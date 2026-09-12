#!/bin/bash

# Lenguaje visual compartido del panel
_INST_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$_INST_DIR/../ui.sh"
# =========================================================
# MÓDULO: Gateway Residencial por WireGuard para HTTP Injector
# Interfaz   : wg-home
# Red VPN    : 10.77.77.0/24
# Droplet    : 10.77.77.1  (servidor WireGuard, escucha 51820/UDP)
# PC Home    : 10.77.77.2  (cliente, Linux CachyOS, salida wlan0 NAT)
# Tabla RT   : 200 homevpn (policy routing — no toca tabla main)
# =========================================================
# SEGURIDAD SSH: La ruta por defecto de la tabla main NUNCA
# se altera. Las conexiones entrantes y de administración
# siempre salen directamente por la IP de DigitalOcean.
# =========================================================

# === Constantes del módulo ===
WGH_IFACE="wg-home"
WGH_CONF="/etc/wireguard/wg-home.conf"
WGH_PRIV_KEY="/etc/wireguard/wghome_droplet_private.key"
WGH_PUB_KEY="/etc/wireguard/wghome_droplet_public.key"
WGH_PEER_KEY="/etc/wireguard/wghome_peer_public.key"
WGH_PORT="51820"
WGH_SUBNET="10.77.77.0/24"
WGH_DROPLET_IP="10.77.77.1"
WGH_PEER_IP="10.77.77.2"
WGH_RT_TABLE="200"
WGH_RT_NAME="homevpn"
WGH_RT_BACKUP="/etc/wireguard/wghome_route_backup"
WGH_BACKUP_DIR="/var/backups/homevpn"
WGH_LOG_FILE="/var/log/homevpn.log"
WGH_USERS_CONF="/etc/wireguard/homevpn-users.conf"
WGH_FALLBACK_CONF="/etc/wireguard/homevpn-fallback.conf"
WGH_SERVICE_FILE="/etc/systemd/system/homevpn-rules.service"
WGH_FWMARK="0x77"

# Paleta heredada del entorno (main.sh la exporta via source)
# CR CY GR RD YL WH DM SEP — definidas en main.sh o defaults de seguridad
CR=${CR:-"\033[0m"}
CY=${CY:-"\033[1;36m"}
GR=${GR:-"\033[1;32m"}
RD=${RD:-"\033[0;31m"}
YL=${YL:-"\033[0;33m"}
WH=${WH:-"\033[1;37m"}
DM=${DM:-"\033[2;37m"}

# =========================================================
# 0. SISTEMA DE LOGGING Y BACKUP (CAMBIOS 16, 17, 18)
# =========================================================

# Registro en /var/log/homevpn.log (sin registrar secretos)
_wgh_log() {
    local msg="$1"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)
    mkdir -p "$(dirname "$WGH_LOG_FILE")" 2>/dev/null
    touch "$WGH_LOG_FILE" 2>/dev/null
    chmod 640 "$WGH_LOG_FILE" 2>/dev/null
    echo "[$ts] $msg" >> "$WGH_LOG_FILE" 2>/dev/null
}

# Crear backup con timestamp en /var/backups/homevpn/
_wgh_backup() {
    local ts
    ts=$(date '+%Y%m%d_%H%M%S' 2>/dev/null || date +%s)
    local target_dir="${WGH_BACKUP_DIR}/backup_${ts}"
    mkdir -p "$target_dir" 2>/dev/null
    chmod 700 "$target_dir" 2>/dev/null

    [ -f "$WGH_CONF" ] && cp -p "$WGH_CONF" "$target_dir/" 2>/dev/null
    [ -f /etc/iproute2/rt_tables ] && cp -p /etc/iproute2/rt_tables "$target_dir/" 2>/dev/null
    [ -f "$WGH_USERS_CONF" ] && cp -p "$WGH_USERS_CONF" "$target_dir/" 2>/dev/null
    [ -f "$WGH_FALLBACK_CONF" ] && cp -p "$WGH_FALLBACK_CONF" "$target_dir/" 2>/dev/null

    {
        echo "=== SNAPSHOT: $ts ==="
        echo "--- ip rule show ---"
        ip rule show
        echo "--- ip route show table main ---"
        ip route show table main
        echo "--- ip route show table ${WGH_RT_TABLE} ---"
        ip route show table "${WGH_RT_TABLE}" 2>/dev/null
        echo "--- iptables-save (mangle & nat & filter) ---"
        iptables-save 2>/dev/null
    } > "${target_dir}/state_snapshot.txt" 2>/dev/null

    _wgh_log "Backup creado en ${target_dir}"
    echo "$target_dir"
}

# =========================================================
# HELPERS INTERNOS DE SISTEMA Y RED
# =========================================================

# Detectar distribución base
_wgh_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "${ID:-unknown}"
    else
        echo "unknown"
    fi
}

# Detectar backend de firewall activo
_wgh_detect_firewall_backend() {
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo "ufw (iptables-nft backend)"
    elif command -v iptables &>/dev/null; then
        local v
        v=$(iptables -V 2>/dev/null)
        echo "iptables ($v)"
    else
        echo "unknown"
    fi
}

# Obtener la IP pública normal de la Droplet
WGH_ENDPOINT_CONF="/etc/wireguard/homevpn-endpoint.conf"

_wgh_set_endpoint() {
    mkdir -p /etc/wireguard 2>/dev/null
    echo "ENDPOINT=$1" > "$WGH_ENDPOINT_CONF"
    chmod 644 "$WGH_ENDPOINT_CONF"
    _wgh_log "Endpoint publico fijado manualmente a: $1"
}

# Direccion publica de esta Droplet, la que los nodos usan como
# Endpoint. Antes habia aqui un valor fijo de reserva —la IP de una
# Droplet concreta— y cuando curl fallaba el panel anunciaba con
# total seguridad una direccion ajena: los nodos apuntaban su tunel
# a otra maquina y no volvia ni un paquete. Nunca se inventa una IP:
# si no se puede averiguar, se devuelve vacio y se pide al usuario.
_wgh_get_droplet_ip() {
    # 1. Valor fijado a mano: manda sobre todo lo demas.
    if [ -f "$WGH_ENDPOINT_CONF" ]; then
        local fixed
        fixed=$(sed -n 's/^ENDPOINT=//p' "$WGH_ENDPOINT_CONF" 2>/dev/null | head -1)
        [ -n "$fixed" ] && { echo "$fixed"; return 0; }
    fi

    local ip="" svc
    for svc in https://api.ipify.org https://ifconfig.me https://icanhazip.com https://ipv4.icanhazip.com; do
        ip=$(curl -4 -s --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]')
        echo "$ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' && { echo "$ip"; return 0; }
        ip=""
    done

    # 2. Sin salida a Internet: la IP de la interfaz por defecto.
    #    Sirve en una Droplet, donde la publica esta en la propia
    #    interfaz; se descartan rangos privados para no anunciar una
    #    direccion interna que ningun nodo podria alcanzar.
    local dev
    dev=$(ip route show default 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    if [ -n "$dev" ]; then
        ip=$(ip -4 addr show dev "$dev" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 \
             | grep -vE '^(10\.|127\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' | head -1)
        [ -n "$ip" ] && { echo "$ip"; return 0; }
    fi

    echo ""
    return 1
}

# =========================================================
# CORREGIR LA DIRECCION PUBLICA A MANO
# =========================================================
wghome_fix_endpoint() {
    clear
    print_title 2>/dev/null || true
    ui_section "DIRECCION PUBLICA DEL VPS" "la que los nodos usan como Endpoint"
    ui_blank

    # No se adivina: se enseña todo lo que ESTE servidor sabe de si
    # mismo —lo que ve el exterior y lo que tiene en sus interfaces—
    # y elige el usuario. Deducir la IP de otro sitio es justo lo que
    # hacia que los nodos apuntasen a una maquina ajena.
    local det
    det=$(_wgh_get_droplet_ip)

    echo -e "${UI_PAD}${WH}Lo que sabe este servidor de si mismo${CR}"
    ui_blank

    local n=0
    local -a cand=()

    # 1. Como lo ve Internet
    local seen
    seen=$(curl -4 -s --max-time 6 https://api.ipify.org 2>/dev/null | tr -d '[:space:]')
    if echo "$seen" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        n=$((n+1)); cand+=("$seen")
        echo -e "${UI_PAD}${CY}[$n]${CR} ${GR}${seen}${CR} ${DM}— como lo ve Internet (salida)${CR}"
    else
        echo -e "${UI_PAD}${DM}    Sin respuesta de los servicios de IP externa.${CR}"
    fi

    # 2. Direcciones publicas configuradas en las interfaces
    local a
    while read -r a; do
        [ -z "$a" ] && continue
        # No repetir la que ya salio como IP de salida
        printf '%s\n' "${cand[@]}" | grep -qxF "$a" && continue
        n=$((n+1)); cand+=("$a")
        echo -e "${UI_PAD}${CY}[$n]${CR} ${WH}${a}${CR} ${DM}— configurada en una interfaz${CR}"
    done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 \
             | grep -vE '^(10\.|127\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)')

    ui_blank
    if [ -f "$WGH_ENDPOINT_CONF" ]; then
        echo -e "${UI_PAD}$(ui_cell "Fijada ahora a mano" "${det}" 44 "$YL")"
    elif [ -n "$det" ]; then
        echo -e "${UI_PAD}$(ui_cell "En uso (detectada)" "${det}" 44 "$GR")"
    else
        ui_err "Ahora mismo no hay ninguna direccion utilizable."
    fi

    ui_blank
    ui_rule
    echo -e "${UI_PAD}${DM}Debe ser la direccion publica de ESTE servidor, el que${CR}"
    echo -e "${UI_PAD}${DM}corre este panel. Si tienes varios VPS, comprueba que no${CR}"
    echo -e "${UI_PAD}${DM}estas poniendo la de otro: los nodos abririan el tunel${CR}"
    echo -e "${UI_PAD}${DM}contra la maquina equivocada y no volveria ni un paquete.${CR}"
    ui_blank
    echo -e "${UI_PAD}${DM}Escribe un numero de la lista, una IP o dominio,${CR}"
    echo -e "${UI_PAD}${DM}o deja vacio para no cambiar nada.${CR}"
    ui_blank
    read -p "$(echo -e "${UI_PAD}${DM}Direccion ${CY}»${CR} ")" nep
    nep=$(echo "$nep" | tr -d '[:space:]')
    [ -z "$nep" ] && return

    # Si es un numero de la lista, se traduce a la direccion
    if echo "$nep" | grep -qE '^[0-9]+$' && [ "$nep" -ge 1 ] && [ "$nep" -le "$n" ]; then
        nep="${cand[$((nep-1))]}"
    fi

    _wgh_set_endpoint "$nep"
    ui_ok "Endpoint fijado a ${nep}."
    ui_warn "Cada nodo debe actualizar su Endpoint con esta direccion."
    ui_pause
}

# Instalar WireGuard si no está presente
_wgh_ensure_installed() {
    if command -v wg &>/dev/null && command -v wg-quick &>/dev/null; then
        return 0
    fi
    echo -e "  ${YL}[*]${CR} WireGuard no encontrado. Instalando..."
    local distro
    distro=$(_wgh_distro)
    case "$distro" in
        ubuntu|debian)
            apt-get update -yq &>/dev/null
            apt-get install -yq wireguard wireguard-tools &>/dev/null
            ;;
        arch|cachyos)
            pacman -Sy --noconfirm wireguard-tools &>/dev/null
            ;;
        *)
            echo -e "  ${RD}[-]${CR} Distribución no reconocida: $distro"
            echo -e "  ${YL}[!]${CR} Instala manualmente: wireguard y wireguard-tools"
            return 1
            ;;
    esac
    if ! command -v wg &>/dev/null; then
        echo -e "  ${RD}[-]${CR} Error instalando WireGuard."
        return 1
    fi
    echo -e "  ${GR}[+]${CR} WireGuard instalado correctamente."
    return 0
}

# Registrar tabla de rutas 200 homevpn si no existe
_wgh_ensure_rt_table() {
    mkdir -p /etc/iproute2 2>/dev/null
    if [ ! -f /etc/iproute2/rt_tables ]; then
        touch /etc/iproute2/rt_tables
    fi
    if ! grep -q "^${WGH_RT_TABLE}[[:space:]]" /etc/iproute2/rt_tables 2>/dev/null; then
        echo -e "  ${YL}[*]${CR} Registrando tabla de rutas ${WGH_RT_TABLE} ${WGH_RT_NAME}..."
        echo "${WGH_RT_TABLE} ${WGH_RT_NAME}" >> /etc/iproute2/rt_tables
        _wgh_log "Tabla ${WGH_RT_TABLE} ${WGH_RT_NAME} agregada a /etc/iproute2/rt_tables"
        echo -e "  ${GR}[+]${CR} Tabla ${WGH_RT_NAME} registrada."
    fi
}

# Activar IP forwarding de forma persistente
# =========================================================
# FILTRO DE RUTA INVERSA
# ---------------------------------------------------------
# Con rp_filter en 1 (estricto, el valor por defecto en muchos
# sistemas) el kernel descarta un paquete si la mejor ruta hacia
# su origen no sale por la interfaz por la que entro.
#
# Eso mata este montaje sin dejar rastro: las respuestas de
# Internet vuelven por wg-home con origen una IP publica, y la
# ruta hacia esa IP va por eth0, no por wg-home. Se descartan
# todas. El tunel se ve perfecto, el handshake entra, los
# contadores suben... y no hay Internet.
#
# Se pasa a 2 (laxo): basta con que el origen sea alcanzable por
# alguna interfaz. Es lo correcto en una maquina que enruta por
# politicas, y sigue descartando origenes imposibles.
# =========================================================
_wgh_fix_rp_filter() {
    # El valor efectivo de una interfaz es el maximo entre 'all' y
    # el suyo, asi que no basta con tocar uno de los dos.
    sysctl -w net.ipv4.conf.all.rp_filter=2 &>/dev/null
    sysctl -w net.ipv4.conf.default.rp_filter=2 &>/dev/null
    local i ifc dev
    for i in $(_wgh_nodes_list 2>/dev/null | cut -d'|' -f3); do
        ifc=$(_wgn_iface "$i")
        sysctl -w "net.ipv4.conf.${ifc}.rp_filter=2" &>/dev/null
    done
    dev=$(ip route show default 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [ -n "$dev" ] && sysctl -w "net.ipv4.conf.${dev}.rp_filter=2" &>/dev/null

    # Persistente: si no, se pierde en el proximo reinicio y el
    # gateway deja de dar Internet sin que nadie toque nada.
    mkdir -p /etc/sysctl.d 2>/dev/null
    cat > /etc/sysctl.d/99-homevpn.conf <<EOF
# Gateway residencial: el policy routing necesita rp_filter laxo.
# Con el valor estricto (1) se descartan las respuestas que vuelven
# por el tunel y no hay salida a Internet.
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
EOF
    _wgh_log "rp_filter ajustado a 2 (laxo) y hecho persistente"
}

_wgh_enable_forwarding() {
    sysctl -w net.ipv4.ip_forward=1 &>/dev/null
    if ! grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    else
        sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    fi
}

# Verificar que el túnel tiene handshake reciente (< 3 minutos)
_wgh_has_handshake() {
    local ts
    ts=$(wg show "${WGH_IFACE}" latest-handshakes 2>/dev/null | awk '{print $2}')
    [ -z "$ts" ] && return 1
    [ "$ts" = "0" ] && return 1
    local now diff
    now=$(date +%s)
    diff=$(( now - ts ))
    [ "$diff" -lt 180 ]
}

# Obtener segundos desde el último handshake
_wgh_handshake_seconds() {
    local ts
    ts=$(wg show "${WGH_IFACE}" latest-handshakes 2>/dev/null | awk '{print $2}')
    if [ -z "$ts" ] || [ "$ts" = "0" ]; then
        echo "never"
        return
    fi
    local now diff
    now=$(date +%s)
    diff=$(( now - ts ))
    echo "$diff"
}

# Verificar que la ruta SSH principal no pasa por wg-home
_wgh_verify_ssh_route() {
    local default_gw
    default_gw=$(ip route show table main | grep '^default' | grep -v "wg-home" | head -1)
    if [ -z "$default_gw" ]; then
        echo -e "  ${RD}[!]${CR} ADVERTENCIA: La ruta por defecto en tabla main no se encontró o usa wg-home."
        echo -e "  ${RD}[!]${CR} SSH podría verse afectado. Revisa: ip route show table main"
        _wgh_log "ALERTA: Verificación de ruta SSH falló en tabla main"
        return 1
    fi
    return 0
}

# Abrir puerto 51820/udp en UFW si está activo
_wgh_open_firewall() {
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${WGH_PORT}/udp" &>/dev/null
        echo -e "  ${GR}[+]${CR} UFW: puerto ${WGH_PORT}/UDP abierto."
        _wgh_log "UFW: puerto ${WGH_PORT}/UDP abierto"
    fi
}

# Cerrar puerto 51820/udp en UFW si está activo
_wgh_close_firewall() {
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw delete allow "${WGH_PORT}/udp" &>/dev/null
        echo -e "  ${GR}[+]${CR} UFW: regla ${WGH_PORT}/UDP eliminada."
        _wgh_log "UFW: regla ${WGH_PORT}/UDP eliminada"
    fi
}

# Verificar si el módulo está instalado (archivos de config y claves existen)
_wgh_is_installed() {
    [ -f "${WGH_CONF}" ] && [ -f "${WGH_PRIV_KEY}" ]
}

# Genera el par de claves de la Droplet y un wg-home.conf base si no
# existen, sin arrancar ninguna interfaz. Permite usar nodos socks sin
# tener que pasar antes por el asistente de instalacion (opcion 1).
_wgh_ensure_keys() {
    _wgh_ensure_installed || return 1
    mkdir -p /etc/wireguard 2>/dev/null
    if [ ! -s "${WGH_PRIV_KEY}" ]; then
        (umask 077; wg genkey > "${WGH_PRIV_KEY}")
        wg pubkey < "${WGH_PRIV_KEY}" > "${WGH_PUB_KEY}"
        chmod 600 "${WGH_PRIV_KEY}"; chmod 644 "${WGH_PUB_KEY}"
    fi
    [ -f "${WGH_CONF}" ] || { _wgh_render_conf "$(cat "${WGH_PRIV_KEY}")" "" > "${WGH_CONF}"; chmod 600 "${WGH_CONF}"; }
}

# Verificar si el túnel está activo a nivel de interfaz de red
_wgh_is_up() {
    ip link show "${WGH_IFACE}" &>/dev/null 2>&1
}

# Verificar si la salida residencial está activa en policy routing
_wgh_routing_is_active() {
    # WireGuard deja una regla 'ip rule'; un nodo socks no, porque
    # redirige con iptables. Se considera activa si hay cualquiera de
    # las dos huellas, o marcas de usuario ya aplicadas.
    ip rule show | grep -qE "lookup (${WGH_RT_NAME}|${WGH_RT_TABLE})" && return 0
    iptables -t nat -S 2>/dev/null | grep -q "HOMEVPN_SOCKS" && return 0
    iptables -t mangle -S 2>/dev/null | grep -q "HOMEVPN_MARK" && return 0
    return 1
}

# Obtener o fijar estado de Fallback (por defecto ON)
_wgh_get_fallback() {
    if [ -f "$WGH_FALLBACK_CONF" ]; then
        grep -oE "ON|OFF" "$WGH_FALLBACK_CONF" 2>/dev/null | head -1 || echo "ON"
    else
        echo "ON"
    fi
}

_wgh_set_fallback() {
    local val="$1"
    [ "$val" != "OFF" ] && val="ON"
    mkdir -p /etc/wireguard 2>/dev/null
    echo "FALLBACK=${val}" > "$WGH_FALLBACK_CONF"
    chmod 644 "$WGH_FALLBACK_CONF"
    _wgh_log "Fallback residencial configurado a: ${val}"
}

# =========================================================
# REGISTRO DE NODOS RESIDENCIALES
# ---------------------------------------------------------
# Antes solo cabia un nodo: el conf llevaba un unico [Peer] y
# registrar una clave nueva borraba la anterior en silencio.
# Ahora se admiten varios (PC, movil, Raspberry...), cada uno
# con su propia IP dentro de 10.77.77.0/24.
#
# UNO SOLO puede ser la SALIDA a Internet en cada momento, y
# esto no es una decision de diseño sino del protocolo: el
# reparto de paquetes de WireGuard se hace por AllowedIPs, y
# dos peers no pueden declarar 0.0.0.0/0 a la vez — el segundo
# se lo quitaria al primero. Asi que el nodo activo lleva
# 0.0.0.0/0 y el resto solo su /32: siguen conectados y
# alcanzables, listos para relevarlo, pero no reciben el
# trafico de Internet.
#
# Formato de /etc/wireguard/homevpn-nodes.conf:
#   nombre|clave_publica|ip|activo(si/no)
# =========================================================

WGH_NODES_CONF="/etc/wireguard/homevpn-nodes.conf"

# Trae al registro el peer unico de la version anterior, para que
# actualizar el panel no desconecte el nodo que ya funcionaba.
# =========================================================
# PARAMETROS DERIVADOS DE CADA NODO
# ---------------------------------------------------------
# Para que dos nodos den salida A LA VEZ hace falta una
# interfaz WireGuard por cada uno. No es una preferencia: el
# reparto de paquetes se hace por AllowedIPs, y solo un peer
# de una interfaz puede declarar 0.0.0.0/0. Con una interfaz
# por nodo, cada cual tiene su propio 0.0.0.0/0 sin competir.
#
# Todo se deduce del indice, asi que el registro guarda un
# numero y no cinco campos que podrian descuadrarse entre si.
#
#   N=1 -> wg-home    51820  10.77.77.x  tabla 200  marca 0x77
#   N=2 -> wg-home2   51821  10.77.78.x  tabla 202  marca 0x772
#   N=3 -> wg-home3   51822  10.77.79.x  tabla 203  marca 0x773
#
# El nodo 1 conserva exactamente los valores de siempre: una
# instalacion que ya funciona no debe notar este cambio.
# =========================================================

_wgn_iface()  { [ "$1" = "1" ] && echo "wg-home"           || echo "wg-home$1"; }
_wgn_port()   { echo $(( 51819 + $1 )); }
_wgn_net()    { echo "10.77.$(( 76 + $1 ))"; }
_wgn_vpsip()  { echo "$(_wgn_net "$1").1"; }
_wgn_nodeip() { echo "$(_wgn_net "$1").2"; }
_wgn_subnet() { echo "$(_wgn_net "$1").0/24"; }
_wgn_table()  { [ "$1" = "1" ] && echo "200"               || echo $(( 200 + $1 )); }
_wgn_mark()   { [ "$1" = "1" ] && echo "0x77"              || echo "0x77$1"; }
_wgn_conf()   { echo "/etc/wireguard/$(_wgn_iface "$1").conf"; }

# --- Parametros derivados de los nodos SOCKS (movil sin root) ---
# Un nodo SOCKS no tiene interfaz WireGuard: el movil abre un tunel
# inverso (ssh -R) que deja un SOCKS5 escuchando en localhost, y el
# trafico de sus usuarios se redirige a ese SOCKS con redsocks. Los
# rangos no pisan los del modelo WireGuard (que usa 51820+, 10.77.x).
_wgn_socksport() { echo $(( 11080 + $1 )); }   # SOCKS inverso (ssh -R), en localhost
_wgn_redport()   { echo $(( 12300 + $1 )); }   # escucha local de redsocks
_wgn_socksuser() { echo "snode$1"; }           # usuario de sistema del movil (uid<1000)
_socks_redconf() { echo "/etc/redsocks/node$1.conf"; }
_socks_redunit() { echo "redsocks-node$1"; }

# Tipo de un nodo: 'wg' (WireGuard, por defecto) o 'socks' (movil).
# El registro heredado no trae 4o campo, asi que la ausencia = wg.
_wgh_node_type() {
    local t
    t=$(_wgh_nodes_list | awk -F'|' -v n="$1" '$1==n {print $4}' | head -1)
    [ -z "$t" ] && t="wg"
    echo "$t"
}
_wgh_node_is_socks() { [ "$(_wgh_node_type "$1")" = "socks" ]; }

# --- Registro: nombre|clave_publica|indice ---

_wgh_nodes_migrate() {
    [ -f "$WGH_NODES_CONF" ] && return 0
    mkdir -p /etc/wireguard 2>/dev/null
    : > "$WGH_NODES_CONF"; chmod 600 "$WGH_NODES_CONF"
    if [ -s "${WGH_PEER_KEY}" ]; then
        local old
        old=$(tr -d '[:space:]' < "${WGH_PEER_KEY}" 2>/dev/null)
        [ -n "$old" ] && {
            echo "nodo-1|${old}|1" >> "$WGH_NODES_CONF"
            _wgh_log "Peer unico anterior migrado como nodo 1"
        }
    fi
}

_wgh_nodes_list()  { _wgh_nodes_migrate; grep -vE '^\s*(#|$)' "$WGH_NODES_CONF" 2>/dev/null; }
_wgh_nodes_count() { _wgh_nodes_list | wc -l; }

# Indice libre mas bajo. Se reutilizan huecos: si se borra el
# nodo 2, el siguiente alta vuelve a ocupar ese indice y con el
# su interfaz, puerto y subred.
_wgh_nodes_next_idx() {
    local i
    for i in $(seq 1 16); do
        _wgh_nodes_list | cut -d'|' -f3 | grep -qx "$i" || { echo "$i"; return 0; }
    done
    return 1
}

_wgh_node_idx_of()  { _wgh_nodes_list | awk -F'|' -v n="$1" '$1==n {print $3}' | head -1; }
_wgh_node_key_of()  { _wgh_nodes_list | awk -F'|' -v n="$1" '$1==n {print $2}' | head -1; }
_wgh_node_name_of() { _wgh_nodes_list | awk -F'|' -v i="$1" '$3==i {print $1}' | head -1; }
_wgh_nodes_names()  { _wgh_nodes_list | cut -d'|' -f1; }
_wgh_nodes_has_key(){ _wgh_nodes_list | cut -d'|' -f2 | grep -qxF "$1"; }
_wgh_node_exists()  { _wgh_nodes_names | grep -qxF "$1"; }

_wgh_nodes_add() {
    # name | clave/usuario | indice | tipo(wg|socks)
    # En un nodo wg el 2o campo es la clave publica; en uno socks es
    # el usuario de sistema del movil. El tipo va al final para no
    # romper el registro heredado de 3 campos (que se lee como wg).
    local name="$1" key="$2" type="${3:-wg}" idx
    _wgh_nodes_migrate
    idx=$(_wgh_nodes_next_idx) || return 1
    echo "${name}|${key}|${idx}|${type}" >> "$WGH_NODES_CONF"
    chmod 600 "$WGH_NODES_CONF"
    _wgh_log "Nodo '${name}' (${type}) registrado con indice ${idx}"
    echo "$idx"
}

_wgh_nodes_del() {
    local name="$1" idx tmp
    idx=$(_wgh_node_idx_of "$name")
    [ -z "$idx" ] && return 1

    # Segun el tipo, se desmonta la interfaz wg o el stack socks
    # (redsocks + usuario del movil) antes de soltar el registro.
    if _wgh_node_is_socks "$name"; then
        _socks_node_del "$idx"
    else
        _wgh_node_down "$idx"
        rm -f "$(_wgn_conf "$idx")" 2>/dev/null
        ip route flush table "$(_wgn_table "$idx")" 2>/dev/null
    fi

    tmp=$(mktemp)
    _wgh_nodes_list | awk -F'|' -v n="$name" '$1!=n' > "$tmp"
    mv "$tmp" "$WGH_NODES_CONF"; chmod 600 "$WGH_NODES_CONF"

    # Los usuarios que salian por el se quedan sin salida asignada:
    # vuelven a la IP del VPS en vez de quedar enrutados al vacio.
    if [ -f "$WGH_USERS_CONF" ]; then
        tmp=$(mktemp)
        grep -vE '^\s*(#|$)' "$WGH_USERS_CONF" 2>/dev/null | awk -F'|' -v n="$name" '$2!=n' > "$tmp"
        mv "$tmp" "$WGH_USERS_CONF"; chmod 644 "$WGH_USERS_CONF"
    fi
    _wgh_log "Nodo '${name}' (indice ${idx}) eliminado"
}

# =========================================================
# CICLO DE VIDA DE CADA INTERFAZ
# ---------------------------------------------------------
# Todas comparten el par de claves de la Droplet. WireGuard lo
# permite y evita que el usuario tenga que llevar una clave
# distinta por nodo: lo que las distingue es el puerto.
# =========================================================

_wgh_node_render() {
    local idx="$1" key="$2" priv
    priv=$(cat "${WGH_PRIV_KEY}" 2>/dev/null)
    cat <<EOF
# =========================================================
# Gateway Residencial — nodo $(_wgh_node_name_of "$idx") (indice ${idx})
# Interfaz : $(_wgn_iface "$idx")   Puerto: $(_wgn_port "$idx")/UDP
# Red      : $(_wgn_subnet "$idx")
# =========================================================
# Table = off: wg-quick no debe tocar la tabla main de la
# Droplet. El reparto por usuario se hace con policy routing.
# =========================================================
[Interface]
Address    = $(_wgn_vpsip "$idx")/24
ListenPort = $(_wgn_port "$idx")
PrivateKey = ${priv}
Table      = off

[Peer]
# Nodo residencial: $(_wgh_node_name_of "$idx")
PublicKey           = ${key}
AllowedIPs          = 0.0.0.0/0
PersistentKeepalive = 0
EOF
}

_wgh_node_write_conf() {
    local idx="$1" key
    key=$(_wgh_node_key_of "$(_wgh_node_name_of "$idx")")
    [ -z "$key" ] && return 1
    _wgh_node_render "$idx" "$key" > "$(_wgn_conf "$idx")"
    chmod 600 "$(_wgn_conf "$idx")"
}

_wgh_node_is_up() { ip link show "$(_wgn_iface "$1")" &>/dev/null; }

_wgh_node_up() {
    local idx="$1" ifc
    ifc=$(_wgn_iface "$idx")
    _wgh_node_write_conf "$idx" || return 1

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        # El puerto por el que el nodo llama.
        ufw allow "$(_wgn_port "$idx")/udp" &>/dev/null
        # Y la entrada POR EL TUNEL. El panel deja UFW en "deny
        # incoming", y aunque las respuestas suelen entrar por la
        # regla de conexiones establecidas, cualquier trafico que
        # inicie el nodo —un ping de prueba, por ejemplo— se
        # descartaria sin dejar rastro. El nodo es un equipo propio,
        # y esto solo abre su interfaz, no Internet.
        ufw allow in on "$ifc" &>/dev/null
    fi

    if _wgh_node_is_up; then
        # Ya arriba: se aplica el conf en caliente, sin cortar.
        wg syncconf "$ifc" <(wg-quick strip "$ifc" 2>/dev/null) 2>/dev/null && return 0
    fi
    systemctl enable "wg-quick@${ifc}" &>/dev/null
    systemctl restart "wg-quick@${ifc}" &>/dev/null
    sleep 1
    _wgh_node_is_up
}

_wgh_node_down() {
    local idx="$1" ifc
    ifc=$(_wgn_iface "$idx")
    systemctl stop "wg-quick@${ifc}" &>/dev/null
    systemctl disable "wg-quick@${ifc}" &>/dev/null
    ip link del "$ifc" 2>/dev/null
    _wgh_log "Interfaz ${ifc} detenida"
}

# Levanta todas las interfaces registradas.
_wgh_nodes_up_all() {
    local name idx key type
    while IFS='|' read -r name key idx type; do
        [ -z "$idx" ] && continue
        if [ "${type:-wg}" = "socks" ]; then
            _socks_up "$idx"
        else
            _wgh_node_up "$idx"
        fi
    done < <(_wgh_nodes_list)
}

# Handshake de un nodo, en segundos. -1 si nunca hubo.
_wgh_node_hs() {
    local idx="$1" ts
    ts=$(wg show "$(_wgn_iface "$idx")" latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)
    [ -z "$ts" ] || [ "$ts" = "0" ] && { echo "-1"; return; }
    echo $(( $(date +%s) - ts ))
}

# =========================================================
# NODOS SOCKS — movil sin root por tunel inverso (ssh -R)
# ---------------------------------------------------------
# El movil abre 'ssh -N -R <socksport> snodeN@vps'. Eso deja un
# SOCKS5 escuchando en 127.0.0.1:<socksport> del VPS que sale por
# la conexion del telefono. redsocks toma el trafico ya marcado de
# los usuarios asignados y lo mete por ese SOCKS. Solo TCP: el DNS
# (UDP) sigue resolviendo en el VPS.
# =========================================================
_SOCKS_SSHD_DROPIN="/etc/ssh/sshd_config.d/20-vpsservice-nodes.conf"

_socks_deps_ready() { command -v redsocks &>/dev/null; }

_socks_install_deps() {
    _socks_deps_ready && return 0
    _wgh_log "Instalando redsocks..."
    apt-get update -yq &>/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -yq redsocks &>/dev/null
    # El paquete arranca un redsocks con su config de ejemplo, que no
    # usamos: cada nodo corre su propia instancia. Se apaga el de serie.
    systemctl disable --now redsocks &>/dev/null
    _socks_deps_ready
}

# sshd: los usuarios de nodo solo pueden abrir el reenvio inverso, nada
# mas. Sin esto un snodeN con contrasena seria un proxy abierto hacia el
# localhost del VPS.
_socks_harden_sshd() {
    [ -f "$_SOCKS_SSHD_DROPIN" ] && return 0
    [ -d /etc/ssh/sshd_config.d ] || return 0
    cat > "$_SOCKS_SSHD_DROPIN" <<'SSHEOF'
# Usuarios de nodo movil (SOCKS inverso). Solo reenvio remoto.
Match User snode*
    AllowTcpForwarding remote
    PermitTunnel no
    X11Forwarding no
    AllowAgentForwarding no
    PermitTTY no
    ForceCommand echo "Nodo conectado. Manten esta sesion abierta."
SSHEOF
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
}

# Crea (o reutiliza) el usuario de sistema del movil y autoriza SU LLAVE.
# Igual que un nodo WireGuard se registra por su clave publica, el nodo
# movil se autentica con la llave SSH que genera el propio nodo: sin
# contrasena. La cuenta es de sistema (uid<1000) para no aparecer en la
# tabla de cuentas del panel, que filtra por uid>=1000.
_socks_user_ensure() {
    local idx="$1" pubkey="$2" user home akfile
    user=$(_wgn_socksuser "$idx")
    home="/var/lib/vpsservice/$user"
    if ! id "$user" &>/dev/null; then
        mkdir -p /var/lib/vpsservice 2>/dev/null
        useradd -r -m -d "$home" -s /usr/sbin/nologin "$user" 2>/dev/null
    fi
    # Sin contrasena: la cuenta solo entra con la llave del nodo.
    passwd -l "$user" &>/dev/null

    # authorized_keys, restringida a solo reenvio de puertos. El drop-in
    # de sshd ya limita a reenvio REMOTO; aqui se cierra todo lo demas.
    akfile="$home/.ssh/authorized_keys"
    mkdir -p "$home/.ssh" 2>/dev/null
    if [ -n "$pubkey" ]; then
        local opts="restrict,port-forwarding"
        # Evita duplicar la misma llave si se reconfigura el nodo.
        touch "$akfile"
        grep -qF "$pubkey" "$akfile" 2>/dev/null || echo "${opts} ${pubkey}" >> "$akfile"
    fi
    chmod 700 "$home/.ssh"; chmod 600 "$akfile" 2>/dev/null
    chown -R "$user":"$user" "$home/.ssh" 2>/dev/null

    # Si el sshd tiene lista blanca, el usuario de nodo tambien entra.
    if grep -qE "^AllowUsers" /etc/ssh/sshd_config 2>/dev/null; then
        grep -qE "^AllowUsers.*\b${user}\b" /etc/ssh/sshd_config || \
            sed -i -E "s|^(AllowUsers.*)$|\1 ${user}|" /etc/ssh/sshd_config
    fi
    _socks_harden_sshd
}

_socks_redsocks_write() {
    local idx="$1" redport socksport
    redport=$(_wgn_redport "$idx"); socksport=$(_wgn_socksport "$idx")
    mkdir -p /etc/redsocks 2>/dev/null
    cat > "$(_socks_redconf "$idx")" <<EOF
// Nodo SOCKS ${idx} — generado por vpsservice. No editar a mano.
base {
    log_debug = off;
    log_info = off;
    log = "syslog:daemon";
    daemon = off;
    redirector = iptables;
}
redsocks {
    local_ip = 127.0.0.1;
    local_port = ${redport};
    // SOCKS5 que deja el movil con 'ssh -R ${socksport}'
    ip = 127.0.0.1;
    port = ${socksport};
    type = socks5;
}
EOF
    chmod 600 "$(_socks_redconf "$idx")"

    local rbin
    rbin=$(command -v redsocks 2>/dev/null); [ -z "$rbin" ] && rbin=/usr/sbin/redsocks
    cat > "/etc/systemd/system/$(_socks_redunit "$idx").service" <<EOF
[Unit]
Description=redsocks para nodo movil ${idx} (vpsservice)
After=network.target

[Service]
Type=simple
ExecStart=${rbin} -c $(_socks_redconf "$idx")
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload &>/dev/null
}

# El SOCKS inverso esta arriba si el movil mantiene su ssh -R: el
# puerto local queda en escucha.
_socks_reverse_up() {
    local idx="$1" port
    port=$(_wgn_socksport "$idx")
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"
}

_socks_redsocks_up() { systemctl is-active --quiet "$(_socks_redunit "$1")" 2>/dev/null; }

# ¿Existe la regla nat que desvia la marca de este nodo a su redsocks?
_socks_redirect_present() {
    local idx="$1" mark redport
    mark=$(_wgn_mark "$idx"); redport=$(_wgn_redport "$idx")
    iptables -t nat -C OUTPUT -p tcp -m mark --mark "${mark}" -m comment --comment "HOMEVPN_SOCKS" -j REDIRECT --to-ports "${redport}" 2>/dev/null
}

# Prueba en vivo: sale a Internet POR EL MOVIL (a traves del SOCKS inverso).
# Devuelve la IP publica vista, o vacio si el camino esta roto.
_socks_probe_ip() {
    local idx="$1" sport
    sport=$(_wgn_socksport "$idx")
    command -v curl >/dev/null 2>&1 || return 1
    curl -s -m 10 --socks5-hostname "127.0.0.1:${sport}" https://api.ipify.org 2>/dev/null \
        || curl -s -m 10 --socks5-hostname "127.0.0.1:${sport}" http://ifconfig.me 2>/dev/null
}

_socks_up() {
    local idx="$1"
    _socks_redsocks_write "$idx"
    systemctl enable --now "$(_socks_redunit "$idx")" &>/dev/null
    _socks_redsocks_up "$idx"
}

_socks_down() {
    local idx="$1"
    systemctl disable --now "$(_socks_redunit "$idx")" &>/dev/null
}

_socks_node_del() {
    local idx="$1" user
    _socks_down "$idx"
    rm -f "$(_socks_redconf "$idx")" "/etc/systemd/system/$(_socks_redunit "$idx").service" 2>/dev/null
    systemctl daemon-reload &>/dev/null
    user=$(_wgn_socksuser "$idx")
    if id "$user" &>/dev/null; then
        pkill -u "$user" 2>/dev/null
        userdel -r "$user" 2>/dev/null
    fi
    _wgh_log "Nodo socks ${idx} (${user}) eliminado"
}

# Puerto por el que entra OpenSSH (el movil se conecta ahi).
_socks_ssh_port() {
    local p
    p=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
    [ -z "$p" ] && p=$(grep -E '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2; exit}')
    echo "${p:-22}"
}

# Pantalla con los datos del nodo. La conexion es POR LLAVE: el nodo
# (proyecto Vpsservice-Node-Gateway) genera su par SSH; aqui solo se
# muestra que debe configurar y como comprobar el estado.
_socks_show_instructions() {
    local idx="$1" name="$2" user host port sport haskey
    user=$(_wgn_socksuser "$idx")
    host=$(_wgh_get_droplet_ip); [ -z "$host" ] && host="<IP_DEL_VPS>"
    port=$(_socks_ssh_port)
    sport=$(_wgn_socksport "$idx")
    # ¿ya tiene una llave autorizada?
    [ -s "/var/lib/vpsservice/${user}/.ssh/authorized_keys" ] && haskey="si" || haskey="no"

    clear
    print_title 2>/dev/null || true
    ui_section "NODO MOVIL: ${name}" "conexion por llave SSH"
    ui_blank
    echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Host del VPS " "$host" 30 "$GR")"
    echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Puerto SSH   " "$port" 30 "$CY")"
    echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Usuario      " "$user" 30 "$WH")"
    echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Puerto SOCKS " "$sport" 30 "$CY")"
    if [ "$haskey" = "si" ]; then
        echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Llave        " "autorizada" 30 "$GR")"
    else
        echo -e "${UI_PAD}${RD}▪${CR} $(ui_cell "Llave        " "pendiente de pegar" 30 "$RD")"
    fi
    ui_rule
    echo -e "${UI_PAD}${WH}En el celular (Android, SIN root):${CR}"
    echo -e "${UI_PAD}${DM}1. Instala ${WH}Termux${DM} y el nodo:${CR}"
    echo -e "${UI_PAD}   ${CY}Vpsservice-Node-Gateway${CR} ${DM}(setup.sh), luego el comando ${WH}nodo${CR}"
    echo -e "${UI_PAD}${DM}2. En el nodo, opcion [1]: mete los datos de arriba.${CR}"
    echo -e "${UI_PAD}${DM}   El nodo GENERA su llave y muestra su clave publica.${CR}"
    echo -e "${UI_PAD}${DM}3. Pega esa clave aqui (opcion REGISTRAR NODO MOVIL con${CR}"
    echo -e "${UI_PAD}${DM}   el mismo nombre) y el nodo [2] para conectar.${CR}"
    ui_rule
    echo -e "${UI_PAD}${DM}Comando equivalente a mano (con la llave del nodo):${CR}"
    echo -e "${UI_PAD}${WH}ssh -N -R 127.0.0.1:${sport} -i <llave> ${user}@${host} -p ${port}${CR}"
    ui_blank
    echo -e "${UI_PAD}${DM}Comprobar en el VPS que el movil esta conectado:${CR}"
    echo -e "${UI_PAD}${WH}ss -tlnp | grep ${sport}${CR}"
    ui_blank
    echo -e "${UI_PAD}${YL}[!] Asigna usuarios a este nodo en ASIGNAR USUARIOS${CR}"
    echo -e "${UI_PAD}${YL}    y enciende la salida residencial para que surta efecto.${CR}"
    ui_solid
    ui_pause
}
# Alta de un nodo movil (SOCKS inverso), por LLAVE — igual que un nodo
# WireGuard se registra pegando su clave publica. El nodo (proyecto
# Vpsservice-Node-Gateway) genera su par SSH y muestra su clave; aqui
# se pega y se autoriza. Sin contrasenas.
wghome_register_socks() {
    clear
    print_title 2>/dev/null || true
    ui_section "REGISTRAR NODO MOVIL" "celular Android sin root — por llave"
    ui_blank

    ui_info "Preparando dependencias (redsocks)..."
    if ! _socks_install_deps; then
        ui_err "No se pudo instalar redsocks. Revisa la conexion del VPS."
        ui_pause; return
    fi
    # Un nodo socks no necesita el asistente wg, pero el motor de salida
    # comprueba que el gateway este "instalado". Se generan las claves
    # base (sin arrancar interfaz) para no obligar a la opcion 1.
    _wgh_ensure_keys >/dev/null 2>&1 || true

    ui_blank
    read -p "$(echo -e "${UI_PAD}${DM}Nombre corto (ej: movil, pixel) ${CY}»${CR} ")" nname
    nname=$(echo "$nname" | tr -cd 'A-Za-z0-9_-' | cut -c1-13)
    [ -z "$nname" ] && { ui_err "Nombre vacio."; sleep 1; return; }

    # Si el nombre ya existe y es socks, esto re-autoriza su llave; si es
    # wg, se rechaza para no mezclar dos nodos con el mismo nombre.
    local nidx reauth=""
    if _wgh_node_exists "$nname"; then
        if _wgh_node_is_socks "$nname"; then
            nidx=$(_wgh_node_idx_of "$nname"); reauth="si"
            ui_info "Ese nodo movil ya existe: se actualizara su llave."
        else
            ui_err "Ya existe un nodo (WireGuard) con ese nombre."; sleep 2; return
        fi
    else
        nidx=$(_wgh_nodes_add "$nname" "pendiente" "socks")
        [ -z "$nidx" ] && { ui_err "No quedan indices libres (maximo 16 nodos)."; sleep 2; return; }
    fi

    local user port host sshp
    user=$(_wgn_socksuser "$nidx"); port=$(_wgn_socksport "$nidx")
    host=$(_wgh_get_droplet_ip); [ -z "$host" ] && host="<IP_DEL_VPS>"
    sshp=$(_socks_ssh_port)

    ui_blank
    ui_rule
    echo -e "${UI_PAD}${WH}Configura estos datos EN EL NODO${CR} ${DM}(app/script del nodo):${CR}"
    echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Host del VPS " "$host" 30 "$GR")"
    echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Puerto SSH   " "$sshp" 30 "$CY")"
    echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Usuario      " "$user" 30 "$WH")"
    echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Puerto SOCKS " "$port" 30 "$CY")"
    ui_rule
    echo -e "${UI_PAD}${DM}El nodo generara su llave y te mostrara su clave publica.${CR}"
    ui_blank
    read -p "$(echo -e "${UI_PAD}${DM}Pega la clave publica del nodo (Enter = luego) ${CY}»${CR} ")" pubkey
    pubkey=$(echo "$pubkey" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    if [ -n "$pubkey" ]; then
        if ! echo "$pubkey" | grep -qE '^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-[a-z0-9-]+|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-[a-z0-9-]+) [A-Za-z0-9+/]+=*'; then
            ui_err "Eso no parece una clave publica SSH valida."
            [ -z "$reauth" ] && _wgh_nodes_del "$nname"
            sleep 2; return
        fi
        # Guardar la llave en el registro (campo 2), como el nodo wg guarda
        # su clave publica. Se evita registrar la misma llave dos veces.
        if [ -z "$reauth" ] && _wgh_nodes_has_key "$pubkey"; then
            ui_err "Esa clave ya esta registrada en otro nodo."
            _wgh_nodes_del "$nname"; sleep 2; return
        fi
        local tmp
        tmp=$(mktemp)
        _wgh_nodes_list | awk -F'|' -v n="$nname" -v k="$pubkey" 'BEGIN{OFS="|"} $1==n{$2=k} {print}' > "$tmp"
        mv "$tmp" "$WGH_NODES_CONF"; chmod 600 "$WGH_NODES_CONF"
    fi

    ui_blank
    ui_info "Creando el usuario del nodo y autorizando su llave..."
    _socks_user_ensure "$nidx" "$pubkey"
    _socks_up "$nidx" >/dev/null 2>&1 || true

    # Si la salida residencial ya estaba activa, entra en caliente.
    _wgh_routing_is_active && _wgh_apply_user_routing >/dev/null 2>&1

    ui_blank
    if [ -n "$pubkey" ]; then
        ui_ok "Nodo movil '${nname}' registrado y llave autorizada."
    else
        ui_ok "Nodo movil '${nname}' reservado."
        ui_warn "Aun sin llave: vuelve a esta opcion con el mismo nombre y"
        ui_warn "pega la clave publica que genere el nodo para activarlo."
    fi
    ui_pause
    _socks_show_instructions "$nidx" "$nname"
}

# =========================================================
# ASIGNACION DE USUARIOS A NODOS
# ---------------------------------------------------------
# /etc/wireguard/homevpn-users.conf  ->  usuario|nodo
# Una linea sin '|' viene del formato antiguo, cuando solo
# habia una salida: se entiende asignada al nodo 1.
# =========================================================

_wgh_user_node() {
    local u="$1" n
    n=$(grep -vE '^\s*(#|$)' "$WGH_USERS_CONF" 2>/dev/null | awk -F'|' -v u="$u" '$1==u {print $2}' | head -1)
    if [ -z "$n" ]; then
        grep -vE '^\s*(#|$)' "$WGH_USERS_CONF" 2>/dev/null | grep -qx "$u" && n=$(_wgh_node_name_of 1)
    fi
    echo "$n"
}

_wgh_user_assign() {
    local u="$1" node="$2" tmp
    mkdir -p /etc/wireguard 2>/dev/null
    touch "$WGH_USERS_CONF"
    tmp=$(mktemp)
    grep -vE '^\s*(#|$)' "$WGH_USERS_CONF" 2>/dev/null | awk -F'|' -v u="$u" '$1!=u' > "$tmp"
    [ -n "$node" ] && echo "${u}|${node}" >> "$tmp"
    mv "$tmp" "$WGH_USERS_CONF"; chmod 644 "$WGH_USERS_CONF"
    if [ -n "$node" ]; then
        _wgh_log "Usuario ${u} asignado al nodo ${node}"
    else
        _wgh_log "Usuario ${u} devuelto a la salida normal del VPS"
    fi
}

# Usuarios asignados a un nodo concreto.
_wgh_node_users() {
    local node="$1" u
    while IFS= read -r u; do
        [ -z "$u" ] && continue
        [ "$(_wgh_user_node "$u")" = "$node" ] && echo "$u"
    done < <(_wgh_get_client_users | cut -d: -f1)
}

# El modelo de "un unico nodo activo" desaparecio al permitir varias
# salidas simultaneas. Estos ayudantes quedan para las pantallas que
# solo necesitan un representante: el primer nodo registrado.
_wgh_nodes_first_idx()  { _wgh_nodes_list | head -1 | cut -d'|' -f3; }
_wgh_nodes_first_name() { _wgh_nodes_list | head -1 | cut -d'|' -f1; }
_wgh_nodes_first_ip()   { local i; i=$(_wgh_nodes_first_idx); [ -n "$i" ] && _wgn_nodeip "$i" || echo "$WGH_PEER_IP"; }

# =========================================================
# AISLAMIENTO ENTRE NODOS
# ---------------------------------------------------------
# Los nodos comparten la subred 10.77.77.0/24, asi que sin esto
# el movil podria alcanzar al PC a traves de la Droplet, que hace
# de router entre ambos. La regla corta el reenvio de wg-home
# hacia wg-home, que es justo el trafico entre peers, y no toca
# el de los clientes hacia Internet.
# =========================================================
_wgh_isolate_on() {
    # Cada nodo vive en su propia interfaz y su propia subred, asi que
    # solo podrian verse si la Droplet les hiciera de router. Se corta
    # el reenvio entre cualquier par de interfaces wg-home*.
    # Solo interfaces WireGuard reales: los nodos socks no tienen una.
    local a b ia ib wg_idx
    wg_idx=$(_wgh_nodes_list | awk -F'|' '($4=="" || $4=="wg"){print $3}')
    for a in $wg_idx; do
        ia=$(_wgn_iface "$a")
        for b in $wg_idx; do
            ib=$(_wgn_iface "$b")
            iptables -C FORWARD -i "$ia" -o "$ib" -m comment --comment "HOMEVPN_ISOLATE" -j DROP 2>/dev/null || \
                iptables -I FORWARD 1 -i "$ia" -o "$ib" -m comment --comment "HOMEVPN_ISOLATE" -j DROP 2>/dev/null
        done
    done
    _wgh_log "Aislamiento entre nodos aplicado"
}

_wgh_isolate_off() {
    while iptables -S FORWARD 2>/dev/null | grep -q "HOMEVPN_ISOLATE"; do
        local rule
        rule=$(iptables -S FORWARD 2>/dev/null | grep "HOMEVPN_ISOLATE" | head -1 | sed 's/^-A /-D /')
        [ -z "$rule" ] && break
        # shellcheck disable=SC2086
        iptables $rule 2>/dev/null || break
    done
}

_wgh_isolate_is_on() {
    iptables -C FORWARD -i "${WGH_IFACE}" -o "${WGH_IFACE}" -m comment --comment "HOMEVPN_ISOLATE" -j DROP 2>/dev/null
}

# =========================================================
# CAMBIO 1: GENERADOR DE CONFIGURACIÓN wg-home.conf
# IMPORTANTE: Table = off en [Interface] y AllowedIPs = 0.0.0.0/0 en [Peer]
# =========================================================
_wgh_render_conf() {
    local priv="$1"
    local peer_pub="$2"

    cat <<EOF
# =========================================================
# Gateway Residencial — Droplet (Servidor WireGuard)
# Interfaz : ${WGH_IFACE}
# Red VPN  : ${WGH_SUBNET}
# =========================================================
# SEGURIDAD CRÍTICA:
# - Table = off: impide que wg-quick altere la tabla main de la Droplet.
# - AllowedIPs = 0.0.0.0/0: permite que el PC doméstico enrute tráfico a Internet.
# =========================================================

[Interface]
Address    = ${WGH_DROPLET_IP}/24
ListenPort = ${WGH_PORT}
PrivateKey = ${priv}
Table      = off

EOF

    # Un bloque [Peer] por nodo registrado. El activo se lleva
    # 0.0.0.0/0 —es el que recibe el trafico de Internet— y los
    # demas solo su /32: siguen conectados y alcanzables, pero no
    # compiten por la ruta. Dos peers con 0.0.0.0/0 no pueden
    # coexistir: WireGuard se lo adjudicaria al ultimo.
    local total
    total=$(_wgh_nodes_count)

    if [ "${total:-0}" -eq 0 ]; then
        # Compatibilidad: si aun no hay registro pero si la clave
        # suelta de la version anterior, se usa esa.
        if [ -n "$peer_pub" ]; then
            cat <<EOF
[Peer]
# Nodo residencial (registro heredado)
PublicKey           = ${peer_pub}
AllowedIPs          = 0.0.0.0/0
PersistentKeepalive = 0
EOF
        else
            cat <<EOF
# [Peer] — Pendiente registrar algun nodo residencial.
# Usa la opcion 6 del menu para darlo de alta.
EOF
        fi
        return 0
    fi

    local name key idx type
    while IFS='|' read -r name key idx type; do
        [ -z "$key" ] && continue
        # Un nodo movil (socks) no tiene clave ni peer WireGuard: se
        # omite para no escribir un [Peer] invalido en wg-home.conf.
        [ "${type:-wg}" = "socks" ] && continue
        cat <<EOF
[Peer]
# Nodo: ${name}  ($(_wgn_nodeip "$idx"))
PublicKey           = ${key}
AllowedIPs          = $(_wgn_nodeip "$idx")/32
PersistentKeepalive = 0

EOF
    done < <(_wgh_nodes_list)
}

# Asegura que si wg-home.conf existe, contenga Table = off y AllowedIPs = 0.0.0.0/0
_wgh_repair_conf_if_needed() {
    if [ -f "$WGH_CONF" ]; then
        local needs_update=false
        if ! grep -q "^Table[[:space:]]*=[[:space:]]*off" "$WGH_CONF" 2>/dev/null; then
            needs_update=true
        fi
        if grep -q "AllowedIPs[[:space:]]*=[[:space:]]*${WGH_PEER_IP}/32" "$WGH_CONF" 2>/dev/null; then
            needs_update=true
        fi

        if [ "$needs_update" = true ]; then
            _wgh_log "Reparando ${WGH_CONF} con Table=off y AllowedIPs=0.0.0.0/0"
            local priv peer_pub
            priv=$(cat "${WGH_PRIV_KEY}" 2>/dev/null || true)
            peer_pub=""
            [ -f /etc/wireguard/wghome_peer_public.key ] && peer_pub=$(cat /etc/wireguard/wghome_peer_public.key 2>/dev/null)
            if [ -n "$priv" ]; then
                _wgh_render_conf "$priv" "$peer_pub" > "${WGH_CONF}"
                chmod 600 "${WGH_CONF}"
                if _wgh_is_up; then
                    wg syncconf "${WGH_IFACE}" <(wg-quick strip "${WGH_IFACE}" 2>/dev/null) 2>/dev/null || true
                fi
            fi
        fi
    fi
}

# =========================================================
# CAMBIO 3: DETECCIÓN AUTOMÁTICA DEL STACK HTTP INJECTOR
# =========================================================
_wgh_detect_http_injector() {
    local ssl_port="" ssl_proc="" int_port="" final_service=""

    # 1. Analizar stunnel
    if [ -f /etc/stunnel/stunnel.conf ]; then
        ssl_port=$(grep -E '^\s*accept\s*=' /etc/stunnel/stunnel.conf 2>/dev/null | awk -F'=' '{print $2}' | xargs)
        int_port=$(grep -E '^\s*connect\s*=' /etc/stunnel/stunnel.conf 2>/dev/null | awk -F'=' '{print $2}' | xargs)
        if systemctl is-active --quiet stunnel4 2>/dev/null || pgrep -x stunnel4 &>/dev/null; then
            ssl_proc="stunnel4 (ACTIVO)"
        else
            ssl_proc="stunnel4 (INACTIVO)"
        fi
    fi

    # 2. Analizar websocket si no hay stunnel o adicional
    local ws_port=""
    if [ -f /etc/websocket/proxy.py ]; then
        ws_port=$(grep -oE 'WS_PORT[^0-9]*[0-9]+' /etc/websocket/proxy.py 2>/dev/null | grep -oE '[0-9]+' || echo "80")
    fi

    # 3. Analizar servicio SSH final
    local ssh_p="22"
    if grep -qE '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config 2>/dev/null; then
        ssh_p=$(grep -E '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    fi
    if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
        final_service="OpenSSH (puerto $ssh_p)"
    elif systemctl is-active --quiet dropbear 2>/dev/null; then
        final_service="Dropbear SSH"
    else
        final_service="SSH / Dropbear"
    fi

    echo "SSL_PORT=${ssl_port:-443}|SSL_PROC=${ssl_proc:-N/A}|INT_PORT=${int_port:-127.0.0.1:22}|WS_PORT=${ws_port:-N/A}|FINAL_SVC=${final_service}"
}

# =========================================================
# CAMBIO 14: GESTIÓN DE USUARIOS HTTP INJECTOR
# =========================================================

# Obtiene la lista de usuarios reales del sistema con UID >= 1000 (excluye root y nobody)
_wgh_get_client_users() {
    awk -F: '$3 >= 1000 && $3 != 65534 {print $1 ":" $3}' /etc/passwd 2>/dev/null
}

# Leer usuarios seleccionados en /etc/wireguard/homevpn-users.conf
_wgh_get_configured_users() {
    if [ -f "$WGH_USERS_CONF" ]; then
        grep -vE '^\s*#' "$WGH_USERS_CONF" 2>/dev/null | grep -v '^\s*$' | tr -d '\r'
    fi
}

# Menú para configurar qué usuarios salen por la IP residencial (Opción 12)
wghome_manage_users() {
    while true; do
        clear
        print_title 2>/dev/null || true
        echo -e "$SEP"
        echo -e "${WH}     CONFIGURAR USUARIOS HTTP INJECTOR${CR}"
        echo -e "$SEP"
        echo -e "  ${DM}Selecciona los usuarios Linux cuyo tráfico saldrá${CR}"
        echo -e "  ${DM}por el Gateway Residencial (PC doméstico en Colombia).${CR}"
        echo -e "  ${YL}[!] El usuario 'root' y SSH de admin están siempre excluidos.${CR}"
        echo -e "$SEP"

        local -a system_users=()
        local -a system_uids=()
        local line u uid
        while IFS=: read -r u uid; do
            [ -z "$u" ] && continue
            system_users+=("$u")
            system_uids+=("$uid")
        done < <(_wgh_get_client_users)

        if [ ${#system_users[@]} -eq 0 ]; then
            echo -e "  ${RD}[-] No hay usuarios de clientes creados (UID >= 1000).${CR}"
            echo -e "  ${DM}Crea usuarios primero desde la opción 1 del menú principal.${CR}"
            echo ""
            read -p "$(echo -e ${DM})Presiona Enter para volver...$(echo -e ${CR})"
            return
        fi

        local -a configured_users=()
        if [ -f "$WGH_USERS_CONF" ]; then
            while IFS= read -r cu; do
                [ -n "$cu" ] && configured_users+=("$cu")
            done < <(_wgh_get_configured_users)
        fi

        echo -e "  ${WH}Usuarios disponibles en el sistema:${CR}"
        echo ""
        local i is_sel tag
        for i in "${!system_users[@]}"; do
            u="${system_users[$i]}"
            uid="${system_uids[$i]}"
            is_sel=false
            for cu in "${configured_users[@]}"; do
                if [ "$cu" = "$u" ]; then is_sel=true; break; fi
            done
            if [ "$is_sel" = true ]; then
                tag="${GR}[✓ ENRUTADO RESIDENCIAL]${CR}"
            else
                tag="${DM}[  Salida normal VPS  ]${CR}"
            fi
            printf "  ${CY}%2d)${CR} ${WH}%-16s${CR} (UID: %-5s) %b\n" "$((i + 1))" "$u" "$uid" "$tag"
        done

        echo ""
        echo -e "  ${CY} A)${CR} ${WH}Seleccionar TODOS los usuarios${CR}"
        echo -e "  ${CY} N)${CR} ${WH}Desmarcar TODOS${CR}"
        echo -e "  ${CY} 0)${CR} ${WH}Guardar y Volver${CR}"
        echo -e "$SEP"
        read -p "$(echo -e ${DM})Elige un número para alternar (o A/N/0): $(echo -e ${CR})" sel

        case "$sel" in
            0|"")
                break
                ;;
            a|A)
                mkdir -p /etc/wireguard 2>/dev/null
                printf "%s\n" "${system_users[@]}" > "$WGH_USERS_CONF"
                chmod 600 "$WGH_USERS_CONF"
                _wgh_log "Usuarios configurados: todos (${system_users[*]})"
                ;;
            n|N)
                mkdir -p /etc/wireguard 2>/dev/null
                > "$WGH_USERS_CONF"
                chmod 600 "$WGH_USERS_CONF"
                _wgh_log "Usuarios configurados: ninguno"
                ;;
            *)
                if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le ${#system_users[@]} ]; then
                    local target_user="${system_users[$((sel - 1))]}"
                    local -a new_users=()
                    local found=false
                    for cu in "${configured_users[@]}"; do
                        if [ "$cu" = "$target_user" ]; then
                            found=true
                        else
                            new_users+=("$cu")
                        fi
                    done
                    if [ "$found" = false ]; then
                        new_users+=("$target_user")
                    fi
                    mkdir -p /etc/wireguard 2>/dev/null
                    printf "%s\n" "${new_users[@]}" > "$WGH_USERS_CONF"
                    chmod 600 "$WGH_USERS_CONF"
                    _wgh_log "Usuario alternado: ${target_user} (activo: $([ "$found" = false ] && echo SI || echo NO))"
                else
                    echo -e "  ${RD}[-] Opción no válida.${CR}"; sleep 1
                fi
                ;;
        esac

        # Si el enrutamiento está activo en caliente, refrescar las reglas
        if _wgh_routing_is_active; then
            echo -e "  ${YL}[*] Actualizando reglas de policy routing en caliente...${CR}"
            _wgh_apply_user_routing &>/dev/null
        fi
    done
}

# Ver usuarios actualmente enrutados (Opción 13)
wghome_view_users() {
    clear
    print_title 2>/dev/null || true
    echo -e "$SEP"
    echo -e "${WH}     USUARIOS ENRUTADOS POR GATEWAY RESIDENCIAL${CR}"
    echo -e "$SEP"
    echo ""

    local -a configured_users=()
    if [ -f "$WGH_USERS_CONF" ]; then
        while IFS= read -r cu; do
            [ -n "$cu" ] && configured_users+=("$cu")
        done < <(_wgh_get_configured_users)
    fi

    if [ ${#configured_users[@]} -eq 0 ]; then
        echo -e "  ${YL}[!] No hay usuarios configurados para salida residencial.${CR}"
        echo -e "  ${DM}Usa la opción 12 del menú para asignar usuarios.${CR}"
    else
        echo -e "  ${WH}Usuarios configurados en ${WGH_USERS_CONF}:${CR}"
        echo ""
        printf "  ${CY}%-16s${CR}  ${CY}%-8s${CR}  ${CY}%-22s${CR}  ${CY}%s${CR}\n" "USUARIO" "UID" "REGLA FIREWALL (MANGLE)" "CONEXIÓN ACTIVA"
        echo -e "  $(printf '─%.0s' {1..70})"

        local u uid rule_active conn_count
        for u in "${configured_users[@]}"; do
            uid=$(id -u "$u" 2>/dev/null || echo "N/A")
            if [ "$uid" != "N/A" ] && iptables -t mangle -C OUTPUT -m owner --uid-owner "$uid" -m comment --comment "HOMEVPN_HTTP_INJECTOR" -j MARK --set-mark "${WGH_FWMARK}" &>/dev/null; then
                rule_active="${GR}ACTIVA (0x77)${CR}"
            else
                rule_active="${RD}INACTIVA${CR}"
            fi
            conn_count=$(ps -u "$u" -o comm= 2>/dev/null | grep -E "^(sshd|dropbear)$" | wc -l)
            if [ "$conn_count" -gt 0 ]; then
                conn_status="${GR}${conn_count} sesion(es)${CR}"
            else
                conn_status="${DM}sin conexion${CR}"
            fi
            printf "  ${WH}%-16s${CR}  %-8s  %-31b  %b\n" "$u" "$uid" "$rule_active" "$conn_status"
        done
    fi

    echo ""
    echo -e "  ${DM}Estado global de policy routing: $(_wgh_routing_is_active && echo -e "${GR}ON${CR}" || echo -e "${RD}OFF${CR}")${CR}"
    echo -e "$SEP"
    read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
}

# Configurar Fallback Residencial (Opción 14)
wghome_configure_fallback() {
    clear
    print_title 2>/dev/null || true
    echo -e "$SEP"
    echo -e "${WH}     CONFIGURACIÓN DE FALLBACK RESIDENCIAL${CR}"
    echo -e "$SEP"
    echo ""
    local current_fb
    current_fb=$(_wgh_get_fallback)

    echo -e "  ${DM}Estado actual de Fallback:${CR} $([ "$current_fb" = "ON" ] && echo -e "${GR}[ ON  ]${CR}" || echo -e "${RD}[ OFF ]${CR}")"
    echo ""
    echo -e "  ${WH}¿Cómo funciona el Fallback?${CR}"
    echo -e "  ${DM}• ${GR}ON (Recomendado)${CR}: Si el PC doméstico se apaga o pierde Internet,${CR}"
    echo -e "  ${DM}  el tráfico de HTTP Injector vuelve temporalmente a la IP de la VPS.${CR}"
    echo -e "  ${DM}  Los clientes no se quedan sin navegación.${CR}"
    echo -e "  ${DM}• ${RD}OFF${CR}: Si el PC doméstico cae, el tráfico de HTTP Injector se detiene${CR}"
    echo -e "  ${DM}  hasta que el gateway residencial vuelva a estar disponible (cero fugas).${CR}"
    echo -e "  ${YL}[!] El acceso SSH administrativo NUNCA se ve afectado en ningún caso.${CR}"
    echo ""
    echo -e "  ${CY}1)${CR} Activar Fallback   ${GR}[ ON  ]${CR}"
    echo -e "  ${CY}2)${CR} Desactivar Fallback ${RD}[ OFF ]${CR}"
    echo -e "  ${CY}0)${CR} Cancelar"
    echo -e "$SEP"
    read -p "$(echo -e ${DM})Elige [0-2]: $(echo -e ${CR})" fb_opt

    case "$fb_opt" in
        1)
            _wgh_set_fallback "ON"
            echo -e "  ${GR}[+] Fallback activado (ON).${CR}"; sleep 1 ;;
        2)
            _wgh_set_fallback "OFF"
            echo -e "  ${YL}[*] Fallback desactivado (OFF).${CR}"; sleep 1 ;;
        *)
            ;;
    esac
}

# =========================================================
# CAMBIO 4 & 5: APLICACIÓN Y REMOCIÓN DE REGLAS DE ENRUTAMIENTO
# =========================================================

# Aplica las marcas de iptables y reglas ip rule de forma idempotente y segura
_wgh_apply_user_routing() {
    _wgh_ensure_rt_table
    _wgh_enable_forwarding
    _wgh_fix_rp_filter

    local droplet_pub_ip
    droplet_pub_ip=$(_wgh_get_droplet_ip)

    # --- Exclusiones: se ponen UNA vez, valen para todos los nodos ---
    # Nada de esto debe marcarse nunca, o el propio tunel, el SSH de
    # administracion o el trafico entre nodos se irian por la casa.
    local -a excludes=(
        "-d 127.0.0.0/8"
        "-d 10.77.0.0/16"
        "-p tcp --sport 22"
    )
    [ -n "$droplet_pub_ip" ] && excludes+=("-d ${droplet_pub_ip}")
    local i
    for i in $(seq 1 16); do
        excludes+=("-p udp --dport $(_wgn_port "$i")" "-p udp --sport $(_wgn_port "$i")")
    done
    [ -n "$PORT_SSH" ] && [ "$PORT_SSH" != "22" ] && excludes+=("-p tcp --sport ${PORT_SSH}")
    [ -n "$PORT_SSL" ] && excludes+=("-p tcp --sport ${PORT_SSL}")
    [ -n "$PORT_WS" ]  && excludes+=("-p tcp --sport ${PORT_WS}")
    [ -n "$PORT_DROPBEAR" ] && excludes+=("-p tcp --sport ${PORT_DROPBEAR}")

    local exc
    for exc in "${excludes[@]}"; do
        # shellcheck disable=SC2086
        iptables -t mangle -C OUTPUT $exc -m comment --comment "HOMEVPN_EXCLUDE" -j RETURN 2>/dev/null || \
            iptables -t mangle -I OUTPUT 1 $exc -m comment --comment "HOMEVPN_EXCLUDE" -j RETURN 2>/dev/null || true
    done

    # --- Una tabla, una regla y una marca por nodo ---
    # Aqui esta la diferencia con el modelo de una sola salida: cada
    # nodo tiene su propia default en su propia tabla, y a cada
    # usuario se le pone la marca del nodo que le toca. Dos usuarios
    # pueden salir por sitios distintos al mismo tiempo.
    local name key idx type ifc mark tbl nodeip redport total_users=0
    while IFS='|' read -r name key idx type; do
        [ -z "$idx" ] && continue
        mark=$(_wgn_mark "$idx")

        if [ "${type:-wg}" = "socks" ]; then
            # Nodo movil: sin ruta ni interfaz. redsocks toma el trafico
            # marcado y lo entrega al SOCKS inverso del telefono.
            redport=$(_wgn_redport "$idx")
            _socks_up "$idx" >/dev/null 2>&1 || true
            # Solo TCP: el SOCKS no transporta UDP. El DNS resuelve en el VPS.
            iptables -t nat -C OUTPUT -p tcp -m mark --mark "${mark}" -m comment --comment "HOMEVPN_SOCKS" -j REDIRECT --to-ports "${redport}" 2>/dev/null || \
                iptables -t nat -A OUTPUT -p tcp -m mark --mark "${mark}" -m comment --comment "HOMEVPN_SOCKS" -j REDIRECT --to-ports "${redport}" 2>/dev/null || true
        else
            ifc=$(_wgn_iface "$idx"); tbl=$(_wgn_table "$idx"); nodeip=$(_wgn_nodeip "$idx")

            ip route replace default via "${nodeip}" dev "${ifc}" table "${tbl}" 2>/dev/null

            ip rule show | grep -q "fwmark ${mark} lookup ${tbl}" || \
                ip rule add fwmark "${mark}" table "${tbl}" priority $(( 1000 + idx )) 2>/dev/null || true

            # Regla por origen: lo que salga con la IP de esta interfaz usa
            # su tabla. Sin esto, un 'curl --interface wg-homeN' se va por
            # eth0 con un origen que no le corresponde, y la comprobacion
            # de IP de salida da un resultado enganoso.
            ip rule show | grep -q "from $(_wgn_vpsip "$idx") lookup ${tbl}" || \
                ip rule add from "$(_wgn_vpsip "$idx")" table "${tbl}" priority $(( 900 + idx )) 2>/dev/null || true

            # El tunel recorta el MTU. Sin ajustar el MSS el handshake TCP
            # pasa y luego las paginas grandes se quedan a medias: el fallo
            # tipico de "conecta pero no carga".
            iptables -t mangle -C POSTROUTING -o "${ifc}" -p tcp --tcp-flags SYN,RST SYN -m comment --comment "HOMEVPN_MSS" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
                iptables -t mangle -A POSTROUTING -o "${ifc}" -p tcp --tcp-flags SYN,RST SYN -m comment --comment "HOMEVPN_MSS" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

            # NAT y reenvio de esta interfaz
            iptables -t nat -C POSTROUTING -o "${ifc}" -m comment --comment "HOMEVPN_NAT" -j MASQUERADE 2>/dev/null || \
                iptables -t nat -A POSTROUTING -o "${ifc}" -m comment --comment "HOMEVPN_NAT" -j MASQUERADE 2>/dev/null || true
            iptables -C FORWARD -o "${ifc}" -m comment --comment "HOMEVPN_FORWARD" -j ACCEPT 2>/dev/null || \
                iptables -A FORWARD -o "${ifc}" -m comment --comment "HOMEVPN_FORWARD" -j ACCEPT 2>/dev/null || true
            iptables -C FORWARD -i "${ifc}" -m state --state RELATED,ESTABLISHED -m comment --comment "HOMEVPN_FORWARD" -j ACCEPT 2>/dev/null || \
                iptables -A FORWARD -i "${ifc}" -m state --state RELATED,ESTABLISHED -m comment --comment "HOMEVPN_FORWARD" -j ACCEPT 2>/dev/null || true
        fi

        # Marcar por UID a los usuarios asignados a ESTE nodo
        local u uid n=0
        while IFS= read -r u; do
            [ -z "$u" ] && continue
            uid=$(id -u "$u" 2>/dev/null || true)
            [ -z "$uid" ] && continue
            [ "$uid" -ge 1000 ] 2>/dev/null || continue
            iptables -t mangle -C OUTPUT -m owner --uid-owner "$uid" -m comment --comment "HOMEVPN_MARK" -j MARK --set-mark "${mark}" 2>/dev/null || \
                iptables -t mangle -A OUTPUT -m owner --uid-owner "$uid" -m comment --comment "HOMEVPN_MARK" -j MARK --set-mark "${mark}" 2>/dev/null || true
            n=$((n+1))
        done < <(_wgh_node_users "$name")
        total_users=$(( total_users + n ))
        _wgh_log "Nodo ${name} (${ifc}, marca ${mark}, tabla ${tbl}): ${n} usuario(s)"
    done < <(_wgh_nodes_list)

    _wgh_isolate_on
    _wgh_log "Enrutamiento por usuario aplicado: ${total_users} usuario(s) sobre $(_wgh_nodes_count) nodo(s)"
}

# Elimina ÚNICAMENTE las reglas creadas por este módulo (CAMBIO 7)
_wgh_routing_off_internal() {
    _wgh_log "Desactivando salida residencial..."
    _wgh_backup &>/dev/null

    # Con varios nodos hay una tabla y una regla por cada uno, asi que
    # limpiar solo la 200 dejaria a los demas enrutando a medias.
    local i tbl mark
    for i in $(seq 1 16); do
        tbl=$(_wgn_table "$i"); mark=$(_wgn_mark "$i")
        while ip rule show | grep -q "fwmark ${mark} lookup ${tbl}"; do
            ip rule del fwmark "${mark}" table "${tbl}" 2>/dev/null || break
        done
        while ip rule show | grep -qE "lookup ${tbl}\b"; do
            ip rule del table "${tbl}" 2>/dev/null || break
        done
        ip route flush table "${tbl}" 2>/dev/null || true
    done

    # Reglas propias, identificadas por su comentario. Se borran solo
    # las nuestras: el cortafuegos que ya tuviera el VPS no se toca.
    while iptables -t mangle -D OUTPUT -m comment --comment "HOMEVPN_MARK" 2>/dev/null; do :; done
    local rule
    for tag in HOMEVPN_MARK HOMEVPN_HTTP_INJECTOR HOMEVPN_EXCLUDE HOMEVPN_MSS; do
        while iptables -S -t mangle 2>/dev/null | grep -q "$tag"; do
            rule=$(iptables -S -t mangle 2>/dev/null | grep "$tag" | head -1 | sed 's/^-A /-D /')
            [ -z "$rule" ] && break
            # shellcheck disable=SC2086
            iptables -t mangle $rule 2>/dev/null || break
        done
    done
    for tag in HOMEVPN_NAT HOMEVPN_SOCKS; do
        while iptables -S -t nat 2>/dev/null | grep -q "$tag"; do
            rule=$(iptables -S -t nat 2>/dev/null | grep "$tag" | head -1 | sed 's/^-A /-D /')
            [ -z "$rule" ] && break
            # shellcheck disable=SC2086
            iptables -t nat $rule 2>/dev/null || break
        done
    done
    # Apagar los redsocks de los nodos socks: sin usuarios enrutados no
    # tienen nada que hacer, y asi no dejan un servicio suelto corriendo.
    local sidx styp sname skey
    while IFS='|' read -r sname skey sidx styp; do
        [ "${styp:-wg}" = "socks" ] && _socks_down "$sidx"
    done < <(_wgh_nodes_list)
    while iptables -S FORWARD 2>/dev/null | grep -q "HOMEVPN_FORWARD"; do
        rule=$(iptables -S FORWARD 2>/dev/null | grep "HOMEVPN_FORWARD" | head -1 | sed 's/^-A /-D /')
        [ -z "$rule" ] && break
        # shellcheck disable=SC2086
        iptables $rule 2>/dev/null || break
    done
    _wgh_isolate_off

    _wgh_verify_ssh_route
    _wgh_log "Desactivacion completada"
}

# =========================================================
# 1. INSTALAR / CONFIGURAR GATEWAY RESIDENCIAL
# =========================================================
wghome_install() {
    clear
    print_title 2>/dev/null || true
    echo -e "$SEP"
    echo -e "${WH}     INSTALAR GATEWAY RESIDENCIAL (WireGuard)${CR}"
    echo -e "$SEP"

    if _wgh_is_installed; then
        echo -e "  ${YL}[!]${CR} El gateway ya está configurado."
        echo -e "  ${DM}    Conf: ${WGH_CONF}${CR}"
        echo ""
        read -p "$(echo -e ${DM})¿Reinstalar/sobreescribir? (s/n): $(echo -e ${CR})" resp
        if [[ "$resp" != "s" && "$resp" != "S" ]]; then
            echo -e "  ${GR}[+]${CR} Operación cancelada."; sleep 1; return
        fi
        systemctl stop "wg-quick@${WGH_IFACE}" 2>/dev/null
    fi

    # Paso 1: Instalar WireGuard
    echo ""
    _wgh_ensure_installed || { sleep 2; return 1; }

    # Paso 2: Habilitar forwarding
    echo -e "  ${YL}[*]${CR} Habilitando IP forwarding..."
    _wgh_enable_forwarding
    echo -e "  ${GR}[+]${CR} IP forwarding activo."

    # Paso 3: Registrar tabla de rutas
    _wgh_ensure_rt_table

    # Paso 4: Claves de la Droplet
    # Regenerarlas invalida a TODOS los nodos a la vez: siguen
    # cifrando sus saludos contra una clave publica que este
    # servidor ya no tiene, y WireGuard los descarta sin decir nada.
    # Antes se rehacian en cada reinstalacion, en silencio.
    mkdir -p /etc/wireguard
    if [ -s "${WGH_PRIV_KEY}" ]; then
        echo ""
        echo -e "  ${YL}[!]${CR} Esta Droplet ya tiene su par de claves."
        echo -e "  ${DM}      Publica actual: $(cat "${WGH_PUB_KEY}" 2>/dev/null)${CR}"
        echo -e "  ${RD}[!]${CR} Generar unas nuevas DESCONECTA todos los nodos"
        echo -e "  ${DM}      registrados: habria que reconfigurarlos uno a uno.${CR}"
        echo ""
        if ui_confirm "¿Conservar las claves actuales?" "s"; then
            [ -s "${WGH_PUB_KEY}" ] || wg pubkey < "${WGH_PRIV_KEY}" > "${WGH_PUB_KEY}"
            echo -e "  ${GR}[+]${CR} Claves conservadas: los nodos siguen validos."
        else
            (umask 077; wg genkey > "${WGH_PRIV_KEY}")
            wg pubkey < "${WGH_PRIV_KEY}" > "${WGH_PUB_KEY}"
            _wgh_log "Claves de la Droplet REGENERADAS: nodos invalidados"
            echo -e "  ${YL}[!]${CR} Claves nuevas. Actualiza la clave del VPS en cada nodo."
        fi
    else
        echo -e "  ${YL}[*]${CR} Generando par de claves para la Droplet..."
        (umask 077; wg genkey > "${WGH_PRIV_KEY}")
        wg pubkey < "${WGH_PRIV_KEY}" > "${WGH_PUB_KEY}"
        echo -e "  ${GR}[+]${CR} Claves generadas (privada protegida chmod 600)."
    fi
    chmod 600 "${WGH_PRIV_KEY}"
    chmod 644 "${WGH_PUB_KEY}"

    # Paso 5: Crear wg-home.conf con Table = off y AllowedIPs = 0.0.0.0/0
    echo -e "  ${YL}[*]${CR} Creando ${WGH_CONF}..."
    local priv peer_pub=""
    priv=$(cat "${WGH_PRIV_KEY}")
    [ -f "${WGH_PEER_KEY}" ] && peer_pub=$(cat "${WGH_PEER_KEY}" 2>/dev/null)

    _wgh_render_conf "$priv" "$peer_pub" > "${WGH_CONF}"
    chmod 600 "${WGH_CONF}"
    echo -e "  ${GR}[+]${CR} ${WGH_CONF} creado con Table = off (seguridad SSH)."

    # Paso 6: Abrir firewall
    _wgh_open_firewall

    # Paso 7: Habilitar servicio systemd
    systemctl enable "wg-quick@${WGH_IFACE}" &>/dev/null
    echo -e "  ${GR}[+]${CR} Servicio wg-quick@${WGH_IFACE} habilitado."
    # 'enable' solo programa el arranque futuro. Sin este 'start' la
    # Droplet quedaba instalada pero sin escuchar, y los nodos
    # enviaban handshakes contra un puerto que no atendia nadie.
    systemctl start "wg-quick@${WGH_IFACE}" &>/dev/null
    _wgh_nodes_up_all
    if _wgh_is_up; then
        echo -e "  ${GR}[+]${CR} Túnel ${WGH_IFACE} levantado y escuchando en ${WGH_PORT}/UDP."
    else
        echo -e "  ${YL}[!]${CR} El túnel no arrancó todavía (normal si aún no hay nodos)."
    fi

    # Inicializar fallback por defecto en ON si no existe
    [ ! -f "$WGH_FALLBACK_CONF" ] && _wgh_set_fallback "ON"

    _wgh_nodes_migrate
    _wgh_log "Gateway residencial instalado exitosamente"

    echo ""
    echo -e "$SEP"
    echo -e "  ${GR}[+] ¡Instalación completada!${CR}"
    echo ""
    echo -e "  ${YL}[!] Pasos siguientes:${CR}"
    echo -e "  ${DM}  1. Consulta la clave pública del Droplet (opción 2).${CR}"
    echo -e "  ${DM}  2. Configura tu PC doméstico (CachyOS) con esa clave.${CR}"
    echo -e "  ${DM}  3. Registra la clave del PC en el panel (opción 3).${CR}"
    echo -e "  ${DM}  4. Activa el túnel (opción 4).${CR}"
    echo -e "  ${DM}  5. Configura los usuarios HTTP Injector (opción 12).${CR}"
    echo -e "  ${DM}  6. Activa la salida residencial (opción 8).${CR}"
    echo -e "$SEP"
    read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
}

# =========================================================
# 2. MOSTRAR CLAVE PÚBLICA DE LA DROPLET
# =========================================================
wghome_show_pubkey() {
    clear
    print_title 2>/dev/null || true
    echo -e "$SEP"
    echo -e "${WH}     DATOS PARA CONFIGURAR UN NODO${CR}"
    echo -e "$SEP"

    if [ ! -f "${WGH_PUB_KEY}" ]; then
        echo -e "  ${RD}[-]${CR} No se encontró la clave pública."
        echo -e "  ${DM}    Instala el gateway primero (opción 1).${CR}"
        sleep 2; return
    fi

    local pub ip_pub
    pub=$(cat "${WGH_PUB_KEY}")
    ip_pub=$(_wgh_get_droplet_ip)

    echo ""
    if [ -n "$ip_pub" ]; then
        echo -e "  ${DM}IP pública Droplet :${CR} ${GR}${ip_pub}${CR}"
        echo -e "  ${DM}   ${YL}Comprueba que es la misma por la que entras por SSH.${CR}"
        echo -e "  ${DM}   Si no lo es, corrígela en GESTIONAR NODOS > [5].${CR}"
    else
        echo -e "  ${RD}IP pública Droplet : NO SE PUDO AVERIGUAR${CR}"
        echo -e "  ${DM}   Fíjala a mano en GESTIONAR NODOS > [5]; sin ella los${CR}"
        echo -e "  ${DM}   nodos no saben a dónde abrir el túnel.${CR}"
        ip_pub="<PON_AQUI_LA_IP_DEL_VPS>"
    fi
    echo -e "  ${DM}Puerto WireGuard   :${CR} ${CY}${WGH_PORT}/UDP${CR}"
    echo ""
    echo -e "  ${YL}[ Clave Pública de la Droplet ]${CR}"
    echo -e "  ${WH}${pub}${CR}"
    echo -e "  ${DM}Esta va en el campo PublicKey del nodo.${CR}"
    echo ""

    _wgh_nodes_migrate
    local total
    total=$(_wgh_nodes_count)

    if [ "${total:-0}" -eq 0 ]; then
        echo -e "$SEP"
        echo -e "  ${YL}[!]${CR} Todavía no hay ningún nodo registrado."
        echo -e "  ${DM}    Regístralo primero en GESTIONAR NODOS: allí se le${CR}"
        echo -e "  ${DM}    asigna su dirección, y sin ella esta pantalla no${CR}"
        echo -e "  ${DM}    puede decirte qué poner en el campo Address.${CR}"
        echo -e "$SEP"
        read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
        return
    fi

    # Cada nodo tiene SU direccion. Enseñar una plantilla con la IP
    # fija de antes hacia que el segundo nodo se configurase con la
    # del primero, y entonces la Droplet le rechazaba los paquetes
    # por venir de una IP fuera de su AllowedIPs.
    echo -e "$SEP"
    echo -e "  ${WH}Nodos registrados${CR}"
    echo ""
    local name key idx type n=0 etiq
    while IFS='|' read -r name key idx type; do
        [ -z "$idx" ] && continue
        n=$((n+1))
        if [ "${type:-wg}" = "socks" ]; then
            etiq="${DM}movil (SOCKS)${CR}"
        else
            etiq="${CY}$(_wgn_nodeip "$idx")${CR}"
        fi
        echo -e "  ${CY}[$n]${CR} ${WH}${name}${CR} ${DM}—${CR} ${etiq}"
    done < <(_wgh_nodes_list)

    echo ""
    read -p "$(echo -e ${DM})¿De qué nodo quieres la configuración? [1-${n}] (Enter = salir): $(echo -e ${CR})" pick
    [ -z "$pick" ] && return

    local line
    line=$(_wgh_nodes_list | sed -n "${pick}p")
    [ -z "$line" ] && { echo -e "  ${RD}[-]${CR} Opción no válida."; sleep 2; return; }

    local n_name n_key n_idx n_type
    n_name=$(echo "$line" | cut -d'|' -f1)
    n_key=$(echo "$line" | cut -d'|' -f2)
    n_idx=$(echo "$line" | cut -d'|' -f3)
    n_type=$(echo "$line" | cut -d'|' -f4); [ -z "$n_type" ] && n_type="wg"

    # Un nodo movil no lleva config WireGuard: se le enseñan los pasos
    # de Termux, que es lo unico que necesita para conectarse.
    if [ "$n_type" = "socks" ]; then
        _socks_show_instructions "$n_idx" "$n_name"
        return
    fi
    local n_ip
    n_ip=$(_wgn_nodeip "$n_idx")

    clear
    print_title 2>/dev/null || true
    echo -e "$SEP"
    echo -e "${WH}     CONFIGURACIÓN DEL NODO: ${n_name}${CR}"
    echo -e "$SEP"
    echo ""
    echo -e "  ${DM}Dirección asignada :${CR} ${CY}${n_ip}${CR}"
    echo -e "  ${DM}Clave registrada   :${CR} ${DM}${n_key}${CR}"
    echo ""
    echo -e "  ${YL}━━━ Si usas el panel del nodo (node.sh) ━━━${CR}"
    echo -e "  ${DM}En su asistente, cuando pida los datos:${CR}"
    echo -e "  ${DM}  Host del VPS :${CR} ${WH}${ip_pub}${CR}"
    echo -e "  ${DM}  Puerto       :${CR} ${WH}${WGH_PORT}${CR}"
    echo -e "  ${DM}  Clave del VPS:${CR} ${WH}${pub}${CR}"
    echo -e "  ${DM}  IP del nodo  :${CR} ${GR}${n_ip}${CR}  ${YL}<-- esta, no otra${CR}"
    echo ""
    echo -e "  ${YL}━━━ Si lo configuras a mano ━━━${CR}"
    echo -e "  ${DM}En /etc/wireguard/wg-home.conf del nodo:${CR}"
    echo ""
    echo -e "  ${CY}[Interface]${CR}"
    echo -e "  ${WH}PrivateKey          = <LA PRIVADA DE ESE EQUIPO>${CR}"
    echo -e "  ${WH}Address             = ${n_ip}/24${CR}"
    echo ""
    echo -e "  ${CY}[Peer]${CR}"
    echo -e "  ${WH}PublicKey           = ${pub}${CR}"
    echo -e "  ${WH}Endpoint            = ${ip_pub}:${WGH_PORT}${CR}"
    echo -e "  ${WH}AllowedIPs          = ${WGH_DROPLET_IP}/32${CR}"
    echo -e "  ${WH}PersistentKeepalive = 25${CR}"
    echo ""
    echo -e "  ${DM}Y para compartir su salida a Internet (ajusta la interfaz):${CR}"
    echo -e "  ${DM}PostUp   = iptables -A FORWARD -i ${WGH_IFACE} -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE${CR}"
    echo -e "  ${DM}PostDown = iptables -D FORWARD -i ${WGH_IFACE} -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE${CR}"
    echo ""
    echo -e "  ${YL}[!] La clave privada de la Droplet NUNCA se comparte.${CR}"
    echo -e "  ${YL}[!] La privada del nodo se queda en el nodo: aquí solo${CR}"
    echo -e "  ${DM}      se guarda su clave pública.${CR}"
    echo -e "$SEP"
    read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
}

# =========================================================
# 3. REGISTRAR CLAVE PÚBLICA DEL PC DOMÉSTICO
# =========================================================
# Aplica el conf regenerado sobre la interfaz sin cortar el tunel.
_wgh_nodes_sync() {
    local priv
    priv=$(cat "${WGH_PRIV_KEY}" 2>/dev/null)
    [ -z "$priv" ] && return 1
    _wgh_render_conf "$priv" > "${WGH_CONF}"
    chmod 600 "${WGH_CONF}"
    if _wgh_is_up; then
        wg syncconf "${WGH_IFACE}" <(wg-quick strip "${WGH_IFACE}" 2>/dev/null) 2>/dev/null || \
            systemctl restart "wg-quick@${WGH_IFACE}" 2>/dev/null
        _wgh_isolate_on
    fi
}

# =========================================================
# GESTION DE NODOS RESIDENCIALES
# =========================================================
wghome_manage_nodes() {
    _wgh_nodes_migrate
    while true; do
        clear
        print_title 2>/dev/null || true
        ui_section "NODOS RESIDENCIALES" "cada uno con su propia salida"
        ui_blank

        local total
        total=$(_wgh_nodes_count)
        if [ "${total:-0}" -eq 0 ]; then
            echo -e "${UI_PAD}${DM}No hay ningun nodo registrado todavia.${CR}"
        else
            printf "${UI_PAD}${DM}%-13s %-6s %-10s %-7s %s${CR}\n" "NOMBRE" "TIPO" "PUERTO" "USUAR." "ESTADO"
            local name key idx type hs est nu tipo puerto
            while IFS='|' read -r name key idx type; do
                [ -z "$idx" ] && continue
                type="${type:-wg}"
                nu=$(_wgh_node_users "$name" | wc -l)
                if [ "$type" = "socks" ]; then
                    tipo="movil"; puerto=$(_wgn_socksport "$idx")
                    if _socks_reverse_up "$idx"; then
                        est="${GR}conectado${CR}"
                    elif _socks_redsocks_up "$idx"; then
                        est="${YL}esperando movil${CR}"
                    else
                        est="${RD}apagado${CR}"
                    fi
                else
                    tipo="wg"; puerto=$(_wgn_port "$idx")
                    if ! _wgh_node_is_up "$idx"; then
                        est="${RD}apagado${CR}"
                    else
                        hs=$(_wgh_node_hs "$idx")
                        if [ "$hs" -ge 0 ] 2>/dev/null && [ "$hs" -lt 180 ]; then
                            est="${GR}conectado (${hs}s)${CR}"
                        elif [ "$hs" -ge 0 ] 2>/dev/null; then
                            est="${YL}visto hace ${hs}s${CR}"
                        else
                            est="${YL}sin handshake${CR}"
                        fi
                    fi
                fi
                printf "${UI_PAD}${WH}%-13s${CR} ${DM}%-6s${CR} ${CY}%-10s${CR} ${WH}%-7s${CR} %b\n" \
                    "$name" "$tipo" "$puerto" "$nu" "$est"
            done < <(_wgh_nodes_list)
        fi

        ui_blank
        ui_rule
        echo -e "${UI_PAD}${DM}Varios nodos pueden dar salida A LA VEZ: cada usuario${CR}"
        echo -e "${UI_PAD}${DM}sale por el nodo que le asignes. Entre ellos no se ven.${CR}"
        ui_blank

        ui_opt "1" "REGISTRAR NODO PC"  "WireGuard"
        ui_opt "6" "REGISTRAR NODO MOVIL" "celular sin root"
        ui_opt "2" "ASIGNAR USUARIOS"  "quien sale por donde"
        ui_opt "3" "DATOS PARA EL NODO" "que poner alli"
        ui_opt "5" "DIRECCION PUBLICA"  "endpoint del VPS"
        ui_opt_danger "4" "ELIMINAR NODO" "lo desconecta"
        ui_opt "0" "VOLVER"
        ui_solid
        ui_prompt "Elige una opcion [0-6]"

        case "$REPLY_UI" in
            1)  ui_blank
                read -p "$(echo -e "${UI_PAD}${DM}Nombre corto (ej: pc, movil) ${CY}»${CR} ")" nname
                nname=$(echo "$nname" | tr -cd 'A-Za-z0-9_-' | cut -c1-14)
                [ -z "$nname" ] && { ui_err "Nombre vacio."; sleep 1; continue; }
                _wgh_node_exists "$nname" && { ui_err "Ya existe ese nodo."; sleep 2; continue; }
                read -p "$(echo -e "${UI_PAD}${DM}Clave publica del nodo ${CY}»${CR} ")" nkey
                nkey=$(echo "$nkey" | tr -d '[:space:]')
                if ! echo "$nkey" | grep -qE '^[A-Za-z0-9+/]{43}=$'; then
                    ui_err "Formato de clave no valido (44 car. base64)."; sleep 2; continue
                fi
                _wgh_nodes_has_key "$nkey" && { ui_err "Esa clave ya esta registrada."; sleep 2; continue; }
                local nidx
                nidx=$(_wgh_nodes_add "$nname" "$nkey")
                [ -z "$nidx" ] && { ui_err "No quedan indices libres."; sleep 2; continue; }
                ui_blank
                ui_info "Levantando su interfaz..."
                if _wgh_node_up "$nidx"; then ui_ok "Interfaz $(_wgn_iface "$nidx") activa."
                else ui_warn "La interfaz no arranco; revisa con la opcion 9."; fi
                ui_blank
                ui_ok "Nodo '${nname}' registrado."
                echo -e "${UI_PAD}${DM}   Configura EN EL NODO estos valores exactos:${CR}"
                echo -e "${UI_PAD}${DM}     Puerto del VPS :${CR} ${WH}$(_wgn_port "$nidx")${CR}"
                echo -e "${UI_PAD}${DM}     IP del nodo    :${CR} ${GR}$(_wgn_nodeip "$nidx")${CR}"
                echo -e "${UI_PAD}${DM}     IP del VPS     :${CR} ${WH}$(_wgn_vpsip "$nidx")${CR}"
                echo -e "${UI_PAD}${DM}   (opcion 3 te los repite cuando quieras)${CR}"
                ui_pause ;;
            6)  wghome_register_socks ;;
            2)  wghome_assign_users ;;
            3)  wghome_show_pubkey ;;
            5)  wghome_fix_endpoint ;;
            4)  ui_blank
                read -p "$(echo -e "${UI_PAD}${DM}Nombre del nodo a eliminar ${CY}»${CR} ")" dname
                _wgh_node_exists "$dname" || { ui_err "No existe ese nodo."; sleep 2; continue; }
                if ui_confirm "¿Eliminar '${dname}'? Sus usuarios volveran a la IP del VPS" "n"; then
                    _wgh_nodes_del "$dname"
                    _wgh_routing_is_active && _wgh_apply_user_routing
                    ui_ok "Nodo eliminado."
                fi
                ui_pause ;;
            0)  break ;;
            *)  ui_err "Opcion no valida."; sleep 1 ;;
        esac
    done
}

# =========================================================
# ASIGNAR CADA USUARIO A SU NODO
# =========================================================
wghome_assign_users() {
    while true; do
        clear
        print_title 2>/dev/null || true
        ui_section "SALIDA POR USUARIO" "quien sale por que nodo"
        ui_blank

        if [ "$(_wgh_nodes_count)" -eq 0 ]; then
            ui_err "Registra algun nodo primero."
            ui_pause; return
        fi

        local -a us=()
        local u n i=0
        while IFS= read -r u; do
            [ -z "$u" ] && continue
            us+=("$u"); i=$((i+1))
            n=$(_wgh_user_node "$u")
            if [ -n "$n" ]; then
                printf "${UI_PAD}${CY}[%2d]${CR} ${WH}%-16s${CR} ${DM}sale por${CR} ${GR}%s${CR}\n" "$i" "$u" "$n"
            else
                printf "${UI_PAD}${CY}[%2d]${CR} ${WH}%-16s${CR} ${DM}sale por${CR} ${DM}la IP del VPS${CR}\n" "$i" "$u"
            fi
        done < <(_wgh_get_client_users | cut -d: -f1)

        [ ${#us[@]} -eq 0 ] && { ui_blank; ui_warn "No hay cuentas de cliente creadas."; ui_pause; return; }

        ui_blank
        ui_rule
        echo -e "${UI_PAD}${DM}Nodos disponibles: ${WH}$(_wgh_nodes_names | tr '\n' ' ')${CR}"
        echo -e "${UI_PAD}${DM}root y el SSH de administracion nunca se enrutan.${CR}"
        ui_blank
        ui_prompt "Numero del usuario a cambiar (0 = volver)"
        local pick="$REPLY_UI"
        [ "$pick" = "0" ] || [ -z "$pick" ] && return
        echo "$pick" | grep -qE '^[0-9]+$' || { ui_err "No es un numero."; sleep 1; continue; }
        [ "$pick" -ge 1 ] && [ "$pick" -le ${#us[@]} ] || { ui_err "Fuera de rango."; sleep 1; continue; }

        local target="${us[$((pick-1))]}"
        ui_blank
        echo -e "${UI_PAD}${DM}Nodo para ${WH}${target}${DM}. Escribe su nombre,${CR}"
        echo -e "${UI_PAD}${DM}o 'no' para que salga por la IP normal del VPS.${CR}"
        ui_prompt "Nodo"
        local nn="$REPLY_UI"
        if [ "$nn" = "no" ] || [ -z "$nn" ]; then
            _wgh_user_assign "$target" ""
            ui_ok "${target} sale ahora por la IP del VPS."
        elif _wgh_node_exists "$nn"; then
            _wgh_user_assign "$target" "$nn"
            ui_ok "${target} sale ahora por ${nn}."
        else
            ui_err "No existe el nodo '${nn}'."; sleep 2; continue
        fi

        # Aplicar en caliente: cambiar la asignacion y que no surta
        # efecto hasta reactivar seria una trampa facil de pisar.
        if _wgh_routing_is_active; then
            _wgh_apply_user_routing
            ui_ok "Cambio aplicado al instante."
        else
            ui_warn "La salida residencial esta apagada: se aplicara al encenderla."
        fi
        sleep 1
    done
}

# =========================================================
# 4. ACTIVAR TÚNEL WIREGUARD
# =========================================================
wghome_tunnel_up() {
    clear
    print_title 2>/dev/null || true
    echo -e "$SEP"
    echo -e "${WH}     ACTIVAR TÚNEL WireGuard${CR}"
    echo -e "$SEP"

    if ! _wgh_is_installed; then
        echo -e "  ${RD}[-]${CR} Gateway no instalado. Usa la opción 1."
        sleep 2; return
    fi

    _wgh_repair_conf_if_needed

    if ! grep -q "^\[Peer\]" "${WGH_CONF}" 2>/dev/null; then
        echo -e "  ${RD}[-]${CR} No hay Peer registrado en ${WGH_CONF}."
        echo -e "  ${YL}[!]${CR} Usa la opción 3 para registrar la clave del PC doméstico."
        sleep 2; return
    fi

    if _wgh_is_up; then
        echo -e "  ${YL}[!]${CR} El túnel ${WGH_IFACE} ya está activo."
        sleep 1; return
    fi

    echo -e "  ${YL}[*]${CR} Verificando que SSH no se verá afectado..."
    _wgh_verify_ssh_route || { sleep 2; return 1; }

    echo -e "  ${YL}[*]${CR} Levantando wg-quick@${WGH_IFACE}..."
    systemctl start "wg-quick@${WGH_IFACE}" 2>/dev/null
    sleep 2

    if _wgh_is_up; then
        echo -e "  ${GR}[+]${CR} Túnel ${WGH_IFACE} activo."
        echo ""
        echo -e "  ${DM}Interfaz:${CR}"
        ip addr show "${WGH_IFACE}" 2>/dev/null | grep -E "inet|link" | sed 's/^/    /'
        echo ""
        _wgh_verify_ssh_route && echo -e "  ${GR}[+]${CR} SSH protegido — tabla main intacta."
        _wgh_log "Túnel wg-home levantado"
    else
        echo -e "  ${RD}[-]${CR} Error levantando túnel. Revisa: journalctl -u wg-quick@${WGH_IFACE} -n 20"
        _wgh_log "ERROR al levantar túnel wg-home"
    fi

    echo ""
    read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
}

# =========================================================
# 5. DESACTIVAR TÚNEL WIREGUARD
# =========================================================
wghome_tunnel_down() {
    clear
    print_title 2>/dev/null || true
    echo -e "$SEP"
    echo -e "${WH}     DESACTIVAR TÚNEL WireGuard${CR}"
    echo -e "$SEP"

    if ! _wgh_is_up; then
        echo -e "  ${YL}[!]${CR} El túnel ${WGH_IFACE} ya está inactivo."
        sleep 1; return
    fi

    if _wgh_routing_is_active; then
        echo -e "  ${YL}[*]${CR} Desactivando salida residencial primero para evitar rutas huérfanas..."
        _wgh_routing_off_internal
    fi

    echo -e "  ${YL}[*]${CR} Deteniendo wg-quick@${WGH_IFACE}..."
    systemctl stop "wg-quick@${WGH_IFACE}" 2>/dev/null
    sleep 1

    if ! _wgh_is_up; then
        echo -e "  ${GR}[+]${CR} Túnel ${WGH_IFACE} desactivado."
        _wgh_verify_ssh_route && echo -e "  ${GR}[+]${CR} SSH protegido — ruta por defecto intacta."
        _wgh_log "Túnel wg-home detenido"
    else
        echo -e "  ${RD}[-]${CR} Error al detener el túnel."
    fi

    sleep 1
    read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
}


# =========================================================
# 7. PROBAR CONECTIVIDAD CON PC DOMÉSTICO
# =========================================================
wghome_ping_peer() {
    clear
    print_title 2>/dev/null || true
    echo -e "$SEP"
    echo -e "${WH}     PROBAR CONECTIVIDAD — PC Doméstico${CR}"
    echo -e "$SEP"
    echo ""

    if ! _wgh_is_up; then
        echo -e "  ${RD}[-]${CR} El túnel ${WGH_IFACE} no está activo."
        echo -e "  ${YL}[!]${CR} Activa el túnel primero (opción 4)."
        sleep 2; return
    fi

    local _pip; _pip=$(_wgh_nodes_first_ip)
    echo -e "  ${YL}[*]${CR} Haciendo ping a ${_pip} (nodo activo: $(_wgh_nodes_first_name))..."
    echo ""
    if ping -c 4 -W 2 "${_pip}" 2>/dev/null; then
        echo ""
        echo -e "  ${GR}[+] PC doméstico alcanzable vía WireGuard.${CR}"
        local hs_sec
        hs_sec=$(_wgh_handshake_seconds)
        if [ "$hs_sec" != "never" ] && [ "$hs_sec" -lt 180 ]; then
            echo -e "  ${GR}[+] Handshake WireGuard reciente (${hs_sec}s) — túnel saludable.${CR}"
        else
            echo -e "  ${YL}[!] Handshake no reciente. Verifica que PersistentKeepalive = 25 esté en el PC.${CR}"
        fi
    else
        echo ""
        echo -e "  ${RD}[-] No se pudo alcanzar el PC doméstico (10.77.77.2).${CR}"
        echo -e "  ${DM}  Causas comunes:${CR}"
        echo -e "  ${DM}  • El PC doméstico no está encendido o WireGuard está detenido en el PC.${CR}"
        echo -e "  ${DM}  • La clave pública del PC en la Droplet no coincide con la del PC.${CR}"
        echo -e "  ${DM}  • El firewall del PC bloquea ICMP o WireGuard.${CR}"
    fi

    echo ""
    read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
}

# =========================================================
# CAMBIO 6: 8. ACTIVAR SALIDA RESIDENCIAL (CON VALIDACIONES COMPLETAS)
# =========================================================
wghome_routing_on() {
    clear
    print_title 2>/dev/null || true
    echo -e "$SEP"
    echo -e "${WH}     ACTIVAR SALIDA RESIDENCIAL (HTTP Injector)${CR}"
    echo -e "$SEP"
    echo ""

    # VALIDACIÓN 1: Instalación
    if ! _wgh_is_installed; then
        echo -e "  ${RD}[-]${CR} Gateway no instalado. Usa la opción 1 primero."
        sleep 2; return
    fi

    # Asegurar corrección de AllowedIPs y Table = off
    _wgh_repair_conf_if_needed

    # Cuantos nodos de cada tipo hay: las comprobaciones de tunel,
    # handshake y ping solo tienen sentido si hay algun nodo WireGuard.
    local wg_count socks_count
    wg_count=$(_wgh_nodes_list | awk -F"|" '($4==""||$4=="wg"){c++}END{print c+0}')
    socks_count=$(_wgh_nodes_list | awk -F"|" '$4=="socks"{c++}END{print c+0}')

    # VALIDACIÓN 2: Túnel UP (solo si hay nodos WireGuard)
    if [ "$wg_count" -gt 0 ] && ! _wgh_is_up; then
        echo -e "  ${YL}[!]${CR} El túnel ${WGH_IFACE} no está activo."
        read -p "$(echo -e ${DM})¿Deseas levantar el túnel ahora? (s/n) [s]: $(echo -e ${CR})" autoup
        autoup=${autoup:-s}
        if [[ "$autoup" == "s" || "$autoup" == "S" ]]; then
            echo -e "  ${YL}[*]${CR} Levantando túnel wg-quick@${WGH_IFACE}..."
            systemctl start "wg-quick@${WGH_IFACE}" 2>/dev/null
            sleep 2
            if ! _wgh_is_up; then
                echo -e "  ${RD}[-]${CR} Error al iniciar el túnel. Revisa opción 4 y 6."
                sleep 2; return
            fi
            echo -e "  ${GR}[+]${CR} Túnel ${WGH_IFACE} activo."
        else
            echo -e "  ${GR}[+]${CR} Operación cancelada."; sleep 1; return
        fi
    fi

    # VALIDACIÓN 3: Idempotencia
    if _wgh_routing_is_active; then
        echo -e "  ${YL}[!]${CR} La salida residencial ya está activa."
        echo ""
        echo -e "  ${DM}Reglas actuales en ip rule:${CR}"
        ip rule show | grep -E "homevpn|${WGH_RT_TABLE}" | sed 's/^/    /'
        echo ""
        read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"; return
    fi

    echo -e "  ${YL}[*]${CR} Ejecutando comprobaciones de seguridad pre-activación..."
    echo ""

    # VALIDACIÓN 4: Seguridad de ruta SSH
    _wgh_verify_ssh_route || {
        echo -e "  ${RD}[!]${CR} Abortando por seguridad SSH."
        _wgh_log "Abortada activación: ruta SSH comprometida"
        sleep 3; return
    }

    # VALIDACIÓN 5: Handshake WireGuard (solo si hay nodos WireGuard)
    if [ "$wg_count" -gt 0 ] && ! _wgh_has_handshake; then
        echo -e "  ${YL}[!] ADVERTENCIA: No se detecta handshake reciente en WireGuard.${CR}"
        echo -e "  ${YL}[!] El PC doméstico puede no haber iniciado sesión aún.${CR}"
        echo ""
        read -p "$(echo -e ${DM})¿Continuar de todas formas? (s/n) [s]: $(echo -e ${CR})" resp
        resp=${resp:-s}
        if [[ "$resp" != "s" && "$resp" != "S" ]]; then
            echo -e "  ${GR}[+]${CR} Operación cancelada."; sleep 1; return
        fi
    fi

    # VALIDACIÓN 6: Conectividad ICMP al PC (solo con nodos WireGuard)
    if [ "$wg_count" -gt 0 ]; then
        local _aip; _aip=$(_wgh_nodes_first_ip)
        echo -e "  ${YL}[*]${CR} Verificando ping a ${_aip}..."
        if ! ping -c 2 -W 2 "${_aip}" &>/dev/null; then
            echo -e "  ${YL}[!] El PC doméstico no respondió al ping.${CR}"
            read -p "$(echo -e ${DM})¿Continuar aplicando configuración? (s/n) [s]: $(echo -e ${CR})" resp_ping
            resp_ping=${resp_ping:-s}
            if [[ "$resp_ping" != "s" && "$resp_ping" != "S" ]]; then
                echo -e "  ${GR}[+]${CR} Operación cancelada."; sleep 1; return
            fi
        else
            echo -e "  ${GR}[+]${CR} Conectividad con el nodo verificada [OK]."
        fi
    fi

    # VALIDACIÓN 7: Usuarios HTTP Injector configurados
    local -a conf_users=()
    if [ -f "$WGH_USERS_CONF" ]; then
        while IFS= read -r cu; do
            [ -n "$cu" ] && conf_users+=("$cu")
        done < <(_wgh_get_configured_users)
    fi

    if [ ${#conf_users[@]} -eq 0 ]; then
        echo -e "  ${YL}[!] No hay usuarios HTTP Injector seleccionados en ${WGH_USERS_CONF}.${CR}"
        echo -e "  ${DM}¿Deseas configurar los usuarios ahora? (s/n) [s]:${CR} "
        read -p "  > " cfg_now
        cfg_now=${cfg_now:-s}
        if [[ "$cfg_now" == "s" || "$cfg_now" == "S" ]]; then
            wghome_manage_users
            while IFS= read -r cu; do
                [ -n "$cu" ] && conf_users+=("$cu")
            done < <(_wgh_get_configured_users)
        fi
        if [ ${#conf_users[@]} -eq 0 ]; then
            echo -e "  ${YL}[!] Se activará el routing con regla de interfaz, pero añade usuarios en opción 12.${CR}"
        fi
    fi

    # Crear backup de seguridad previo
    local backup_path
    backup_path=$(_wgh_backup)
    echo -e "  ${GR}[+]${CR} Estado previo respaldado en: ${backup_path}"

    # Aplicar Policy Routing e iptables
    echo -e "  ${YL}[*]${CR} Instalando tabla 200 y reglas de enrutamiento por UID..."
    _wgh_apply_user_routing

    # Verificación post-activación
    echo ""
    echo -e "  ${YL}[*]${CR} Verificación final de seguridad SSH..."
    _wgh_verify_ssh_route && echo -e "  ${GR}[+]${CR} SSH protegido — tabla main intacta [OK]."

    echo ""
    if _wgh_routing_is_active; then
        echo -e "  ${GR}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CR}"
        echo -e "  ${GR}[✓] ¡SALIDA RESIDENCIAL ACTIVADA CON ÉXITO!${CR}"
        echo -e "  ${GR}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CR}"
        echo -e "  ${DM}• Usuarios HTTP Injector enrutados : ${WH}${#conf_users[@]}${CR}"
        echo -e "  ${DM}• Nodos activos                    : ${WH}${wg_count} wg + ${socks_count} movil${CR}"
        echo -e "  ${DM}• SSH Administrativo / root        : ${GR}Protegido (IP VPS)${CR}"
        echo -e "  ${DM}• Comprueba la IP residencial con la opción 10 del menú.${CR}"
    else
        echo -e "  ${RD}[-] Error: Las reglas no pudieron ser validadas en el kernel.${CR}"
    fi

    echo ""
    read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
}

# =========================================================
# CAMBIO 7: 9. DESACTIVAR SALIDA RESIDENCIAL
# =========================================================
wghome_routing_off() {
    clear
    print_title 2>/dev/null || true
    echo -e "$SEP"
    echo -e "${WH}     DESACTIVAR SALIDA RESIDENCIAL${CR}"
    echo -e "$SEP"
    echo ""

    if ! _wgh_routing_is_active; then
        echo -e "  ${YL}[!]${CR} La salida residencial no está activa."
        sleep 1; return
    fi

    echo -e "  ${YL}[*]${CR} Desactivando salida residencial de forma segura..."
    _wgh_routing_off_internal

    echo -e "  ${GR}[+]${CR} Reglas ip rule de tabla ${WGH_RT_NAME} eliminadas."
    echo -e "  ${GR}[+]${CR} Marcas de firewall HOMEVPN removidas limpiamente."
    echo -e "  ${GR}[+]${CR} Túnel ${WGH_IFACE} permanece activo."
    echo -e "  ${GR}[+]${CR} Tabla main intacta — SSH administrativo seguro."
    echo ""

    sleep 1
    read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
}

# =========================================================
# CAMBIO 8: 10. VER IP DE SALIDA (CORREGIDO SIN N/A)
# =========================================================
wghome_check_ip() {
    clear
    print_title 2>/dev/null || true
    ui_section "IP DE SALIDA" "por donde sale cada quien, de verdad"
    ui_blank

    local ip_normal
    ip_normal=$(_wgh_get_droplet_ip)
    echo -e "${UI_PAD}$(ui_cell "IP del VPS" "${ip_normal:-desconocida}" 40 "$WH")"
    echo -e "${UI_PAD}${DM}   Es la que ven los usuarios SIN nodo asignado.${CR}"
    ui_blank
    ui_rule
    ui_blank

    if [ "$(_wgh_nodes_count)" -eq 0 ]; then
        ui_warn "No hay nodos registrados."
        ui_pause; return
    fi

    if ! _wgh_routing_is_active; then
        ui_warn "La salida residencial esta apagada."
        echo -e "${UI_PAD}${DM}   Encendiendola, estas pruebas saldran por los nodos.${CR}"
        ui_blank
    fi

    # La prueba de verdad es salir COMO el usuario: recorre
    # exactamente el mismo camino que su trafico —su UID recibe la
    # marca, la marca elige la tabla, la tabla el nodo—. Probar con
    # 'curl --interface' solo demuestra que la interfaz existe, no
    # que el reparto por usuario funcione.
    local name key idx u probe ip_res
    while IFS='|' read -r name key idx; do
        [ -z "$idx" ] && continue
        echo -e "${UI_PAD}${WH}Nodo ${name}${CR} ${DM}($(_wgn_iface "$idx"), $(_wgn_nodeip "$idx"))${CR}"

        if ! _wgh_node_is_up "$idx"; then
            echo -e "${UI_PAD}  ${RD}interfaz apagada${CR}"
            ui_blank; continue
        fi
        if [ "$(_wgh_node_hs "$idx")" -lt 0 ] 2>/dev/null; then
            echo -e "${UI_PAD}  ${RD}sin handshake: el nodo no ha conectado nunca${CR}"
            ui_blank; continue
        fi

        probe=$(_wgh_node_users "$name" | head -1)
        if [ -z "$probe" ]; then
            echo -e "${UI_PAD}  ${YL}sin usuarios asignados${CR}"
            echo -e "${UI_PAD}  ${DM}Asignale alguno para poder probar su salida.${CR}"
            ui_blank; continue
        fi

        echo -e "${UI_PAD}  ${DM}Probando como '${probe}'...${CR}"
        ip_res=$(runuser -u "$probe" -- curl -4 -s --max-time 12 https://api.ipify.org 2>/dev/null)
        [ -z "$ip_res" ] && ip_res=$(runuser -u "$probe" -- curl -4 -s --max-time 12 https://ifconfig.me 2>/dev/null)

        if [ -z "$ip_res" ]; then
            echo -e "${UI_PAD}  ${RD}sin respuesta: el trafico no llega a Internet${CR}"
            echo -e "${UI_PAD}  ${DM}Revisa en el nodo que el reenvio y el NAT esten puestos.${CR}"
        elif [ "$ip_res" = "$ip_normal" ]; then
            echo -e "${UI_PAD}  ${YL}${ip_res}${CR} ${RD}<- es la IP del VPS, no la del nodo${CR}"
            echo -e "${UI_PAD}  ${DM}Su trafico no se esta desviando: comprueba que el${CR}"
            echo -e "${UI_PAD}  ${DM}usuario tenga UID >= 1000 y la salida este encendida.${CR}"
        else
            echo -e "${UI_PAD}  ${GR}${ip_res}${CR} ${DM}<- sale por el nodo${CR}"
        fi
        ui_blank
    done < <(_wgh_nodes_list)

    ui_solid
    read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
}

# =========================================================
# CAMBIO 9: 11. DIAGNÓSTICO COMPLETO ([OK], [WARN], [ERROR])
# =========================================================
wghome_diagnose() {
    clear
    print_title 2>/dev/null || true
    ui_section "DIAGNOSTICO DEL GATEWAY" "solo prueba lo que tienes montado"
    ui_blank

    _wgh_repair_conf_if_needed

    local wg_count socks_count
    wg_count=$(_wgh_nodes_list | awk -F'|' '($4==""||$4=="wg"){c++}END{print c+0}')
    socks_count=$(_wgh_nodes_list | awk -F'|' '$4=="socks"{c++}END{print c+0}')

    if [ "$((wg_count+socks_count))" -eq 0 ]; then
        ui_warn "No hay ningun nodo registrado. Registra uno en GESTIONAR NODOS."
        ui_solid; ui_pause; return
    fi

    echo -e "${UI_PAD}${DM}Nodos: ${WH}${wg_count}${DM} WireGuard  +  ${WH}${socks_count}${DM} movil (SOCKS)${CR}"
    ui_rule

    # ---- COMUN: seguridad de la ruta SSH (vale para ambos metodos) ----
    echo -e "${UI_PAD}${YL}[ COMUN ] Proteccion de la ruta SSH${CR}"
    local def_main
    def_main=$(ip route show table main 2>/dev/null | grep '^default' | head -1)
    if echo "$def_main" | grep -q "wg-home"; then
        echo -e "${UI_PAD}  ${RD}[ERROR]${CR} La ruta por defecto usa wg-home (SSH en riesgo): ${def_main}"
    else
        echo -e "${UI_PAD}  ${GR}[OK]${CR} Ruta por defecto intacta (SSH sale por la IP del VPS)"
    fi
    _wgh_routing_is_active && echo -e "${UI_PAD}  ${GR}[OK]${CR} Salida residencial: ACTIVA" \
                           || echo -e "${UI_PAD}  ${YL}[!]${CR} Salida residencial: APAGADA (enciendela para enrutar)"
    echo ""

    # ================= WIREGUARD (solo si hay nodos wg) =================
    if [ "$wg_count" -gt 0 ]; then
        echo -e "${UI_PAD}${YL}[ WIREGUARD ] Tuneles y salida${CR}"
        local name key idx type hs allowed
        while IFS='|' read -r name key idx type; do
            [ -z "$idx" ] && continue
            [ "${type:-wg}" = "socks" ] && continue
            if _wgh_node_is_up "$idx"; then
                hs=$(_wgh_node_hs "$idx")
                if [ "$hs" -ge 0 ] 2>/dev/null && [ "$hs" -lt 180 ]; then
                    echo -e "${UI_PAD}  ${GR}[OK]${CR} ${WH}${name}${CR} ($(_wgn_iface "$idx")): UP, handshake ${hs}s"
                else
                    echo -e "${UI_PAD}  ${YL}[!]${CR} ${WH}${name}${CR} ($(_wgn_iface "$idx")): UP, sin handshake reciente"
                fi
                ip -o link show "$(_wgn_iface "$idx")" &>/dev/null && \
                    ping -c1 -W2 "$(_wgn_nodeip "$idx")" &>/dev/null && \
                    echo -e "${UI_PAD}     ${GR}[OK]${CR} Ping al nodo $(_wgn_nodeip "$idx"): responde" || \
                    echo -e "${UI_PAD}     ${YL}[!]${CR} Ping al nodo $(_wgn_nodeip "$idx"): sin respuesta"
            else
                echo -e "${UI_PAD}  ${RD}[ERROR]${CR} ${WH}${name}${CR} ($(_wgn_iface "$idx")): DOWN"
            fi
        done < <(_wgh_nodes_list)
        allowed=$(grep -E '^\s*AllowedIPs\s*=' "${WGH_CONF}" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | xargs)
        [ "$allowed" = "0.0.0.0/0" ] && echo -e "${UI_PAD}  ${GR}[OK]${CR} AllowedIPs 0.0.0.0/0 (gateway de Internet)" \
                                     || echo -e "${UI_PAD}  ${YL}[!]${CR} AllowedIPs = ${allowed:-?} (deberia ser 0.0.0.0/0)"
        echo ""
    fi

    # =================== SOCKS (solo si hay nodos movil) ===================
    if [ "$socks_count" -gt 0 ]; then
        echo -e "${UI_PAD}${YL}[ SOCKS / MOVIL ] Tunel inverso y salida${CR}"
        local sname skey sidx stype
        while IFS='|' read -r sname skey sidx stype; do
            [ "${stype:-wg}" = "socks" ] || continue
            local sport redport user hay_llave
            sport=$(_wgn_socksport "$sidx"); redport=$(_wgn_redport "$sidx"); user=$(_wgn_socksuser "$sidx")
            echo -e "${UI_PAD}  ${WH}${sname}${CR} ${DM}(usuario ${user}, SOCKS ${sport})${CR}"

            # a) llave autorizada
            [ -s "/var/lib/vpsservice/${user}/.ssh/authorized_keys" ] && hay_llave=si || hay_llave=no
            [ "$hay_llave" = si ] && echo -e "${UI_PAD}     ${GR}[OK]${CR} Llave del nodo autorizada" \
                                  || echo -e "${UI_PAD}     ${RD}[ERROR]${CR} Sin llave autorizada (registra la clave del nodo)"

            # b) movil conectado (puerto inverso escuchando)
            if _socks_reverse_up "$sidx"; then
                echo -e "${UI_PAD}     ${GR}[OK]${CR} Movil conectado (SOCKS escuchando en 127.0.0.1:${sport})"
            else
                echo -e "${UI_PAD}     ${RD}[ERROR]${CR} Movil NO conectado (nadie escucha en ${sport})"
                echo -e "${UI_PAD}        ${DM}En el celular: abre el nodo y conecta (ssh -R).${CR}"
            fi

            # c) redsocks vivo
            if _socks_redsocks_up "$sidx"; then
                echo -e "${UI_PAD}     ${GR}[OK]${CR} redsocks activo ($(_socks_redunit "$sidx"), escucha ${redport})"
            else
                echo -e "${UI_PAD}     ${RD}[ERROR]${CR} redsocks caido ($(_socks_redunit "$sidx"))"
                local jerr
                jerr=$(journalctl -u "$(_socks_redunit "$sidx")" -n 2 --no-pager 2>/dev/null | tail -1)
                [ -n "$jerr" ] && echo -e "${UI_PAD}        ${DM}${jerr}${CR}"
            fi

            # d) regla de redireccion de la marca
            if _socks_redirect_present "$sidx"; then
                echo -e "${UI_PAD}     ${GR}[OK]${CR} Redireccion de la marca $(_wgn_mark "$sidx") -> redsocks activa"
            else
                echo -e "${UI_PAD}     ${YL}[!]${CR} Sin regla REDIRECT (enciende la salida residencial)"
            fi

            # e) usuarios asignados a este nodo
            local nu
            nu=$(_wgh_node_users "$sname" | tr '\n' ' ')
            [ -n "$nu" ] && echo -e "${UI_PAD}     ${GR}[OK]${CR} Usuarios: ${WH}${nu}${CR}" \
                         || echo -e "${UI_PAD}     ${YL}[!]${CR} Ningun usuario asignado a este nodo"

            # f) PRUEBA EN VIVO: salir a Internet por el movil
            if _socks_reverse_up "$sidx"; then
                echo -e "${UI_PAD}     ${DM}Probando salida real por el movil...${CR}"
                local exitip vpsip
                exitip=$(_socks_probe_ip "$sidx"); vpsip=$(_wgh_get_droplet_ip)
                if [ -z "$exitip" ]; then
                    echo -e "${UI_PAD}     ${RD}[ERROR]${CR} El SOCKS del movil no dio salida a Internet."
                    echo -e "${UI_PAD}        ${DM}El movil esta conectado pero su SOCKS no navega:${CR}"
                    echo -e "${UI_PAD}        ${DM}revisa que el telefono tenga datos y que el nodo${CR}"
                    echo -e "${UI_PAD}        ${DM}use reenvio dinamico (ssh -R sin destino).${CR}"
                elif [ "$exitip" = "$vpsip" ]; then
                    echo -e "${UI_PAD}     ${RD}[ERROR]${CR} La salida da la IP del VPS (${exitip}), no la del movil."
                else
                    echo -e "${UI_PAD}     ${GR}[OK]${CR} Salida por el movil: IP ${WH}${exitip}${CR} ${DM}(residencial)${CR}"
                fi
            fi
            echo ""
        done < <(_wgh_nodes_list)
        echo -e "${UI_PAD}${DM}Nota: el SOCKS transporta solo TCP. El DNS (UDP) resuelve${CR}"
        echo -e "${UI_PAD}${DM}en el VPS; las conexiones TCP salen por el movil.${CR}"
        echo ""
    fi

    # ---- COMUN: usuarios configurados ----
    local -a cusers=()
    while IFS= read -r cu; do [ -n "$cu" ] && cusers+=("$cu"); done < <(_wgh_get_configured_users)
    [ ${#cusers[@]} -gt 0 ] && echo -e "${UI_PAD}${GR}[OK]${CR} Usuarios enrutados en total: ${WH}${#cusers[@]}${CR}" \
                            || echo -e "${UI_PAD}${YL}[!]${CR} Ningun usuario asignado a salir por un nodo"

    ui_solid
    ui_pause
}

# =========================================================
# 12. ELIMINAR CONFIGURACIÓN COMPLETA
# =========================================================
wghome_remove() {
    clear
    print_title 2>/dev/null || true
    echo -e "$SEP"
    echo -e "${RD}     ⚠   ELIMINAR GATEWAY RESIDENCIAL   ⚠${CR}"
    echo -e "$SEP"
    echo ""
    echo -e "  ${YL}[!] Esta acción eliminará:${CR}"
    echo -e "  ${DM}  • /etc/wireguard/wg-home.conf${CR}"
    echo -e "  ${DM}  • /etc/wireguard/wghome_droplet_private.key${CR}"
    echo -e "  ${DM}  • /etc/wireguard/wghome_droplet_public.key${CR}"
    echo -e "  ${DM}  • /etc/wireguard/wghome_peer_public.key${CR}"
    echo -e "  ${DM}  • ${WGH_USERS_CONF} y ${WGH_FALLBACK_CONF}${CR}"
    echo -e "  ${DM}  • Servicio wg-quick@wg-home${CR}"
    echo -e "  ${DM}  • Reglas de tabla ${WGH_RT_NAME} (${WGH_RT_TABLE})${CR}"
    echo -e "  ${DM}  • Entrada en /etc/iproute2/rt_tables${CR}"
    echo ""
    read -p "$(echo -e ${DM})¿Continuar? (s/n): $(echo -e ${CR})" resp
    if [[ "$resp" != "s" && "$resp" != "S" ]]; then
        echo -e "  ${GR}[+] Operación cancelada.${CR}"; sleep 1; return
    fi

    read -p "$(echo -e ${RD})Escribe ELIMINAR para confirmar: $(echo -e ${CR})" confirm
    if [[ "$confirm" != "ELIMINAR" ]]; then
        echo -e "  ${RD}[-] Texto incorrecto. Cancelado.${CR}"; sleep 2; return
    fi

    echo ""

    # 1. Desactivar enrutamiento
    _wgh_routing_off_internal

    # 2. Detener y deshabilitar servicio
    echo -e "  ${YL}[*]${CR} Deteniendo servicio wg-quick@${WGH_IFACE}..."
    systemctl stop "wg-quick@${WGH_IFACE}" 2>/dev/null
    systemctl disable "wg-quick@${WGH_IFACE}" 2>/dev/null

    # 3. Eliminar archivos
    echo -e "  ${YL}[*]${CR} Eliminando archivos de configuración..."
    rm -f "${WGH_CONF}"
    rm -f "${WGH_PRIV_KEY}"
    rm -f "${WGH_PUB_KEY}"
    _wgh_isolate_off
    rm -f "${WGH_PEER_KEY}" "${WGH_NODES_CONF}"
    rm -f "${WGH_RT_BACKUP}"
    rm -f "${WGH_USERS_CONF}"
    rm -f "${WGH_FALLBACK_CONF}"

    # 4. Eliminar entrada en rt_tables
    sed -i "/${WGH_RT_NAME}/d" /etc/iproute2/rt_tables 2>/dev/null

    # 5. Firewall
    _wgh_close_firewall

    # 6. Verificación de seguridad final
    _wgh_verify_ssh_route && echo -e "  ${GR}[+]${CR} SSH protegido — tabla main intacta."
    _wgh_log "Gateway residencial desinstalado y eliminado completamente"

    echo ""
    echo -e "$SEP"
    echo -e "  ${GR}[+] Gateway residencial eliminado completamente.${CR}"
    echo -e "$SEP"
    sleep 2
    read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
}

# =========================================================
# CAMBIO 13: MENÚ PRINCIPAL DEL MÓDULO (14 OPCIONES)
# =========================================================
# =========================================================
# ¿POR QUE NO HAY INTERNET?
# ---------------------------------------------------------
# Recorre la cadena entera, eslabon por eslabon, con datos
# reales del sistema. La clave son los CONTADORES de las
# reglas: una regla instalada por la que no ha pasado ni un
# paquete dice que el trafico no llega hasta ella, y eso
# senala el eslabon roto sin tener que adivinarlo.
# =========================================================
_wgh_rule_pkts() {
    # Paquetes que han cruzado una regla, buscada por comentario.
    local tabla="$1" cadena="$2" patron="$3"
    iptables -t "$tabla" -L "$cadena" -v -n -x 2>/dev/null \
        | grep -- "$patron" | awk '{s+=$1} END{print s+0}'
}

wghome_why_no_internet() {
    clear
    print_title 2>/dev/null || true
    ui_section "POR QUE NO HAY INTERNET" "la cadena completa, eslabon a eslabon"
    ui_blank

    local problemas=0
    _p() { problemas=$((problemas+1)); echo -e "${UI_PAD}  ${RD}✗ $1${CR}"; [ -n "${2:-}" ] && echo -e "${UI_PAD}    ${DM}$2${CR}"; }
    _v() { echo -e "${UI_PAD}  ${GR}✓ $1${CR}"; }
    _i() { echo -e "${UI_PAD}    ${DM}$1${CR}"; }

    # --- 1. Nodos ---
    echo -e "${UI_PAD}${YL}1 · Nodos${CR}"
    local total idx name key
    total=$(_wgh_nodes_count)
    if [ "${total:-0}" -eq 0 ]; then
        _p "No hay ningun nodo registrado." "GESTIONAR NODOS > REGISTRAR NODO"
        ui_solid; ui_pause; return
    fi
    _v "${total} nodo(s) registrado(s)."
    local vivos=0
    while IFS='|' read -r name key idx; do
        [ -z "$idx" ] && continue
        if ! _wgh_node_is_up "$idx"; then
            _p "'${name}': su interfaz $(_wgn_iface "$idx") esta apagada." "Se levanta sola al aplicar la salida residencial."
        elif [ "$(_wgh_node_hs "$idx")" -lt 0 ] 2>/dev/null; then
            _p "'${name}': nunca ha conectado." "El aparato no esta llamando al VPS. Revisalo alli."
        else
            _v "'${name}': conectado hace $(_wgh_node_hs "$idx")s."
            vivos=$((vivos+1))
        fi
    done < <(_wgh_nodes_list)
    [ "$vivos" -eq 0 ] && { ui_blank; _p "Ningun nodo esta conectado: no hay por donde salir."; ui_solid; ui_pause; return; }
    ui_blank

    # --- 2. Ajustes del kernel ---
    echo -e "${UI_PAD}${YL}2 · Kernel${CR}"
    local fwd rpf
    fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
    [ "$fwd" = "1" ] && _v "ip_forward activo." || _p "ip_forward apagado." "sysctl -w net.ipv4.ip_forward=1"
    rpf=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null)
    if [ "$rpf" = "1" ]; then
        _p "rp_filter = 1 (estricto)." "Descarta TODAS las respuestas que vuelven por el tunel."
        _i "Se corrige al activar la salida residencial."
    else
        _v "rp_filter = ${rpf} (no descarta el retorno)."
    fi
    ui_blank

    # --- 3. Usuarios asignados ---
    echo -e "${UI_PAD}${YL}3 · Usuarios${CR}"
    local u uid asign=0
    while IFS= read -r u; do
        [ -z "$u" ] && continue
        name=$(_wgh_user_node "$u")
        uid=$(id -u "$u" 2>/dev/null)
        if [ -z "$name" ]; then
            _i "${u} (UID ${uid}): sale por la IP del VPS"
        elif [ -z "$uid" ] || [ "$uid" -lt 1000 ] 2>/dev/null; then
            _p "${u} esta asignado a '${name}' pero su UID es ${uid:-?}." "Solo se enruta UID >= 1000. Esa cuenta nunca saldra por el nodo."
        else
            _v "${u} (UID ${uid}) -> ${name}"
            asign=$((asign+1))
        fi
    done < <(_wgh_get_client_users | cut -d: -f1)
    if [ "$asign" -eq 0 ]; then
        ui_blank
        _p "Ningun usuario esta asignado a un nodo." "GESTIONAR NODOS > ASIGNAR USUARIOS. Sin esto no se desvia nada."
        ui_solid; ui_pause; return
    fi
    ui_blank

    # --- 4. Reglas y contadores ---
    echo -e "${UI_PAD}${YL}4 · Reglas aplicadas${CR}"
    if ! _wgh_routing_is_active; then
        _p "La salida residencial esta APAGADA." "Enciendela con la opcion 3 del menu."
        ui_solid; ui_pause; return
    fi
    _v "Salida residencial encendida."

    local marcados
    marcados=$(_wgh_rule_pkts mangle OUTPUT HOMEVPN_MARK)
    if [ "${marcados:-0}" -eq 0 ]; then
        _p "Ni un solo paquete ha sido marcado todavia." \
           "O el cliente no esta navegando, o su trafico no sale con su UID."
        _i "Conecta el cliente, navega un poco y vuelve a mirar."
    else
        _v "${marcados} paquetes marcados: el trafico del cliente SI se esta desviando."
    fi

    while IFS='|' read -r name key idx; do
        [ -z "$idx" ] && continue
        local mark tbl ifc ruta natp
        mark=$(_wgn_mark "$idx"); tbl=$(_wgn_table "$idx"); ifc=$(_wgn_iface "$idx")
        echo -e "${UI_PAD}  ${WH}${name}${CR} ${DM}(marca ${mark}, tabla ${tbl})${CR}"
        ip rule show | grep -q "fwmark ${mark} lookup ${tbl}" \
            && _v "  regla fwmark -> tabla ${tbl}" \
            || _p "  falta la regla fwmark ${mark} -> tabla ${tbl}"
        ruta=$(ip route show table "$tbl" 2>/dev/null | grep '^default')
        [ -n "$ruta" ] && _v "  ${ruta}" || _p "  la tabla ${tbl} no tiene ruta por defecto"
        natp=$(_wgh_rule_pkts nat POSTROUTING "$ifc")
        if [ "${natp:-0}" -eq 0 ]; then
            _p "  el NAT de ${ifc} no ha traducido ningun paquete" \
               "Marcado pero no enrutado: revisa la ruta de arriba."
        else
            _v "  NAT: ${natp} paquetes traducidos hacia el nodo"
        fi
    done < <(_wgh_nodes_list)
    ui_blank

    # --- 5. La prueba definitiva ---
    echo -e "${UI_PAD}${YL}5 · Salida real${CR}"
    local ip_normal probe res
    ip_normal=$(_wgh_get_droplet_ip)
    while IFS='|' read -r name key idx; do
        [ -z "$idx" ] && continue
        probe=$(_wgh_node_users "$name" | head -1)
        [ -z "$probe" ] && continue
        _i "Saliendo como '${probe}' por '${name}'..."
        res=$(runuser -u "$probe" -- curl -4 -s --max-time 15 https://api.ipify.org 2>/dev/null)
        if [ -z "$res" ]; then
            _p "  sin respuesta: el trafico sale del VPS pero no vuelve" \
               "El nodo recibe y no reenvia. Revisa ALLI el reenvio y el NAT."
        elif [ "$res" = "$ip_normal" ]; then
            _p "  ${res} — es la IP del VPS, no la del nodo" \
               "El desvio no se esta aplicando a ese usuario."
        else
            _v "  ${res} — ¡sale por el nodo!"
        fi
    done < <(_wgh_nodes_list)

    ui_blank; ui_rule
    if [ "$problemas" -eq 0 ]; then
        echo -e "${UI_PAD}${GR}Todo correcto: el gateway esta dando Internet.${CR}"
    else
        echo -e "${UI_PAD}${RD}${problemas} problema(s). El primero de la lista es el que hay que arreglar:${CR}"
        echo -e "${UI_PAD}${DM}los de abajo suelen ser consecuencia suya.${CR}"
    fi
    ui_solid
    read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
}

wghome_menu() {
    # Reparar configuración existente en background si faltaba Table=off o AllowedIPs=0.0.0.0/0
    _wgh_repair_conf_if_needed

    while true; do
        clear
        print_title 2>/dev/null || true
        ui_section "GATEWAY RESIDENCIAL" "salida por WireGuard hacia tu casa"
        ui_blank

        # Estado actual
        local TAG_INST TAG_TUNNEL TAG_ROUTING TAG_FB u_count
        _wgh_is_installed      && TAG_INST="${GR}[ INSTALADO ]${CR}" || TAG_INST="${RD}[ NO INSTALADO ]${CR}"
        _wgh_is_up             && TAG_TUNNEL="$(ui_tag_str on)"      || TAG_TUNNEL="$(ui_tag_str off)"
        _wgh_routing_is_active && TAG_ROUTING="$(ui_tag_str on)"     || TAG_ROUTING="$(ui_tag_str off)"
        [ "$(_wgh_get_fallback)" = "ON" ] && TAG_FB="$(ui_tag_str on)" || TAG_FB="$(ui_tag_str off)"

        u_count=0
        [ -f "$WGH_USERS_CONF" ] && u_count=$(_wgh_get_configured_users | wc -l)

        echo -e "${UI_PAD}$(ui_cell "Instalación" "" 22)${TAG_INST}"
        echo -e "${UI_PAD}$(ui_cell "Usuarios enrutados" "$u_count" 22 "$CY")"
        local n_count n_conn i
        n_count=$(_wgh_nodes_count 2>/dev/null || echo 0)
        n_conn=0
        for i in $(_wgh_nodes_list 2>/dev/null | cut -d'|' -f3); do
            _wgh_node_is_up "$i" && [ "$(_wgh_node_hs "$i")" -ge 0 ] 2>/dev/null && n_conn=$((n_conn+1))
        done
        echo -e "${UI_PAD}$(ui_cell "Nodos registrados" "${n_count:-0}" 22 "$CY")"
        echo -e "${UI_PAD}$(ui_cell "Nodos conectados" "${n_conn}" 22 "$GR")"
        ui_rule
        ui_blank

        echo -e "${UI_PAD}${YL}── TÚNEL ──${CR}"
        ui_opt "1" "INSTALAR / RECONFIG"  "asistente"
        ui_opt "2" "TÚNEL WG-HOME"        "activar/apagar"  "$TAG_TUNNEL"
        ui_opt "3" "SALIDA RESIDENCIAL"   "activar/apagar"  "$TAG_ROUTING"
        ui_opt "4" "FALLBACK AUTOMÁTICO"  "si cae el túnel" "$TAG_FB"
        ui_blank
        echo -e "${UI_PAD}${YL}── CLAVES ──${CR}"
        ui_opt "5" "CLAVE PÚBLICA DEL VPS" "para el PC"
        ui_opt "6" "GESTIONAR NODOS"      "y salida x usuario"
        ui_blank
        echo -e "${UI_PAD}${YL}── USUARIOS ──${CR}"
        ui_opt "7" "VER ENRUTADOS"        "quién sale por casa"
        ui_opt "8" "CONFIGURAR USUARIOS"  "asignar salida"
        ui_blank
        echo -e "${UI_PAD}${YL}── DIAGNÓSTICO ──${CR}"
        ui_opt "9"  "DIAGNÓSTICO COMPLETO" "5 comprobaciones"
        ui_opt "10" "PROBAR CONEXIÓN"      "ping al PC"
        ui_opt "11" "VER IP DE SALIDA"     "normal vs casa"
        ui_blank
        ui_opt "13" "¿POR QUE NO HAY NET?" "cadena completa"
        ui_blank
        ui_opt_danger "12" "ELIMINAR CONFIGURACIÓN" "borra el gateway"
        ui_opt "0" "VOLVER"
        ui_solid
        ui_prompt "Elige una opción [0-13]"

        case "$REPLY_UI" in
            # Los pares activar/desactivar eran cuatro entradas de menu para dos
            # estados: ahora cada uno es un interruptor que alterna segun el tag.
            1)  wghome_install ;;
            2)  if _wgh_is_up; then wghome_tunnel_down; else wghome_tunnel_up; fi ;;
            3)  if _wgh_routing_is_active; then wghome_routing_off; else wghome_routing_on; fi ;;
            4)  wghome_configure_fallback ;;
            5)  wghome_show_pubkey ;;
            6)  wghome_manage_nodes ;;
            7)  wghome_view_users ;;
            8)  wghome_manage_users ;;
            9)  wghome_diagnose ;;
            10) wghome_ping_peer ;;
            11) wghome_check_ip ;;
            13) wghome_why_no_internet ;;
            12) wghome_remove ;;
            0)  break ;;
            *)  ui_err "Opción no válida."; sleep 1 ;;
        esac
    done
}
