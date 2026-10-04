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
    ui_info "WireGuard no encontrado. Instalando..."
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
            ui_err "Distribución no reconocida: $distro"
            ui_warn "Instala manualmente: wireguard y wireguard-tools"
            return 1
            ;;
    esac
    if ! command -v wg &>/dev/null; then
        ui_err "Error instalando WireGuard."
        return 1
    fi
    ui_ok "WireGuard instalado correctamente."
    return 0
}

# Registrar tabla de rutas 200 homevpn si no existe
_wgh_ensure_rt_table() {
    mkdir -p /etc/iproute2 2>/dev/null
    if [ ! -f /etc/iproute2/rt_tables ]; then
        touch /etc/iproute2/rt_tables
    fi
    if ! grep -q "^${WGH_RT_TABLE}[[:space:]]" /etc/iproute2/rt_tables 2>/dev/null; then
        ui_info "Registrando tabla de rutas ${WGH_RT_TABLE} ${WGH_RT_NAME}..."
        echo "${WGH_RT_TABLE} ${WGH_RT_NAME}" >> /etc/iproute2/rt_tables
        _wgh_log "Tabla ${WGH_RT_TABLE} ${WGH_RT_NAME} agregada a /etc/iproute2/rt_tables"
        ui_ok "Tabla ${WGH_RT_NAME} registrada."
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
        ui_warn "ADVERTENCIA: La ruta por defecto en tabla main no se encontró o usa wg-home."
        ui_warn "SSH podría verse afectado. Revisa: ip route show table main"
        _wgh_log "ALERTA: Verificación de ruta SSH falló en tabla main"
        return 1
    fi
    return 0
}

# Abrir puerto 51820/udp en UFW si está activo
_wgh_open_firewall() {
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${WGH_PORT}/udp" &>/dev/null
        ui_ok "UFW: puerto ${WGH_PORT}/UDP abierto."
        _wgh_log "UFW: puerto ${WGH_PORT}/UDP abierto"
    fi
}

# Cerrar puerto 51820/udp en UFW si está activo
_wgh_close_firewall() {
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw delete allow "${WGH_PORT}/udp" &>/dev/null
        ui_ok "UFW: regla ${WGH_PORT}/UDP eliminada."
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
# Como aparece la tabla en 'ip rule show'. La 200 esta registrada en
# rt_tables como 'homevpn' y se muestra con ese nombre: buscar
# "lookup 200" fallaba, se duplicaban reglas al aplicar y la del nodo 1
# no se borraba al apagar la salida.
_wgn_table_re() { [ "$1" = "1" ] && echo "(200|${WGH_RT_NAME})" || _wgn_table "$1"; }

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

# ---------------------------------------------------------
# Registro del formato v1 (version a613a34):
#   nombre|clave|10.77.77.X|si/no      (IP y "activo")
# El formato actual guarda el INDICE del nodo en el 3er campo:
#   nombre|clave|N|tipo[|respaldo]
# Nunca se escribio esta migracion, y con el registro antiguo el
# panel tomaba "10.77.77.2" como indice: interfaces como
# 'wg-home10.77.77.2', marcas como '0x7710.77.77.2', nodos dados por
# caidos y usuarios "sin asignar", aunque el trafico siguiera
# saliendo por casa gracias a las reglas que ya estaban puestas.
#
# 10.77.77.2 era el primer nodo y en el modelo actual es justo el
# indice 1 (misma interfaz wg-home, puerto 51820 e IP): ese nodo no
# hay que tocarlo. Los demas (10.77.77.3, .4...) compartian interfaz
# y ahora tienen la suya: se les da indice libre y se anotan para
# avisar de que hay que reconfigurarlos con DATOS PARA EL NODO.
# ---------------------------------------------------------
WGH_RECONFIG="/etc/wireguard/homevpn-reconfigurar"

_wgh_nodes_migrate_v1() {
    local f="$WGH_NODES_CONF"
    grep -qE '^[^|#]*\|[^|]*\|10\.77\.[0-9]+\.[0-9]+' "$f" 2>/dev/null || return 0
    cp -p "$f" "$f.v1.bak" 2>/dev/null
    local -a keep=() pend=() out=()
    local -A usado=()
    local line name key f3 f4 i n tipo
    while IFS= read -r line; do
        case "$line" in ''|\#*) continue ;; esac
        IFS='|' read -r name key f3 f4 _ <<<"$line"
        if [[ "$f3" =~ ^[0-9]+$ ]]; then keep+=("$line"); usado[$f3]=1
        else pend+=("${name}|${key}|${f3}|${f4}"); fi
    done < "$f"
    out=("${keep[@]}")
    # El 10.77.77.2 primero: es el unico que conserva su sitio exacto.
    local orden=()
    for line in "${pend[@]}"; do [[ "$line" == *"|10.77.77.2|"* ]] && orden=("$line" "${orden[@]}") || orden+=("$line"); done
    for line in "${orden[@]}"; do
        IFS='|' read -r name key f3 f4 <<<"$line"
        i=""
        if [ "$f3" = "10.77.77.2" ] && [ -z "${usado[1]:-}" ]; then
            i=1
        else
            for n in $(seq 1 16); do [ -z "${usado[$n]:-}" ] && { i=$n; break; }; done
            [ -n "$i" ] && echo "$name" >> "$WGH_RECONFIG"
        fi
        [ -z "$i" ] && continue
        usado[$i]=1
        tipo=wg; [ "$f4" = "socks" ] && tipo=socks
        out+=("${name}|${key}|${i}|${tipo}")
        _wgh_log "Registro v1 migrado: '${name}' (${f3}) -> indice ${i}"
    done
    printf '%s\n' "${out[@]}" > "$f"; chmod 600 "$f"

    # Restos que dejo el panel al leer la IP como indice.
    local c u
    for c in /etc/wireguard/wg-home10.*.conf; do
        [ -f "$c" ] || continue
        u="wg-quick@$(basename "$c" .conf)"
        systemctl disable --now "$u" &>/dev/null
        rm -f "$c"
    done
    rm -f "$WGH_HEALTH_FILE" 2>/dev/null
}

_wgh_nodes_migrate() {
    if [ -f "$WGH_NODES_CONF" ]; then _wgh_nodes_migrate_v1; return 0; fi
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

    # Quien lo tuviera de respaldo se queda apuntando a un nodo que
    # ya no existe: al caer su preferido iria a una tabla vacia y
    # perderia la salida en vez de caer a la IP del VPS.
    tmp=$(mktemp)
    _wgh_nodes_list | awk -F'|' -v OFS='|' -v n="$name" \
        '{ t=($4==""?"wg":$4); if ($5==n) { $5="" } ; print $1,$2,$3,t,$5 }' > "$tmp"
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

    if _wgh_node_is_up "$idx"; then
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
    while IFS='|' read -r name key idx type _; do
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
#
# ClientAlive es lo que hace que un movil caido se detecte: sin el,
# si el telefono pierde la cobertura sshd mantiene su puerto -R
# abierto durante HORAS (hasta que caduca el TCP). El vigilante lo
# veia "conectado", el trafico de sus usuarios se iba a un SOCKS
# muerto, y el movil ni siquiera podia volver a conectar porque su
# puerto seguia ocupado. Con 10s x 3 se libera en unos 30 segundos.
#
# El fichero se reescribe si su contenido cambia (antes solo se
# creaba una vez, y una correccion nunca llegaba a los VPS que ya lo
# tenian), y solo se aplica si sshd lo da por valido.
_socks_sshd_conf() {
    cat <<'SSHEOF'
# Usuarios de nodo movil (SOCKS inverso). Solo reenvio remoto.
Match User snode*
    AllowTcpForwarding remote
    PermitTunnel no
    X11Forwarding no
    AllowAgentForwarding no
    PermitTTY no
    ClientAliveInterval 10
    ClientAliveCountMax 3
    ForceCommand echo "Nodo conectado. Manten esta sesion abierta."
SSHEOF
}

_socks_harden_sshd() {
    [ -d /etc/ssh/sshd_config.d ] || return 0
    local want old=""
    want=$(_socks_sshd_conf)
    [ -f "$_SOCKS_SSHD_DROPIN" ] && old=$(cat "$_SOCKS_SSHD_DROPIN")
    [ "$want" = "$old" ] && return 0
    echo "$want" > "$_SOCKS_SSHD_DROPIN"
    if command -v sshd &>/dev/null && ! sshd -t &>/dev/null; then
        # No se arriesga el SSH de todos por esta mejora.
        if [ -n "$old" ]; then echo "$old" > "$_SOCKS_SSHD_DROPIN"; else rm -f "$_SOCKS_SSHD_DROPIN"; fi
        _wgh_log "ERROR: la config sshd de nodos movil no valida; se mantiene la anterior"
        return 1
    fi
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null ||         systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    _wgh_log "Config sshd de nodos movil actualizada"
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
        # permitlisten: la llave solo puede abrir el puerto de ESTE nodo.
        local opts="restrict,port-forwarding,permitlisten=\"127.0.0.1:$(_wgn_socksport "$idx")\""
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
    { [ -f "$WGH_ROUTING_FLAG" ] || _wgh_routing_is_active; } && _wgh_apply_user_routing >/dev/null 2>&1

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
# SALUD DE LOS NODOS Y CONMUTACION AUTOMATICA
# ---------------------------------------------------------
# Objetivo: que un cliente no se quede sin Internet aunque su
# nodo desaparezca. La cadena es
#
#   nodo preferido -> nodo de respaldo -> IP del VPS
#
# y se recorre sola, sin reasignar usuarios ni tocar marcas.
#
# El truco esta en como se montan las reglas. Para la marca de
# un nodo se dejan puestas DOS reglas, una por cada destino, y
# el vigilante solo pone o quita la RUTA POR DEFECTO de cada
# tabla. Cuando una tabla se queda sin ruta, el kernel pasa
# sola a la regla siguiente:
#
#   prio 1001  fwmark 0x77 -> tabla 200 (preferido)
#   prio 1401  fwmark 0x77 -> tabla 202 (respaldo)
#   (ninguna resuelve)     -> tabla main -> IP del VPS
#
# Asi conmutar es un solo comando y es atomico.
#
# Como se mide la salud: ESCUCHANDO, no preguntando. El kernel
# ya cuenta los bytes recibidos de cada peer, y leer ese
# contador no envia un solo paquete. Solo se sondea de verdad
# donde sondear es gratis, que es el wifi del propio nodo.
# =========================================================

WGH_HEALTH_FILE="/run/homevpn-health"     # tmpfs: no desgasta el disco
WGH_WATCH_SERVICE="/etc/systemd/system/homevpn-watchdog.service"
WGH_WATCH_INTERVAL="${WGH_WATCH_INTERVAL:-1}"

# Medidas malas seguidas para dar un nodo por caido, y buenas
# para readmitirlo. Sin esta histeresis un microcorte de dos
# segundos rebotaria a los clientes de un nodo a otro sin parar,
# que se nota mas que la propia caida.
WGH_DOWN_AFTER=3
WGH_UP_AFTER=2

# ---------------------------------------------------------
# Maquina de estados. Funcion pura: entra estado y medida,
# sale estado. Se aisla asi a proposito para poder probarla
# sin nodos, sin red y sin privilegios.
#   _wgh_health_step <up|down> <racha> <1|0>  ->  "estado racha"
# ---------------------------------------------------------
# Deja el resultado en HS_ESTADO / HS_RACHA en vez de imprimirlo,
# por lo mismo que _wgh_measure_calc: una subshell por nodo y
# vuelta es cara cuando la vuelta es cada segundo.
_wgh_health_step() {
    local estado="$1" racha="$2" ok="$3"
    if [ "$ok" = "1" ]; then
        if [ "$estado" = "up" ]; then HS_ESTADO=up; HS_RACHA=0; return; fi
        racha=$((racha + 1))
        if [ "$racha" -ge "$WGH_UP_AFTER" ]; then HS_ESTADO=up; HS_RACHA=0
        else HS_ESTADO=down; HS_RACHA=$racha; fi
    else
        if [ "$estado" = "down" ]; then HS_ESTADO=down; HS_RACHA=0; return; fi
        racha=$((racha + 1))
        if [ "$racha" -ge "$WGH_DOWN_AFTER" ]; then HS_ESTADO=down; HS_RACHA=0
        else HS_ESTADO=up; HS_RACHA=$racha; fi
    fi
}

# Nodo de respaldo de otro nodo (cuarto campo del registro).
# El respaldo es el 5o campo. El 4o ya lo ocupa el tipo de nodo, y
# pisarlo convertiria un nodo socks en uno wg sin avisar.
#   nombre | clave/usuario | indice | tipo | respaldo
_wgh_node_backup_of() { _wgh_nodes_list | awk -F'|' -v n="$1" '$1==n {print $5}' | head -1; }

_wgh_node_set_backup() {
    local name="$1" bk="$2" tmp
    tmp=$(mktemp)
    _wgh_nodes_list | awk -F'|' -v OFS='|' -v n="$name" -v b="$bk" \
        '{ t=($4==""?"wg":$4); if ($1==n) { $5=b } ; print $1,$2,$3,t,$5 }' > "$tmp"
    mv "$tmp" "$WGH_NODES_CONF"; chmod 600 "$WGH_NODES_CONF"
    _wgh_log "Respaldo de '${name}' fijado a '${bk:-la IP del VPS}'"
}

# ---------------------------------------------------------
# ¿Esta vivo este nodo? Cada tipo se mide distinto, pero los
# dos se miden ESCUCHANDO: ni uno ni otro envia un paquete.
#   wg    -> interfaz arriba y el peer ha dado senales
#   socks -> alguien escucha en el puerto inverso del movil
# ---------------------------------------------------------
# Un keepalive de WireGuard NO renueva el handshake: solo mueve el
# contador de bytes del receptor. Medir por handshake daria por
# muerto a un nodo sano que simplemente no tiene trafico, asi que
# la senal buena es que el contador de recibidos avance.
#
# Cuanto silencio se tolera depende del keepalive que tenga pactado
# cada peer, y eso lo dice el propio kernel: asi un nodo con
# keepalive de 5s se detecta en ~15s y uno de 25s no da falsos
# positivos. No hay que configurar nada a mano.
_wgh_silence_for() {
    local ka="${1:-25}" s
    # El kernel escribe 'off' cuando el keepalive es 0, que es justo lo
    # que tiene el VPS. Antes 'off' acababa valiendo 0 en la cuenta y la
    # tolerancia quedaba en 12s con nodos que hablan cada 25s: un nodo
    # sano y sin trafico se daba por caido y recuperado cada 25 segundos.
    [[ "$ka" =~ ^[0-9]+$ ]] && [ "$ka" -gt 0 ] || ka=25
    s=$(( 2 * ka + 5 ))
    [ "$s" -lt 12 ] && s=12
    echo "$s"
}

# Nucleo de la medida. Es pura —solo cuentas— y deja el resultado
# en variables en vez de imprimirlo: llamarla con $( ) costaria una
# subshell por nodo y vuelta, y a una vuelta por segundo eso se
# nota en un VPS pequeno. Medido: pasar de subshells y comandos
# externos a bash puro baja el vigilante del 3,9% de un nucleo a
# una decima parte.
#   -> MED_OK (1/0), MED_RX, MED_TS
#   _wgh_measure_calc <rx> <keepalive> <ahora> <rx_prev> <ts_prev> [silencio_max]
_wgh_measure_calc() {
    local rx="$1" ka="$2" ahora="$3" rxp="$4" tsp="$5" sil="${6:-}"
    if [ -z "$rx" ]; then MED_OK=0; MED_RX="$rxp"; MED_TS="$tsp"; return; fi
    if [ -z "$sil" ]; then
        [[ "$ka" =~ ^[0-9]+$ ]] && [ "$ka" -gt 0 ] || ka=25
        sil=$(( 2 * ka + 5 )); [ "$sil" -lt 12 ] && sil=12
    fi
    if [ "$rx" != "$rxp" ]; then
        MED_OK=1; MED_RX="$rx"; MED_TS="$ahora"
    elif [ $(( ahora - tsp )) -lt "$sil" ]; then
        MED_OK=1; MED_RX="$rx"; MED_TS="$tsp"
    else
        MED_OK=0; MED_RX="$rx"; MED_TS="$tsp"
    fi
}

# ---------------------------------------------------------
# Abrir o cerrar el camino de un nodo. Cerrarlo hace que el
# trafico marcado caiga a la regla siguiente: el respaldo, y
# si no hay, la IP del VPS.
#   wg    -> la ruta por defecto de su tabla
#   socks -> su regla REDIRECT hacia redsocks
# Todas reciben el INDICE del nodo. Antes el tipo se buscaba
# por nombre pasandole el indice, nunca coincidia, y un nodo
# movil caido se trataba como WireGuard: se borraba una ruta
# que no existia y su REDIRECT seguia mandando a sus usuarios
# a un SOCKS muerto.
# ---------------------------------------------------------
_wgh_idx_type() {
    local t
    t=$(_wgh_nodes_list | awk -F'|' -v i="$1" '$3==i {print $4}' | head -1)
    echo "${t:-wg}"
}

_wgh_node_path_on() {
    local idx="$1"
    if [ "$(_wgh_idx_type "$idx")" = "socks" ]; then
        local mark redport
        mark=$(_wgn_mark "$idx"); redport=$(_wgn_redport "$idx")
        iptables -t nat -C OUTPUT -p tcp -m mark --mark "${mark}" -m comment --comment "HOMEVPN_SOCKS" -j REDIRECT --to-ports "${redport}" 2>/dev/null || \
            iptables -t nat -A OUTPUT -p tcp -m mark --mark "${mark}" -m comment --comment "HOMEVPN_SOCKS" -j REDIRECT --to-ports "${redport}" 2>/dev/null
    else
        ip route replace default via "$(_wgn_nodeip "$idx")" dev "$(_wgn_iface "$idx")" table "$(_wgn_table "$idx")" 2>/dev/null
    fi
}

_wgh_node_path_off() {
    local idx="$1"
    if [ "$(_wgh_idx_type "$idx")" = "socks" ]; then
        local mark redport
        mark=$(_wgn_mark "$idx"); redport=$(_wgn_redport "$idx")
        while iptables -t nat -D OUTPUT -p tcp -m mark --mark "${mark}" -m comment --comment "HOMEVPN_SOCKS" -j REDIRECT --to-ports "${redport}" 2>/dev/null; do :; done
    else
        ip route del default table "$(_wgn_table "$idx")" 2>/dev/null
    fi
}

# ---------------------------------------------------------
# Desvio al RESPALDO. Los usuarios de un nodo caido pasan al
# nodo que se le haya fijado como respaldo, y solo si ese
# respaldo esta vivo; si no, siguen cayendo a la IP del VPS.
#   respaldo wg    -> regla 'fwmark <marca del caido> -> tabla
#                     del respaldo', prioridad 1400+indice
#   respaldo socks -> REDIRECT de la marca del caido hacia el
#                     redsocks del respaldo (solo TCP)
# Antes esto se anunciaba en el log pero no existia: la regla
# nunca se creaba y todos caian directos a la IP del VPS.
# ---------------------------------------------------------
_wgh_backup_prio() { echo $(( 1400 + $1 )); }

# Que habria que ejecutar para desviar <idx> a <idx_respaldo>.
# Funcion pura (solo imprime): asi se puede probar sin root.
_wgh_backup_cmd() {
    local idx="$1" bidx="$2" btype="$3" mark
    mark=$(_wgn_mark "$idx")
    if [ "$btype" = "socks" ]; then
        echo "iptables -t nat -A OUTPUT -p tcp -m mark --mark ${mark} -m comment --comment HOMEVPN_SOCKS_BK -j REDIRECT --to-ports $(_wgn_redport "$bidx")"
    else
        echo "ip rule add fwmark ${mark} table $(_wgn_table "$bidx") priority $(_wgh_backup_prio "$idx")"
    fi
}

_wgh_backup_on() {
    local idx="$1" name bk bidx btype mark
    name=$(_wgh_node_name_of "$idx"); bk=$(_wgh_node_backup_of "$name")
    [ -z "$bk" ] && return 0
    bidx=$(_wgh_node_idx_of "$bk"); [ -z "$bidx" ] && return 0
    btype=$(_wgh_idx_type "$bidx"); mark=$(_wgn_mark "$idx")
    if [ "$btype" = "socks" ]; then
        iptables -t nat -C OUTPUT -p tcp -m mark --mark "${mark}" -m comment --comment "HOMEVPN_SOCKS_BK" -j REDIRECT --to-ports "$(_wgn_redport "$bidx")" 2>/dev/null && return 0
    else
        ip rule show 2>/dev/null | grep -q "^$(_wgh_backup_prio "$idx"):" && return 0
    fi
    # shellcheck disable=SC2046
    $(_wgh_backup_cmd "$idx" "$bidx" "$btype") 2>/dev/null
}

_wgh_backup_off() {
    local idx="$1" mark rule
    mark=$(_wgn_mark "$idx")
    while ip rule del priority "$(_wgh_backup_prio "$idx")" 2>/dev/null; do :; done
    while rule=$(iptables -t nat -S OUTPUT 2>/dev/null | grep "HOMEVPN_SOCKS_BK" | grep -- "--mark ${mark} " | head -1) && [ -n "$rule" ]; do
        # shellcheck disable=SC2086
        iptables -t nat ${rule/-A /-D } 2>/dev/null || break
    done
}

# ---------------------------------------------------------
# Lleva el sistema al estado que dicta la salud de los nodos.
# Es idempotente: se llama en cada cambio y, ademas, cada pocos
# segundos, asi que si algo se desajusta (un reinicio del
# vigilante, alguien que toco iptables) se corrige solo.
#   _wgh_reconcile <nombre_array_estado>
# ---------------------------------------------------------
_wgh_reconcile() {
    local -n _st="$1"
    local name key idx tipo bk est bk_est
    [ -f "$WGH_ROUTING_FLAG" ] || return 0
    while IFS='|' read -r name key idx tipo bk; do
        [ -z "$idx" ] && continue
        est="${_st[$name]:-up}"
        if [ "$est" = "up" ]; then
            _wgh_node_path_on "$idx"; _wgh_backup_off "$idx"
        else
            _wgh_node_path_off "$idx"
            bk_est="down"; [ -n "$bk" ] && bk_est="${_st[$bk]:-up}"
            if [ -n "$bk" ] && [ "$bk_est" = "up" ]; then _wgh_backup_on "$idx"; else _wgh_backup_off "$idx"; fi
        fi
    done < <(_wgh_nodes_list)
}

# ---------------------------------------------------------
# SONDA DE PUNTA A PUNTA
# ---------------------------------------------------------
# Que el tunel este vivo no significa que el nodo de Internet.
# Si en casa se cae el wifi o el router, o el PC pierde su NAT al
# reiniciarse, el PC sigue mandando keepalives al VPS: el contador
# de bytes sube, el nodo parecia sano y los usuarios se quedaban
# sin Internet indefinidamente. Aun con el PC apagado, la caida se
# detectaba a los ~60 s.
#
# La sonda recorre el mismo camino que el trafico de los clientes:
#   PC (wg)  -> ping a 1.1.1.1 / 8.8.8.8 saliendo por la interfaz del
#               nodo ('-I wg-homeN': no depende de la tabla de rutas,
#               asi sigue probando aunque el nodo este apartado).
#   movil    -> una peticion HTTP minima por su SOCKS.
# Va en segundo plano (la vuelta del vigilante es de 1 s) y deja la
# hora del ultimo exito en /run/homevpn-probe/<indice>.ok.
#
# Coste: un ping cada 2 s por nodo PC (~7 MB/dia) y ~500 bytes cada
# 10 s por movil (~4 MB/dia del plan de datos).
# ---------------------------------------------------------
WGH_PROBE_DIR="/run/homevpn-probe"
WGH_PROBE_EVERY_WG=2;    WGH_PROBE_WINDOW_WG=7
WGH_PROBE_EVERY_SOCKS=10; WGH_PROBE_WINDOW_SOCKS=25

_wgh_probe_launch() {
    local idx="$1" tipo="$2" d="$WGH_PROBE_DIR" pid
    mkdir -p "$d" 2>/dev/null
    if [ -f "$d/$idx.run" ]; then
        read -r pid < "$d/$idx.run" 2>/dev/null
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
    fi
    (
        if [ "$tipo" = "socks" ]; then
            curl -s -o /dev/null -m 6 --socks5 "127.0.0.1:$(_wgn_socksport "$idx")" http://1.1.1.1/cdn-cgi/trace
        else
            ping -c1 -W2 -I "$(_wgn_iface "$idx")" 1.1.1.1 &>/dev/null || \
                ping -c1 -W2 -I "$(_wgn_iface "$idx")" 8.8.8.8 &>/dev/null
        fi && echo "${EPOCHSECONDS:-$(date +%s)}" > "$d/$idx.ok"
        rm -f "$d/$idx.run"
    ) &>/dev/null &
    echo "$!" > "$d/$idx.run"
}

# Hora del ultimo exito de la sonda (vacio si nunca lo tuvo).
_wgh_probe_last_ok() {
    local t=""
    [ -f "$WGH_PROBE_DIR/$1.ok" ] && read -r t < "$WGH_PROBE_DIR/$1.ok" 2>/dev/null
    echo "$t"
}

# Funcion pura: ¿la sonda da el nodo por bueno?
#   _wgh_probe_verdict <ahora> <ultimo_ok|""> <ventana>  -> 1 | 0 | ? (nunca contesto)
# '?' = el nodo jamas ha pasado la sonda (por ejemplo, un ISP que filtra
# el ICMP): entonces no se le puede juzgar por ella y se usa el contador
# de bytes de antes, para no dar por caido a un nodo que funciona.
_wgh_probe_verdict() {
    local ahora="$1" ok="$2" win="$3"
    [[ "$ok" =~ ^[0-9]+$ ]] || { echo "?"; return; }
    [ $(( ahora - ok )) -lt "$win" ] && echo 1 || echo 0
}

# ---------------------------------------------------------
# EL VIGILANTE
# ---------------------------------------------------------
wghome_watchdog_loop() {
    _wgh_log "Vigilante iniciado (tick ${WGH_WATCH_INTERVAL}s, caida tras ${WGH_DOWN_AFTER} medidas)"
    declare -A ESTADO RACHA RXP TSP RX KA IFC PROBE_T
    declare -a LISTA=()
    local ahora name key idx tipo estado racha nuevo bk ln mt="" mtprev="" vuelta=0 cambio veredicto cada
    local f1 f2 f3 f4 f5 f6 f7 f8 f9 k v

    # Se recupera el estado que dejo la ejecucion anterior (vive en
    # /run: sobrevive a un reinicio del vigilante, no al del VPS). Asi
    # un nodo que estaba caido no se da por bueno al arrancar.
    if [ -f "$WGH_HEALTH_FILE" ]; then
        while IFS='=' read -r k v; do
            [ -n "$k" ] && ESTADO[$k]="$v"
        done < "$WGH_HEALTH_FILE"
    fi

    while true; do
        if [ ! -f "$WGH_ROUTING_FLAG" ]; then sleep "$WGH_WATCH_INTERVAL"; continue; fi

        # EPOCHSECONDS lo da bash sin lanzar 'date'.
        ahora=${EPOCHSECONDS:-$(date +%s)}

        # El registro apenas cambia —solo al dar de alta o de baja un
        # nodo—, asi que preguntar por su fecha cada segundo es
        # gastar un proceso para nada. Cada 10 vueltas basta.
        vuelta=$(( vuelta + 1 ))
        if [ $(( vuelta % 10 )) -eq 1 ]; then
            mt=$(stat -c %Y "$WGH_NODES_CONF" 2>/dev/null || echo 0)
        fi
        if [ "$mt" != "$mtprev" ]; then
            # Un registro de formato antiguo se migra antes de leerlo.
            _wgh_nodes_migrate
            mtprev=$(stat -c %Y "$WGH_NODES_CONF" 2>/dev/null || echo 0); mt="$mtprev"; LISTA=()
            while IFS= read -r ln; do
                case "$ln" in ''|\#*) continue ;; esac
                LISTA+=("$ln")
                idx="${ln#*|}"; idx="${idx#*|}"; idx="${idx%%|*}"
                IFC[$idx]=$(_wgn_iface "$idx")
            done < "$WGH_NODES_CONF"
            # Reconciliar dentro de 15 vueltas, cuando ya se haya medido la
            # lista nueva: hacerlo ahora usaria el estado viejo en memoria.
            vuelta=1
            for k in "${!ESTADO[@]}"; do
                printf '%s\n' "${LISTA[@]}" | grep -q "^${k}|" || unset "ESTADO[$k]"
            done
        fi

        # Una sola llamada al kernel por vuelta, para todas las
        # interfaces, y se reparte en bash.
        RX=(); KA=()
        while IFS=$'\t' read -r f1 f2 f3 f4 f5 f6 f7 f8 f9; do
            [ -z "$f9" ] && continue          # linea de interfaz, no de peer
            RX["${f1}|${f2}"]="$f7"
            KA["${f1}|${f2}"]="$f9"
        done < <(wg show all dump 2>/dev/null)

        cambio=0
        while IFS='|' read -r name key idx tipo _; do
            [ -z "$idx" ] && continue
            estado="${ESTADO[$name]:-up}"

            # Un nodo que arranca caido no tiene el beneficio de la duda:
            # hace falta ver bytes nuevos de verdad para readmitirlo.
            if [ -z "${TSP[$name]:-}" ]; then
                if [ "$estado" = "down" ]; then TSP[$name]=0; else TSP[$name]="$ahora"; fi
            fi

            # Sonda de punta a punta: se lanza cada pocos segundos, en
            # segundo plano, y se lee el resultado de la anterior.
            if [ "${tipo:-wg}" = "socks" ]; then cada=$WGH_PROBE_EVERY_SOCKS; else cada=$WGH_PROBE_EVERY_WG; fi
            if [ $(( ahora - ${PROBE_T[$idx]:-0} )) -ge "$cada" ]; then
                _wgh_probe_launch "$idx" "${tipo:-wg}"; PROBE_T[$idx]="$ahora"
            fi

            if [ "${tipo:-wg}" = "socks" ]; then
                # Vivo = el movil mantiene su ssh -R, redsocks corre Y su
                # SOCKS da salida a Internet de verdad.
                MED_OK=0
                if _socks_reverse_up "$idx" && _socks_redsocks_up "$idx"; then
                    veredicto=$(_wgh_probe_verdict "$ahora" "$(_wgh_probe_last_ok "$idx")" "$WGH_PROBE_WINDOW_SOCKS")
                    [ "$veredicto" != "0" ] && MED_OK=1
                fi
                MED_RX=0; MED_TS="$ahora"
            elif ! _wgh_node_is_up "$idx"; then
                MED_OK=0; MED_RX="${RXP[$name]:--1}"; MED_TS="${TSP[$name]}"
            else
                veredicto=$(_wgh_probe_verdict "$ahora" "$(_wgh_probe_last_ok "$idx")" "$WGH_PROBE_WINDOW_WG")
                # El contador se sigue llevando (sirve de respaldo y para
                # saber si el tunel vive), pero manda la sonda si alguna vez
                # ha contestado: el tunel puede estar vivo y sin Internet.
                _wgh_measure_calc "${RX["${IFC[$idx]}|${key}"]:-}" "${KA["${IFC[$idx]}|${key}"]:-}" \
                                  "$ahora" "${RXP[$name]:--1}" "${TSP[$name]}"
                [ "$veredicto" != "?" ] && MED_OK="$veredicto"
            fi
            RXP[$name]="$MED_RX"; TSP[$name]="$MED_TS"

            racha="${RACHA[$name]:-0}"
            _wgh_health_step "$estado" "$racha" "$MED_OK"
            nuevo="$HS_ESTADO"; RACHA[$name]="$HS_RACHA"
            ESTADO[$name]="$nuevo"

            if [ "$nuevo" != "$estado" ]; then
                cambio=1
                if [ "$nuevo" = "down" ]; then
                    bk=$(_wgh_node_backup_of "$name")
                    if [ -n "$bk" ] && [ "${ESTADO[$bk]:-up}" = "up" ]; then
                        _wgh_log "Nodo '${name}' CAIDO: sus usuarios pasan al respaldo '${bk}'"
                    else
                        _wgh_log "Nodo '${name}' CAIDO: sus usuarios pasan a la IP del VPS"
                    fi
                else
                    _wgh_log "Nodo '${name}' recuperado: vuelve a dar salida"
                fi
            fi
        done < <(printf '%s\n' "${LISTA[@]}")

        # Un cambio en un nodo puede afectar a otros (si era respaldo de
        # alguien), asi que se reconcilia todo. Y cada 15 vueltas aunque
        # no cambie nada: es lo que repara cualquier desajuste.
        if [ "$cambio" = "1" ] || [ $(( vuelta % 15 )) -eq 0 ]; then
            _wgh_reconcile ESTADO
            _wgh_health_dump ESTADO
        fi

        sleep "$WGH_WATCH_INTERVAL"
    done
}

# Vuelca el estado a /run para que el panel pueda leerlo.
_wgh_health_dump() {
    local -n _e="$1"
    local k tmp="${WGH_HEALTH_FILE}.tmp"
    { for k in "${!_e[@]}"; do echo "${k}=${_e[$k]}"; done; } > "$tmp" 2>/dev/null || return
    mv -f "$tmp" "$WGH_HEALTH_FILE" 2>/dev/null
}

_wgh_health_of() {
    [ -f "$WGH_HEALTH_FILE" ] || { echo "up"; return; }
    local v
    v=$(sed -n "s/^$1=//p" "$WGH_HEALTH_FILE" 2>/dev/null | head -1)
    echo "${v:-up}"
}

# ---------------------------------------------------------
# Servicios
# ---------------------------------------------------------
_wgh_watchdog_is_on() { systemctl is-enabled homevpn-watchdog.service &>/dev/null; }

_wgh_watchdog_enable() {
    local dir
    dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    cat > "$WGH_WATCH_SERVICE" <<EOF
[Unit]
Description=Vigilante de nodos residenciales
After=network-online.target homevpn-rules.service

[Service]
Type=simple
ExecStart=/bin/bash ${dir}/wg_home.sh --watchdog
Restart=always
RestartSec=5
Nice=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload &>/dev/null
    systemctl enable homevpn-watchdog.service &>/dev/null
    # restart y no 'start': si ya corria con codigo viejo, que recoja el nuevo.
    systemctl restart homevpn-watchdog.service &>/dev/null
    _wgh_log "Vigilante activado"
}

_wgh_watchdog_disable() {
    systemctl disable --now homevpn-watchdog.service &>/dev/null
    rm -f "$WGH_WATCH_SERVICE"
    systemctl daemon-reload &>/dev/null
    # Al apagarlo se devuelven todas las rutas: si no, un nodo que
    # quedo marcado como caido se quedaria fuera para siempre.
    local i
    if [ -f "$WGH_ROUTING_FLAG" ]; then
        for i in $(_wgh_nodes_list | cut -d'|' -f3); do _wgh_node_path_on "$i"; _wgh_backup_off "$i"; done
    fi
    rm -f "$WGH_HEALTH_FILE"
    _wgh_log "Vigilante desactivado y rutas restauradas"
}

# ---------------------------------------------------------
# PERSISTENCIA: que la salida residencial sobreviva a un
# reinicio del VPS. Las reglas de iptables e 'ip rule' viven
# en memoria; antes, tras reiniciar, desaparecian en silencio
# y todos los usuarios pasaban a salir por la IP del VPS.
# ---------------------------------------------------------
WGH_ROUTING_FLAG="/etc/wireguard/homevpn-routing.on"

_wgh_persist_on() {
    local dir
    dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    mkdir -p /etc/wireguard 2>/dev/null
    touch "$WGH_ROUTING_FLAG"
    cat > "$WGH_SERVICE_FILE" <<EOF
[Unit]
Description=Restaura la salida residencial (vpsservice)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash ${dir}/wg_home.sh --restore

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload &>/dev/null
    systemctl enable homevpn-rules.service &>/dev/null
}

_wgh_persist_off() {
    rm -f "$WGH_ROUTING_FLAG"
    systemctl disable homevpn-rules.service &>/dev/null
    rm -f "$WGH_SERVICE_FILE"
    systemctl daemon-reload &>/dev/null
}

# Vuelve a montar todo: interfaces de los nodos y reglas. Lo usan
# el arranque del VPS y el guardian de servicios.
wghome_restore() {
    [ -f "$WGH_ROUTING_FLAG" ] || return 0
    declare -F refresh_ports >/dev/null || source "$_INST_DIR/../network.sh"
    refresh_ports
    _wgh_nodes_up_all >/dev/null 2>&1
    _wgh_apply_user_routing >/dev/null 2>&1
    _wgh_log "Salida residencial restaurada"
}

# ¿Sigue montada? Barato: lo llama el guardian cada minuto.
_wgh_rules_present() {
    iptables -t mangle -S OUTPUT 2>/dev/null | grep -q "HOMEVPN_EXCLUDE" || return 1
    # Instalaciones anteriores no tenian el bloqueo IPv6: asi el guardian
    # lo pone solo en menos de un minuto.
    if _wgh_has_ipv6 && ! _wgh_v6_present; then return 1; fi
    local name key idx type
    while IFS='|' read -r name key idx type _; do
        [ -z "$idx" ] && continue
        if [ "${type:-wg}" = "socks" ]; then
            _socks_redsocks_up "$idx" || return 1
        else
            _wgh_node_is_up "$idx" || return 1
            ip rule show 2>/dev/null | grep -q "fwmark $(_wgn_mark "$idx") lookup" || return 1
        fi
    done < <(_wgh_nodes_list)
    return 0
}

wghome_check_restore() {
    [ -f "$WGH_ROUTING_FLAG" ] || return 0
    _wgh_rules_present && return 0
    _wgh_log "Faltaban reglas de la salida residencial: restaurando"
    wghome_restore
}

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


# =========================================================
# wg-home.conf — UNA sola fuente de verdad
# ---------------------------------------------------------
# wg-home es la interfaz del nodo 1, y su archivo lo escribian
# dos generadores distintos: el del modelo actual (un peer con
# AllowedIPs 0.0.0.0/0) y el del modelo antiguo de un solo
# tunel (TODOS los nodos con AllowedIPs <ip>/32). Con /32,
# WireGuard descarta las respuestas de Internet que vuelven por
# el nodo, porque su origen no es la IP del nodo: el nodo 1 se
# quedaba sin salida. Y la "reparacion" que corria al abrir el
# menu detectaba el /32... y lo reescribia con el generador
# antiguo, que volvia a poner /32. Ahora todo pasa por aqui.
# =========================================================
_wgh_render_conf() {
    local priv="$1" peer_pub="${2:-}" k1
    # Nodo 1 registrado y de tipo WireGuard: su conf es la del nodo.
    if [ "$(_wgh_node_name_of 1)" != "" ] && [ "$(_wgh_idx_type 1)" = "wg" ]; then
        k1=$(_wgh_node_key_of "$(_wgh_node_name_of 1)")
        if [ -n "$k1" ]; then _wgh_node_render 1 "$k1"; return 0; fi
    fi
    cat <<EOF
# =========================================================
# Gateway Residencial — interfaz ${WGH_IFACE} (nodo 1)
# Table = off: wg-quick no toca la tabla main del VPS.
# =========================================================
[Interface]
Address    = ${WGH_DROPLET_IP}/24
ListenPort = ${WGH_PORT}
PrivateKey = ${priv}
Table      = off

EOF
    # Instalacion muy antigua: clave suelta del unico peer, sin registro.
    if [ -n "$peer_pub" ] && [ "$(_wgh_nodes_count)" -eq 0 ]; then
        cat <<EOF
[Peer]
# Nodo residencial (registro heredado)
PublicKey           = ${peer_pub}
AllowedIPs          = 0.0.0.0/0
PersistentKeepalive = 0
EOF
    fi
}

# Deja wg-home.conf exactamente como debe estar, y si la interfaz esta
# arriba aplica el cambio en caliente (sin cortar a nadie).
_wgh_repair_conf_if_needed() {
    [ -f "$WGH_CONF" ] || return 0
    local priv peer_pub="" want
    priv=$(cat "${WGH_PRIV_KEY}" 2>/dev/null)
    [ -z "$priv" ] && return 0
    [ -f "$WGH_PEER_KEY" ] && peer_pub=$(tr -d '[:space:]' < "$WGH_PEER_KEY" 2>/dev/null)
    want=$(_wgh_render_conf "$priv" "$peer_pub")
    [ "$want" = "$(cat "$WGH_CONF" 2>/dev/null)" ] && return 0
    # Seguro: una reparacion NUNCA deja sin peer una interfaz que lo tiene.
    # Si el registro no reconoce al nodo 1 (formato antiguo, archivo
    # dañado...), quitar el peer corta el tunel que estaba funcionando:
    # mejor no tocar nada y dejarlo anotado.
    if ! grep -q '^\[Peer\]' <<<"$want" && grep -q '^\[Peer\]' "$WGH_CONF" 2>/dev/null; then
        _wgh_log "AVISO: no se reescribe ${WGH_CONF}: quitaria el peer del nodo 1 (registro sin nodo 1)"
        return 0
    fi
    _wgh_log "Reescribiendo ${WGH_CONF} con la configuracion del nodo 1"
    printf '%s\n' "$want" > "$WGH_CONF"
    chmod 600 "$WGH_CONF"
    if _wgh_is_up; then
        wg syncconf "${WGH_IFACE}" <(wg-quick strip "${WGH_IFACE}" 2>/dev/null) 2>/dev/null || true
    fi
}

# =========================================================
# CUENTAS DE CLIENTE
# =========================================================

# Obtiene la lista de usuarios reales del sistema con UID >= 1000 (excluye root y nobody)
_wgh_get_client_users() {
    awk -F: '$3 >= 1000 && $3 != 65534 && $1 != "nobody" && $1 != "ubuntu" {print $1 ":" $3}' /etc/passwd 2>/dev/null
}


# =========================================================
# FUGA POR IPv6
# ---------------------------------------------------------
# Todo el desvio a los nodos (marcas, tablas, REDIRECT) es de
# iptables, o sea IPv4. Cuando un cliente navega, quien abre la
# conexion es el sshd del VPS, y si el VPS tiene IPv6 lo prueba
# PRIMERO con los sitios que lo tienen (Google, YouTube,
# Facebook, Cloudflare...). Esas conexiones salian directas con
# la IP del VPS y el nodo solo veia una parte del trafico. Y el
# diagnostico, que probaba con 'curl -4', decia que todo iba bien.
#
# Arreglo: a los usuarios que salen por un nodo se les RECHAZA el
# TCP por IPv6 con un reset. sshd recibe el rechazo al instante y
# prueba la siguiente direccion del destino, la IPv4, que si pasa
# por el nodo. No se pierde ninguna conexion, solo cambia la familia.
#
# Lo que nunca se toca: el loopback y las respuestas de la propia
# sesion SSH del cliente (si entro al VPS por IPv6, su tunel sigue).
# =========================================================
WGH_V6_CHAIN="HOMEVPN6"

_wgh_has_ipv6() {
    command -v ip6tables &>/dev/null || return 1
    ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'
}

# Reglas de la cadena, una por linea (funcion pura, se prueba sin root).
#   _wgh_v6_rules "<uids>" "<puertos_origen_excluidos>"
_wgh_v6_rules() {
    local uids="$1" sports="$2" p u
    echo "-A ${WGH_V6_CHAIN} -d ::1/128 -j RETURN"
    for p in $sports; do
        echo "-A ${WGH_V6_CHAIN} -p tcp --sport ${p} -j RETURN"
    done
    for u in $uids; do
        echo "-A ${WGH_V6_CHAIN} -p tcp -m owner --uid-owner ${u} -j REJECT --reject-with tcp-reset"
    done
}

# Rehace la cadena con los usuarios enrutados ahora mismo.
_wgh_v6_apply() {
    local uids="$1" sports="$2" r
    command -v ip6tables &>/dev/null || return 0
    ip6tables -N "$WGH_V6_CHAIN" 2>/dev/null
    ip6tables -F "$WGH_V6_CHAIN" 2>/dev/null || return 0
    while IFS= read -r r; do
        # shellcheck disable=SC2086
        [ -n "$r" ] && ip6tables $r 2>/dev/null
    done < <(_wgh_v6_rules "$uids" "$sports")
    ip6tables -C OUTPUT -j "$WGH_V6_CHAIN" 2>/dev/null || \
        ip6tables -I OUTPUT 1 -j "$WGH_V6_CHAIN" 2>/dev/null
}

_wgh_v6_off() {
    command -v ip6tables &>/dev/null || return 0
    while ip6tables -D OUTPUT -j "$WGH_V6_CHAIN" 2>/dev/null; do :; done
    ip6tables -F "$WGH_V6_CHAIN" 2>/dev/null
    ip6tables -X "$WGH_V6_CHAIN" 2>/dev/null
}

_wgh_v6_present() {
    ip6tables -C OUTPUT -j "$WGH_V6_CHAIN" 2>/dev/null
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
    local -A want=()
    local v6uids=""
    while IFS='|' read -r name key idx type _; do
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

            ip rule show | grep -qE "fwmark ${mark} lookup $(_wgn_table_re "$idx")( |$)" || \
                ip rule add fwmark "${mark}" table "${tbl}" priority $(( 1000 + idx )) 2>/dev/null || true

            # Regla por origen: lo que salga con la IP de esta interfaz usa
            # su tabla. Sin esto, un 'curl --interface wg-homeN' se va por
            # eth0 con un origen que no le corresponde, y la comprobacion
            # de IP de salida da un resultado enganoso.
            ip rule show | grep -qE "from $(_wgn_vpsip "$idx") lookup $(_wgn_table_re "$idx")( |$)" || \
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
            want["${uid}|${mark}"]=1
            v6uids="${v6uids} ${uid}"
            n=$((n+1))
        done < <(_wgh_node_users "$name")
        total_users=$(( total_users + n ))
        _wgh_log "Nodo ${name} (${ifc}, marca ${mark}, tabla ${tbl}): ${n} usuario(s)"
    done < <(_wgh_nodes_list)

    # Marcas que ya no tocan: un usuario reasignado o devuelto a la IP
    # del VPS, o una cuenta borrada. Antes nunca se quitaban, asi que
    # "quitar la salida residencial" a un usuario no surtia efecto hasta
    # apagar y encender todo. Se quitan DESPUES de poner las nuevas: el
    # usuario no pasa ni un instante sin marca.
    local rule ruid rmark
    while IFS= read -r rule; do
        ruid=$(sed -n 's/.*--uid-owner \([0-9]*\).*/\1/p' <<<"$rule")
        rmark=$(sed -n 's/.*--set-xmark \(0x[0-9a-f]*\).*/\1/p' <<<"$rule")
        { [ -z "$ruid" ] || [ -z "$rmark" ]; } && continue
        [ -n "${want["${ruid}|${rmark}"]:-}" ] && continue
        # shellcheck disable=SC2086
        iptables -t mangle ${rule/-A /-D } 2>/dev/null || true
    done < <(iptables -t mangle -S OUTPUT 2>/dev/null | grep "HOMEVPN_MARK")

    # Marcas de la version de una sola salida (etiqueta HOMEVPN_HTTP_INJECTOR).
    # Las nuevas ya estan puestas, asi que se retiran: si no, un usuario al
    # que se le quita la salida residencial seguiria saliendo por casa.
    while rule=$(iptables -t mangle -S OUTPUT 2>/dev/null | grep "HOMEVPN_HTTP_INJECTOR" | head -1) && [ -n "$rule" ]; do
        # shellcheck disable=SC2086
        iptables -t mangle ${rule/-A /-D } 2>/dev/null || break
    done

    _wgh_isolate_on

    # IPv6: que los usuarios enrutados no se salten el nodo por la otra
    # familia. Se excluyen las respuestas de los puertos por los que entran.
    local v6sports="22" p
    for p in "$PORT_SSH" "$PORT_SSL" "$PORT_WS" "$PORT_DROPBEAR"; do
        [ -n "$p" ] && [[ " $v6sports " != *" $p "* ]] && v6sports="$v6sports $p"
    done
    _wgh_v6_apply "$v6uids" "$v6sports"

    # Lo de arriba abre el camino de TODOS los nodos. Si el vigilante
    # tiene alguno por caido, se respeta: si no, al reasignar un usuario
    # se devolveria trafico a un nodo muerto hasta la siguiente vuelta.
    if [ -f "$WGH_HEALTH_FILE" ]; then
        local -A _salud=()
        local k v
        while IFS='=' read -r k v; do [ -n "$k" ] && _salud[$k]="$v"; done < "$WGH_HEALTH_FILE"
        _wgh_reconcile _salud
    fi
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
        while ip rule show | grep -qE "fwmark ${mark} lookup $(_wgn_table_re "$i")( |$)"; do
            ip rule del fwmark "${mark}" table "${tbl}" 2>/dev/null || break
        done
        while ip rule show | grep -qE "lookup $(_wgn_table_re "$i")\b"; do
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
    for tag in HOMEVPN_NAT HOMEVPN_SOCKS_BK HOMEVPN_SOCKS; do
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
    while IFS='|' read -r sname skey sidx styp _; do
        [ "${styp:-wg}" = "socks" ] && _socks_down "$sidx"
    done < <(_wgh_nodes_list)
    while iptables -S FORWARD 2>/dev/null | grep -q "HOMEVPN_FORWARD"; do
        rule=$(iptables -S FORWARD 2>/dev/null | grep "HOMEVPN_FORWARD" | head -1 | sed 's/^-A /-D /')
        [ -z "$rule" ] && break
        # shellcheck disable=SC2086
        iptables $rule 2>/dev/null || break
    done
    _wgh_isolate_off
    _wgh_v6_off

    _wgh_verify_ssh_route
    _wgh_log "Desactivacion completada"
}

# =========================================================
# 1. INSTALAR / CONFIGURAR GATEWAY RESIDENCIAL
# =========================================================
wghome_install() {
    clear
    print_title 2>/dev/null || true
        ui_section "INSTALAR GATEWAY RESIDENCIAL (WireGuard)"

    if _wgh_is_installed; then
        ui_warn "El gateway ya está configurado."
        echo -e "  ${DM}    Conf: ${WGH_CONF}${CR}"
        echo ""
        ui_prompt "¿Reinstalar/sobreescribir? (s/n)"; resp="$REPLY_UI"
        if [[ "$resp" != "s" && "$resp" != "S" ]]; then
            ui_info "Operación cancelada."; sleep 1; return
        fi
        systemctl stop "wg-quick@${WGH_IFACE}" 2>/dev/null
    fi

    # Paso 1: Instalar WireGuard
    echo ""
    _wgh_ensure_installed || { sleep 2; return 1; }

    # Paso 2: Habilitar forwarding
    ui_info "Habilitando IP forwarding..."
    _wgh_enable_forwarding
    ui_ok "IP forwarding activo."

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
        ui_warn "Esta Droplet ya tiene su par de claves."
        echo -e "  ${DM}      Publica actual: $(cat "${WGH_PUB_KEY}" 2>/dev/null)${CR}"
        ui_warn "Generar unas nuevas DESCONECTA todos los nodos"
        echo -e "  ${DM}      registrados: habria que reconfigurarlos uno a uno.${CR}"
        echo ""
        if ui_confirm "¿Conservar las claves actuales?" "s"; then
            [ -s "${WGH_PUB_KEY}" ] || wg pubkey < "${WGH_PRIV_KEY}" > "${WGH_PUB_KEY}"
            ui_ok "Claves conservadas: los nodos siguen validos."
        else
            (umask 077; wg genkey > "${WGH_PRIV_KEY}")
            wg pubkey < "${WGH_PRIV_KEY}" > "${WGH_PUB_KEY}"
            _wgh_log "Claves de la Droplet REGENERADAS: nodos invalidados"
            ui_warn "Claves nuevas. Actualiza la clave del VPS en cada nodo."
        fi
    else
        ui_info "Generando par de claves para la Droplet..."
        (umask 077; wg genkey > "${WGH_PRIV_KEY}")
        wg pubkey < "${WGH_PRIV_KEY}" > "${WGH_PUB_KEY}"
        ui_ok "Claves generadas (privada protegida chmod 600)."
    fi
    chmod 600 "${WGH_PRIV_KEY}"
    chmod 644 "${WGH_PUB_KEY}"

    # Paso 5: wg-home.conf. Antes se migra el peer unico de versiones
    # antiguas, para que el conf ya lo incluya como nodo 1.
    _wgh_nodes_migrate
    ui_info "Creando ${WGH_CONF}..."
    local priv peer_pub=""
    priv=$(cat "${WGH_PRIV_KEY}")
    [ -f "${WGH_PEER_KEY}" ] && peer_pub=$(cat "${WGH_PEER_KEY}" 2>/dev/null)

    _wgh_render_conf "$priv" "$peer_pub" > "${WGH_CONF}"
    chmod 600 "${WGH_CONF}"
    ui_ok "${WGH_CONF} creado con Table = off (seguridad SSH)."

    # Paso 6: Abrir firewall
    _wgh_open_firewall

    # Paso 7: Habilitar servicio systemd
    systemctl enable "wg-quick@${WGH_IFACE}" &>/dev/null
    ui_ok "Servicio wg-quick@${WGH_IFACE} habilitado."
    # 'enable' solo programa el arranque futuro. Sin este 'start' la
    # Droplet quedaba instalada pero sin escuchar, y los nodos
    # enviaban handshakes contra un puerto que no atendia nadie.
    systemctl start "wg-quick@${WGH_IFACE}" &>/dev/null
    _wgh_nodes_up_all
    if _wgh_is_up; then
        ui_ok "Túnel ${WGH_IFACE} levantado y escuchando en ${WGH_PORT}/UDP."
    else
        ui_warn "El túnel no arrancó todavía (normal si aún no hay nodos)."
    fi

    _wgh_log "Gateway residencial instalado exitosamente"

    echo ""
    ui_solid
    ui_ok "¡Instalación completada!"
    echo ""
    ui_warn "Pasos siguientes:"
    echo -e "${UI_PAD}${DM}  1. NODOS > REGISTRAR NODO PC (o MÓVIL) con la clave del equipo.${CR}"
    echo -e "${UI_PAD}${DM}  2. NODOS > DATOS PARA EL NODO: lo que hay que poner en él.${CR}"
    echo -e "${UI_PAD}${DM}  3. ASIGNAR USUARIOS: quién sale por cada nodo.${CR}"
    echo -e "${UI_PAD}${DM}  4. Enciende la SALIDA RESIDENCIAL (activa también el vigilante).${CR}"
    ui_solid
    ui_pause
}

# =========================================================
# 2. MOSTRAR CLAVE PÚBLICA DE LA DROPLET
# =========================================================
wghome_show_pubkey() {
    clear
    print_title 2>/dev/null || true
        ui_section "DATOS PARA CONFIGURAR UN NODO"

    if [ ! -f "${WGH_PUB_KEY}" ]; then
        ui_err "No se encontró la clave pública."
        echo -e "  ${DM}    Instala el gateway primero (AVANZADO > INSTALAR).${CR}"
        sleep 2; return
    fi

    local pub ip_pub
    pub=$(cat "${WGH_PUB_KEY}")
    ip_pub=$(_wgh_get_droplet_ip)

    echo ""
    if [ -n "$ip_pub" ]; then
        echo -e "  ${DM}IP pública Droplet :${CR} ${GR}${ip_pub}${CR}"
        echo -e "  ${DM}   ${YL}Comprueba que es la misma por la que entras por SSH.${CR}"
        echo -e "  ${DM}   Si no lo es, corrígela en AVANZADO > DIRECCIÓN PÚBLICA.${CR}"
    else
        echo -e "  ${RD}IP pública Droplet : NO SE PUDO AVERIGUAR${CR}"
        echo -e "  ${DM}   Fíjala en AVANZADO > DIRECCIÓN PÚBLICA; sin ella los${CR}"
        echo -e "  ${DM}   nodos no saben a dónde abrir el túnel.${CR}"
        ip_pub="<PON_AQUI_LA_IP_DEL_VPS>"
    fi
    echo -e "  ${DM}Puertos WireGuard  :${CR} ${CY}51820 + (n.º de nodo - 1)${CR} ${DM}— cada nodo el suyo${CR}"
    echo ""
    echo -e "  ${YL}[ Clave Pública de la Droplet ]${CR}"
    echo -e "  ${WH}${pub}${CR}"
    echo -e "  ${DM}Esta va en el campo PublicKey del nodo.${CR}"
    echo ""

    _wgh_nodes_migrate
    local total
    total=$(_wgh_nodes_count)

    if [ "${total:-0}" -eq 0 ]; then
        ui_solid
        ui_warn "Todavía no hay ningún nodo registrado."
        echo -e "  ${DM}    Regístralo primero en GESTIONAR NODOS: allí se le${CR}"
        echo -e "  ${DM}    asigna su dirección, y sin ella esta pantalla no${CR}"
        echo -e "  ${DM}    puede decirte qué poner en el campo Address.${CR}"
        ui_solid
        ui_pause
        return
    fi

    # Cada nodo tiene SU direccion. Enseñar una plantilla con la IP
    # fija de antes hacia que el segundo nodo se configurase con la
    # del primero, y entonces la Droplet le rechazaba los paquetes
    # por venir de una IP fuera de su AllowedIPs.
    ui_solid
    echo -e "  ${WH}Nodos registrados${CR}"
    echo ""
    local name key idx type n=0 etiq
    while IFS='|' read -r name key idx type _; do
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
    ui_prompt "¿De qué nodo quieres la configuración? [1-${n}] (Enter = salir)"; pick="$REPLY_UI"
    [ -z "$pick" ] && return

    local line
    line=$(_wgh_nodes_list | sed -n "${pick}p")
    [ -z "$line" ] && { ui_err "Opción no válida."; sleep 2; return; }

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
    # Cada nodo tiene SU puerto y SU red. Antes esta pantalla daba los del
    # nodo 1 a todos: un nodo 2 configurado con ella llamaba a la interfaz
    # del nodo 1, que no lo conoce, y no conectaba nunca.
    local n_ip n_port n_vps
    n_ip=$(_wgn_nodeip "$n_idx"); n_port=$(_wgn_port "$n_idx"); n_vps=$(_wgn_vpsip "$n_idx")

    clear
    print_title 2>/dev/null || true
        ui_section "CONFIGURACIÓN DEL NODO: ${n_name}"
    echo ""
    echo -e "  ${DM}Dirección asignada :${CR} ${CY}${n_ip}${CR}"
    echo -e "  ${DM}Clave registrada   :${CR} ${DM}${n_key}${CR}"
    echo ""
    echo -e "  ${YL}━━━ Si usas el panel del nodo (node.sh) ━━━${CR}"
    echo -e "  ${DM}En su asistente, cuando pida los datos:${CR}"
    echo -e "  ${DM}  Host del VPS :${CR} ${WH}${ip_pub}${CR}"
    echo -e "  ${DM}  Puerto       :${CR} ${WH}${n_port}${CR}"
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
    echo -e "  ${WH}Endpoint            = ${ip_pub}:${n_port}${CR}"
    echo -e "  ${WH}AllowedIPs          = ${n_vps}/32${CR}"
    echo -e "  ${WH}PersistentKeepalive = 25${CR}"
    echo ""
    echo -e "  ${DM}Y para compartir su salida a Internet (ajusta la interfaz):${CR}"
    echo -e "  ${DM}PostUp   = iptables -A FORWARD -i ${WGH_IFACE} -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE${CR}"
    echo -e "  ${DM}PostDown = iptables -D FORWARD -i ${WGH_IFACE} -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE${CR}"
    echo ""
    ui_warn "La clave privada de la Droplet NUNCA se comparte."
    ui_warn "La privada del nodo se queda en el nodo: aquí solo"
    echo -e "  ${DM}      se guarda su clave pública.${CR}"
    ui_solid
    ui_pause
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
            while IFS='|' read -r name key idx type _; do
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

        ui_opt "1" "REGISTRAR NODO PC"    "WireGuard"
        ui_opt "2" "REGISTRAR NODO MÓVIL" "celular sin root"
        ui_opt "3" "DATOS PARA EL NODO"   "qué poner allí"
        ui_opt_danger "4" "ELIMINAR NODO" "sus usuarios -> IP VPS"
        ui_opt "0" "VOLVER"
        ui_solid
        ui_prompt "Elige una opción [0-4]"

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
                _wgh_ensure_keys >/dev/null 2>&1
                local nidx
                nidx=$(_wgh_nodes_add "$nname" "$nkey")
                [ -z "$nidx" ] && { ui_err "No quedan indices libres."; sleep 2; continue; }
                ui_blank
                ui_info "Levantando su interfaz..."
                if _wgh_node_up "$nidx"; then ui_ok "Interfaz $(_wgn_iface "$nidx") activa."
                else ui_warn "La interfaz no arrancó; revisa el DIAGNÓSTICO."; fi
                ui_blank
                ui_ok "Nodo '${nname}' registrado."
                echo -e "${UI_PAD}${DM}   Configura EN EL NODO estos valores exactos:${CR}"
                echo -e "${UI_PAD}${DM}     Puerto del VPS :${CR} ${WH}$(_wgn_port "$nidx")${CR}"
                echo -e "${UI_PAD}${DM}     IP del nodo    :${CR} ${GR}$(_wgn_nodeip "$nidx")${CR}"
                echo -e "${UI_PAD}${DM}     IP del VPS     :${CR} ${WH}$(_wgn_vpsip "$nidx")${CR}"
                echo -e "${UI_PAD}${DM}   (DATOS PARA EL NODO te los repite cuando quieras)${CR}"
                ui_pause ;;
            2)  wghome_register_socks ;;
            3)  wghome_show_pubkey ;;
            4)  ui_blank
                ui_prompt "Nombre del nodo a eliminar"; dname="$REPLY_UI"
                _wgh_node_exists "$dname" || { ui_err "No existe ese nodo."; sleep 2; continue; }
                if ui_confirm "¿Eliminar '${dname}'? Sus usuarios volveran a la IP del VPS" "n"; then
                    _wgh_nodes_del "$dname"
                    { [ -f "$WGH_ROUTING_FLAG" ] || _wgh_routing_is_active; } && _wgh_apply_user_routing >/dev/null 2>&1
                    ui_ok "Nodo eliminado."
                fi
                ui_pause ;;
            0|"")  break ;;
            *)  ui_err "Opción no válida."; sleep 1 ;;
        esac
    done
}


# =========================================================
# 4. ACTIVAR TÚNEL WIREGUARD
# =========================================================
wghome_tunnel_up() {
    clear
    print_title 2>/dev/null || true
        ui_section "ACTIVAR TÚNEL WireGuard"

    if ! _wgh_is_installed; then
        ui_err "Gateway no instalado. Usa AVANZADO > INSTALAR."
        sleep 2; return
    fi

    _wgh_repair_conf_if_needed

    if ! grep -q "^\[Peer\]" "${WGH_CONF}" 2>/dev/null; then
        ui_err "No hay Peer registrado en ${WGH_CONF}."
        ui_warn "Registra un nodo PC en NODOS."
        sleep 2; return
    fi

    if _wgh_is_up; then
        ui_warn "El túnel ${WGH_IFACE} ya está activo."
        sleep 1; return
    fi

    ui_info "Verificando que SSH no se verá afectado..."
    _wgh_verify_ssh_route || { sleep 2; return 1; }

    ui_info "Levantando wg-quick@${WGH_IFACE}..."
    systemctl start "wg-quick@${WGH_IFACE}" 2>/dev/null
    sleep 2

    if _wgh_is_up; then
        ui_ok "Túnel ${WGH_IFACE} activo."
        echo ""
        echo -e "  ${DM}Interfaz:${CR}"
        ip addr show "${WGH_IFACE}" 2>/dev/null | grep -E "inet|link" | sed 's/^/    /'
        echo ""
        _wgh_verify_ssh_route && ui_ok "SSH protegido — tabla main intacta."
        _wgh_log "Túnel wg-home levantado"
    else
        ui_err "Error levantando túnel. Revisa: journalctl -u wg-quick@${WGH_IFACE} -n 20"
        _wgh_log "ERROR al levantar túnel wg-home"
    fi

    echo ""
    ui_pause
}

# =========================================================
# 5. DESACTIVAR TÚNEL WIREGUARD
# =========================================================
wghome_tunnel_down() {
    clear
    print_title 2>/dev/null || true
        ui_section "DESACTIVAR TÚNEL WireGuard"

    if ! _wgh_is_up; then
        ui_warn "El túnel ${WGH_IFACE} ya está inactivo."
        sleep 1; return
    fi

    if _wgh_routing_is_active || [ -f "$WGH_ROUTING_FLAG" ]; then
        ui_info "Desactivando salida residencial primero para evitar rutas huérfanas..."
        _wgh_persist_off
        _wgh_routing_off_internal
    fi

    ui_info "Deteniendo wg-quick@${WGH_IFACE}..."
    systemctl stop "wg-quick@${WGH_IFACE}" 2>/dev/null
    sleep 1

    if ! _wgh_is_up; then
        ui_ok "Túnel ${WGH_IFACE} desactivado."
        _wgh_verify_ssh_route && ui_ok "SSH protegido — ruta por defecto intacta."
        _wgh_log "Túnel wg-home detenido"
    else
        ui_err "Error al detener el túnel."
    fi

    sleep 1
    ui_pause
}


# =========================================================
# 12. ELIMINAR CONFIGURACIÓN COMPLETA
# =========================================================
wghome_remove() {
    clear
    print_title 2>/dev/null || true
        ui_section "⚠   ELIMINAR GATEWAY RESIDENCIAL   ⚠"
    echo ""
    ui_warn "Esta acción eliminará:"
    echo -e "  ${DM}  • /etc/wireguard/wg-home.conf${CR}"
    echo -e "  ${DM}  • /etc/wireguard/wghome_droplet_private.key${CR}"
    echo -e "  ${DM}  • /etc/wireguard/wghome_droplet_public.key${CR}"
    echo -e "  ${DM}  • /etc/wireguard/wghome_peer_public.key${CR}"
    echo -e "  ${DM}  • ${WGH_USERS_CONF} y ${WGH_FALLBACK_CONF}${CR}"
    echo -e "  ${DM}  • Servicio wg-quick@wg-home${CR}"
    echo -e "  ${DM}  • Reglas de tabla ${WGH_RT_NAME} (${WGH_RT_TABLE})${CR}"
    echo -e "  ${DM}  • Entrada en /etc/iproute2/rt_tables${CR}"
    echo ""
    ui_prompt "¿Continuar? (s/n)"; resp="$REPLY_UI"
    if [[ "$resp" != "s" && "$resp" != "S" ]]; then
        ui_info "Operación cancelada."; sleep 1; return
    fi

    ui_prompt "Escribe ELIMINAR para confirmar"; confirm="$REPLY_UI"
    if [[ "$confirm" != "ELIMINAR" ]]; then
        ui_err "Texto incorrecto. Cancelado."; sleep 2; return
    fi

    echo ""

    # 1. Desactivar enrutamiento, su restauracion al arrancar y el vigilante
    _wgh_persist_off
    _wgh_routing_off_internal
    _wgh_watchdog_is_on && _wgh_watchdog_disable

    # 2. Detener y deshabilitar servicio
    ui_info "Deteniendo servicio wg-quick@${WGH_IFACE}..."
    systemctl stop "wg-quick@${WGH_IFACE}" 2>/dev/null
    systemctl disable "wg-quick@${WGH_IFACE}" 2>/dev/null

    # 3. Eliminar archivos
    ui_info "Eliminando archivos de configuración..."
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
    _wgh_verify_ssh_route && ui_ok "SSH protegido — tabla main intacta."
    _wgh_log "Gateway residencial desinstalado y eliminado completamente"

    echo ""
    ui_solid
    ui_ok "Gateway residencial eliminado completamente."
    ui_solid
    sleep 2
    ui_pause
}

# =========================================================
# SALIDA DE CADA USUARIO — piezas compartidas
# ---------------------------------------------------------
# Las usan ASIGNAR USUARIOS y el alta de una cuenta nueva, que
# pregunta por donde va a salir el cliente. Una sola forma de
# elegir, para que las dos pantallas no se contradigan.
# =========================================================

# Usuarios que salen por algun nodo (formato: usuario|nodo)
_wgh_routed_users() {
    local u n
    while IFS= read -r u; do
        [ -z "$u" ] && continue
        n=$(_wgh_user_node "$u")
        [ -n "$n" ] && echo "${u}|${n}"
    done < <(_wgh_get_client_users | cut -d: -f1)
}

# Estado legible de un nodo, ya coloreado.
_wgh_node_status() {
    local name="$1" idx type hs
    idx=$(_wgh_node_idx_of "$name"); type=$(_wgh_idx_type "$idx")
    if [ -f "$WGH_ROUTING_FLAG" ] && [ "$(_wgh_health_of "$name")" = "down" ]; then
        echo -e "${RD}caido${CR}"; return
    fi
    if [ "$type" = "socks" ]; then
        if _socks_reverse_up "$idx"; then echo -e "${GR}conectado${CR}"
        else echo -e "${RD}movil desconectado${CR}"; fi
    else
        if ! _wgh_node_is_up "$idx"; then echo -e "${RD}apagado${CR}"; return; fi
        hs=$(_wgh_node_hs "$idx")
        if [ "$hs" -ge 0 ] 2>/dev/null && [ "$hs" -lt 180 ]; then echo -e "${GR}conectado${CR}"
        elif [ "$hs" -ge 0 ] 2>/dev/null; then echo -e "${YL}visto hace ${hs}s${CR}"
        else echo -e "${YL}nunca conecto${CR}"; fi
    fi
}

# Enciende la salida residencial sin preguntas: nodos, reglas,
# arranque persistente y vigilante. Es lo que hace falta para
# que el cliente no se quede sin servicio si un nodo cae.
_wgh_routing_enable() {
    _wgh_ensure_keys >/dev/null 2>&1
    _wgh_backup >/dev/null 2>&1
    _wgh_persist_on
    _wgh_nodes_up_all >/dev/null 2>&1
    _wgh_apply_user_routing >/dev/null 2>&1
    _wgh_watchdog_is_on || _wgh_watchdog_enable
}

# Muestra los destinos posibles y deja la eleccion en PICK_NODE
# ("" = IP del VPS). Devuelve 1 si el usuario cancela.
#   _wgh_pick_exit [actual]
_wgh_pick_exit() {
    local actual="${1:-}" name key idx type i=0 mark tipo
    local -a nombres=()
    PICK_NODE=""
    mark=""; [ -z "$actual" ] && mark=" ${GR}← actual${CR}"
    echo -e "${UI_PAD}${CY}[0]${CR} ${DM}▸${CR} ${WH}IP del VPS${CR} ${DM}(salida normal, siempre disponible)${CR}${mark}"
    while IFS='|' read -r name key idx type _; do
        [ -z "$idx" ] && continue
        i=$((i+1)); nombres+=("$name")
        [ "${type:-wg}" = "socks" ] && tipo="movil" || tipo="PC"
        mark=""; [ "$name" = "$actual" ] && mark=" ${GR}← actual${CR}"
        printf "${UI_PAD}${CY}[%s]${CR} ${DM}▸${CR} ${WH}%-14s${CR} ${DM}%-6s${CR} %b%b\n" \
            "$i" "$name" "$tipo" "$(_wgh_node_status "$name")" "$mark"
    done < <(_wgh_nodes_list)
    ui_blank
    while true; do
        ui_prompt "¿Por dónde sale a Internet? [0-${i}] (Enter = IP del VPS, c = cancelar)"
        case "$REPLY_UI" in
            ""|0) PICK_NODE=""; return 0 ;;
            c|C)  return 1 ;;
        esac
        if [[ "$REPLY_UI" =~ ^[0-9]+$ ]] && [ "$REPLY_UI" -ge 1 ] && [ "$REPLY_UI" -le "$i" ]; then
            PICK_NODE="${nombres[$((REPLY_UI-1))]}"; return 0
        fi
        # Tambien vale escribir el nombre del nodo
        if _wgh_node_exists "$REPLY_UI"; then PICK_NODE="$REPLY_UI"; return 0; fi
        ui_err "Opción no válida."
    done
}

# Asigna la salida y la deja funcionando. Si la salida residencial
# esta apagada, ofrece encenderla: asignar un nodo y que no surta
# efecto seria una trampa facil de pisar.
#   _wgh_set_user_exit <usuario> <nodo|"">
_wgh_set_user_exit() {
    local u="$1" node="$2"
    _wgh_user_assign "$u" "$node"
    if [ -f "$WGH_ROUTING_FLAG" ] || _wgh_routing_is_active; then
        _wgh_apply_user_routing >/dev/null 2>&1
    elif [ -n "$node" ]; then
        ui_warn "La salida residencial está apagada."
        if ui_confirm "¿Encenderla ahora para que ${u} salga por ${node}?" "s"; then
            ui_info "Encendiendo la salida residencial..."
            _wgh_routing_enable
        else
            ui_warn "${u} saldrá por ${node} cuando la enciendas. Mientras, usa la IP del VPS."
            return 0
        fi
    fi
    if [ -n "$node" ]; then
        ui_ok "${WH}${u}${CR} sale por ${GR}${node}${CR}."
        local bk; bk=$(_wgh_node_backup_of "$node")
        echo -e "${UI_PAD}${DM}    Si ${node} cae: ${bk:+pasa a ${bk}, y si también cae: }la IP del VPS. Nunca se queda sin Internet.${CR}"
        echo -e "${UI_PAD}${DM}    Por el nodo va su TCP (web y apps); el UDP sale por el VPS.${CR}"
    else
        ui_ok "${WH}${u}${CR} sale por la IP del VPS."
    fi
}

# =========================================================
# ASIGNAR CADA USUARIO A SU NODO
# =========================================================
wghome_assign_users() {
    while true; do
        clear
        print_title 2>/dev/null || true
        ui_section "SALIDA POR USUARIO" "quién sale por qué nodo"
        ui_blank

        if [ "$(_wgh_nodes_count)" -eq 0 ]; then
            ui_warn "Aún no hay nodos: todos los usuarios salen por la IP del VPS."
            echo -e "${UI_PAD}${DM}Registra uno en IP RESIDENCIAL > NODOS.${CR}"
            ui_pause; return
        fi

        local -a us=()
        local u n i=0
        while IFS= read -r u; do
            [ -z "$u" ] && continue
            us+=("$u"); i=$((i+1))
            n=$(_wgh_user_node "$u")
            if [ -n "$n" ]; then
                printf "${UI_PAD}${CY}[%2d]${CR} ${WH}%-16s${CR} ${DM}sale por${CR} ${GR}%-14s${CR} %b\n" "$i" "$u" "$n" "$(_wgh_node_status "$n")"
            else
                printf "${UI_PAD}${CY}[%2d]${CR} ${WH}%-16s${CR} ${DM}sale por la IP del VPS${CR}\n" "$i" "$u"
            fi
        done < <(_wgh_get_client_users | cut -d: -f1)

        [ ${#us[@]} -eq 0 ] && { ui_blank; ui_warn "No hay cuentas de cliente creadas."; ui_pause; return; }

        ui_blank
        ui_rule
        echo -e "${UI_PAD}${DM}root y el SSH de administración nunca se enrutan.${CR}"
        ui_prompt "Número del usuario a cambiar (Enter = volver)"
        local pick="$REPLY_UI"
        [ "$pick" = "0" ] || [ -z "$pick" ] && return
        if ! [[ "$pick" =~ ^[0-9]+$ ]] || [ "$pick" -lt 1 ] || [ "$pick" -gt ${#us[@]} ]; then
            ui_err "Fuera de rango."; sleep 1; continue
        fi

        local target="${us[$((pick-1))]}"
        ui_blank
        echo -e "${UI_PAD}${WH}Salida para ${target}${CR}"
        _wgh_pick_exit "$(_wgh_user_node "$target")" || continue
        _wgh_set_user_exit "$target" "$PICK_NODE"
        sleep 2
    done
}

# =========================================================
# ENCENDER / APAGAR LA SALIDA RESIDENCIAL
# =========================================================
wghome_routing_on() {
    clear
    print_title 2>/dev/null || true
    ui_section "ENCENDER SALIDA RESIDENCIAL" "cada usuario sale por su nodo"
    ui_blank

    if [ "$(_wgh_nodes_count)" -eq 0 ]; then
        ui_err "No hay nodos registrados. Registra uno en NODOS."
        ui_pause; return
    fi
    _wgh_repair_conf_if_needed
    if ! _wgh_verify_ssh_route; then
        ui_err "Abortado: la ruta por defecto no es segura para el SSH."
        _wgh_log "Abortada activacion: ruta SSH comprometida"
        ui_pause; return
    fi

    local nu
    nu=$(_wgh_routed_users | wc -l)
    [ "$nu" -eq 0 ] && ui_warn "Aún no hay usuarios asignados a un nodo. Asígnalos en ASIGNAR USUARIOS."

    ui_info "Levantando nodos y aplicando reglas..."
    _wgh_routing_enable

    ui_blank
    if _wgh_routing_is_active; then
        ui_ok "Salida residencial ENCENDIDA (${nu} usuario(s) enrutado(s))."
        ui_ok "Vigilante activo: si un nodo cae, sus usuarios pasan a su respaldo o a la IP del VPS."
        ui_ok "Se restaurará sola si el VPS se reinicia."
        ui_ok "El SSH de administración sigue saliendo por la IP del VPS."
    else
        ui_err "Las reglas no se pudieron validar en el kernel. Revisa el DIAGNÓSTICO."
    fi
    ui_pause
}

wghome_routing_off() {
    clear
    print_title 2>/dev/null || true
    ui_section "APAGAR SALIDA RESIDENCIAL"
    ui_blank
    ui_warn "Todos los usuarios pasarán a salir por la IP del VPS."
    ui_blank
    ui_confirm "¿Apagar la salida residencial?" "n" || return
    _wgh_persist_off
    _wgh_routing_off_internal >/dev/null
    ui_ok "Apagada. Los nodos siguen conectados y las asignaciones se conservan."
    ui_pause
}

# =========================================================
# QUE NADIE SE QUEDE SIN INTERNET — vigilante y respaldos
# =========================================================
wghome_configure_fallback() {
    while true; do
        clear
        print_title 2>/dev/null || true
        ui_section "QUE NADIE SE QUEDE SIN INTERNET" "conmutación automática"
        ui_blank

        local tag
        _wgh_watchdog_is_on && tag="$(ui_tag_str on)" || tag="$(ui_tag_str off)"
        echo -e "${UI_PAD}$(ui_cell "Vigilante" "" 22)${tag}"
        ui_blank
        echo -e "${UI_PAD}${DM}Si un nodo deja de responder, sus usuarios pasan solos a:${CR}"
        echo -e "${UI_PAD}  ${WH}nodo preferido${CR} ${DM}->${CR} ${WH}nodo de respaldo${CR} ${DM}->${CR} ${GR}IP del VPS${CR}"
        echo -e "${UI_PAD}${DM}y vuelven cuando el nodo se recupera. Un nodo PC se da por${CR}"
        echo -e "${UI_PAD}${DM}caído en 20-60 s; un móvil en unos 30 s.${CR}"
        ui_rule

        local -a nombres=()
        local name key idx tipo bk i=0
        printf "${UI_PAD}${DM}     %-14s %-7s %-14s %s${CR}\n" "NODO" "TIPO" "RESPALDO" "ESTADO"
        while IFS='|' read -r name key idx tipo bk _; do
            [ -z "$idx" ] && continue
            i=$((i+1)); nombres+=("$name")
            [ "${tipo:-wg}" = "socks" ] && tipo="movil" || tipo="PC"
            printf "${UI_PAD}${CY}[%d]${CR}  ${WH}%-14s${CR} ${DM}%-7s${CR} ${CY}%-14s${CR} %b\n" \
                "$i" "$name" "$tipo" "${bk:-IP del VPS}" "$(_wgh_node_status "$name")"
        done < <(_wgh_nodes_list)
        [ "$i" -eq 0 ] && echo -e "${UI_PAD}${DM}No hay nodos registrados.${CR}"

        ui_blank
        ui_solid
        if _wgh_watchdog_is_on; then ui_opt "1" "DESACTIVAR VIGILANTE" "no recomendado"
        else ui_opt "1" "ACTIVAR VIGILANTE" "conmutar solo"; fi
        ui_opt "2" "FIJAR RESPALDO" "de un nodo"
        ui_opt "0" "VOLVER"
        ui_solid
        ui_prompt "Elige una opción [0-2]"

        case "$REPLY_UI" in
            1)  if _wgh_watchdog_is_on; then
                    ui_warn "Sin vigilante, si un nodo cae sus usuarios se quedan sin Internet."
                    if ui_confirm "¿Desactivarlo igualmente?" "n"; then
                        _wgh_watchdog_disable; ui_ok "Vigilante apagado y rutas restauradas."
                    fi
                else
                    _wgh_watchdog_enable
                    _wgh_watchdog_is_on && ui_ok "Vigilante activo." || ui_err "No se pudo activar."
                fi; sleep 2 ;;
            2)  [ "$i" -eq 0 ] && { ui_err "No hay nodos."; sleep 1; continue; }
                ui_prompt "Número del nodo a configurar"
                local p1="$REPLY_UI" n1
                [[ "$p1" =~ ^[0-9]+$ ]] && [ "$p1" -ge 1 ] && [ "$p1" -le "$i" ] || { ui_err "Fuera de rango."; sleep 1; continue; }
                n1="${nombres[$((p1-1))]}"
                ui_blank
                echo -e "${UI_PAD}${DM}Respaldo de ${WH}${n1}${DM}: número de otro nodo, o 0 para que caiga${CR}"
                echo -e "${UI_PAD}${DM}directo a la IP del VPS.${CR}"
                ui_prompt "Respaldo"
                local p2="$REPLY_UI" n2=""
                if [ "$p2" != "0" ] && [ -n "$p2" ]; then
                    [[ "$p2" =~ ^[0-9]+$ ]] && [ "$p2" -ge 1 ] && [ "$p2" -le "$i" ] || { ui_err "Fuera de rango."; sleep 1; continue; }
                    n2="${nombres[$((p2-1))]}"
                    [ "$n2" = "$n1" ] && { ui_err "Un nodo no puede ser su propio respaldo."; sleep 2; continue; }
                fi
                _wgh_node_set_backup "$n1" "$n2"
                if [ -n "$n2" ]; then ui_ok "Si '${n1}' cae, sus usuarios pasan a '${n2}'."
                else ui_ok "Si '${n1}' cae, sus usuarios pasan a la IP del VPS."; fi
                [ -f "$WGH_ROUTING_FLAG" ] && _wgh_apply_user_routing >/dev/null 2>&1
                sleep 2 ;;
            0|"") break ;;
            *)  ui_err "Opción no válida."; sleep 1 ;;
        esac
    done
}

# =========================================================
# DIAGNOSTICO — la cadena completa, eslabón a eslabón
# ---------------------------------------------------------
# Antes habia cuatro pantallas (diagnostico, ping, IP de salida
# y "por que no hay Internet") que se solapaban, y la ultima
# trataba a los nodos movil como WireGuard y los daba siempre
# por apagados. Ahora es una sola y entiende los dos tipos.
#
# La clave son los CONTADORES de las reglas: una regla por la
# que no ha pasado ni un paquete dice que el trafico no llega
# hasta ella, y eso señala el eslabón roto sin adivinar.
# =========================================================
_wgh_rule_pkts() {
    # Paquetes que han cruzado una regla, buscada por patron.
    local tabla="$1" cadena="$2" patron="$3"
    iptables -t "$tabla" -L "$cadena" -v -n -x 2>/dev/null \
        | grep -- "$patron" | awk '{s+=$1} END{print s+0}'
}

wghome_diagnose() {
    clear
    print_title 2>/dev/null || true
    ui_section "DIAGNÓSTICO DEL GATEWAY" "la cadena completa, eslabón a eslabón"
    ui_blank

    local problemas=0
    _p() { problemas=$((problemas+1)); echo -e "${UI_PAD}  ${RD}✗ $1${CR}"; [ -n "${2:-}" ] && echo -e "${UI_PAD}    ${DM}$2${CR}"; }
    _v() { echo -e "${UI_PAD}  ${GR}✓ $1${CR}"; }
    _i() { echo -e "${UI_PAD}    ${DM}$1${CR}"; }

    # --- 1. Nodos ---
    echo -e "${UI_PAD}${YL}1 · Nodos${CR}"
    local total name key idx type hs user sport vivos=0
    total=$(_wgh_nodes_count)
    if [ "${total:-0}" -eq 0 ]; then
        _p "No hay ningún nodo registrado." "IP RESIDENCIAL > NODOS"
        ui_solid; ui_pause; return
    fi
    while IFS='|' read -r name key idx type _; do
        [ -z "$idx" ] && continue
        if [ "${type:-wg}" = "socks" ]; then
            user=$(_wgn_socksuser "$idx"); sport=$(_wgn_socksport "$idx")
            if [ ! -s "/var/lib/vpsservice/${user}/.ssh/authorized_keys" ]; then
                _p "'${name}' (móvil): sin llave autorizada." "NODOS > REGISTRAR NODO MÓVIL con el mismo nombre y pega su clave."
            elif ! _socks_reverse_up "$idx"; then
                _p "'${name}' (móvil): no está conectado (nadie escucha en ${sport})." "En el celular: abre el nodo y conecta."
            elif ! _socks_redsocks_up "$idx"; then
                _p "'${name}' (móvil): redsocks caído." "$(journalctl -u "$(_socks_redunit "$idx")" -n 1 --no-pager 2>/dev/null | tail -1)"
            else
                _v "'${name}' (móvil): conectado."; vivos=$((vivos+1))
            fi
        else
            if ! _wgh_node_is_up "$idx"; then
                _p "'${name}' (PC): su interfaz $(_wgn_iface "$idx") está apagada." "Se levanta sola al encender la salida residencial."
            else
                hs=$(_wgh_node_hs "$idx")
                if [ "$hs" -lt 0 ] 2>/dev/null && grep -qx "$name" "$WGH_RECONFIG" 2>/dev/null; then
                    _p "'${name}' (PC): con la actualización cambió de IP y puerto." \
                       "Reconfigúralo con NODOS > DATOS PARA EL NODO: IP $(_wgn_nodeip "$idx"), puerto $(_wgn_port "$idx")."
                elif [ "$hs" -lt 0 ] 2>/dev/null; then
                    _p "'${name}' (PC): nunca ha conectado." "El equipo no está llamando al VPS. Revisa allí clave, Endpoint y puerto $(_wgn_port "$idx")."
                elif [ "$hs" -ge 180 ]; then
                    _p "'${name}' (PC): último contacto hace ${hs}s." "Comprueba que el equipo esté encendido y con PersistentKeepalive = 25."
                else
                    _v "'${name}' (PC): conectado (handshake hace ${hs}s)."; vivos=$((vivos+1))
                    # Ya conecta con sus datos nuevos: fuera del aviso.
                    [ -f "$WGH_RECONFIG" ] && sed -i "/^${name}$/d" "$WGH_RECONFIG"
                    # Tunel vivo no es lo mismo que Internet: se prueba el
                    # camino completo, el mismo que usa el vigilante.
                    if ping -c1 -W3 -I "$(_wgn_iface "$idx")" 1.1.1.1 &>/dev/null || \
                       ping -c1 -W3 -I "$(_wgn_iface "$idx")" 8.8.8.8 &>/dev/null; then
                        _v "  y da Internet: un ping a 1.1.1.1 sale por el nodo y vuelve."
                    else
                        _p "  el túnel está vivo pero el nodo NO da Internet." \
                           "En el PC: ¿tiene Internet? ¿está activo su NAT (nodo [2])? El vigilante manda a sus usuarios a su respaldo o a la IP del VPS."
                    fi
                fi
            fi
        fi
        if [ -f "$WGH_ROUTING_FLAG" ] && [ "$(_wgh_health_of "$name")" = "down" ]; then
            _i "el vigilante lo tiene por CAÍDO: sus usuarios salen por $(_wgh_node_backup_of "$name" | sed 's/^$/la IP del VPS/')"
        fi
    done < <(_wgh_nodes_list)
    [ "$vivos" -eq 0 ] && _p "Ningún nodo está conectado: los usuarios asignados salen por la IP del VPS."
    ui_blank

    # --- 2. Kernel ---
    echo -e "${UI_PAD}${YL}2 · Kernel${CR}"
    local fwd rpf
    fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
    [ "$fwd" = "1" ] && _v "ip_forward activo." || _p "ip_forward apagado." "Se corrige al encender la salida residencial."
    rpf=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null)
    if [ "$rpf" = "1" ]; then
        _p "rp_filter = 1 (estricto)." "Descarta las respuestas que vuelven por el túnel. Se corrige al encender la salida."
    else
        _v "rp_filter = ${rpf:-?} (no descarta el retorno)."
    fi
    local def_main
    def_main=$(ip route show table main 2>/dev/null | grep '^default' | head -1)
    if echo "$def_main" | grep -q "wg-home"; then
        _p "La ruta por defecto del VPS usa wg-home: el SSH está en riesgo." "$def_main"
    else
        _v "Ruta por defecto intacta: el SSH sale por la IP del VPS."
    fi
    ui_blank

    # --- 3. Usuarios ---
    echo -e "${UI_PAD}${YL}3 · Usuarios${CR}"
    local u uid asign=0
    while IFS= read -r u; do
        [ -z "$u" ] && continue
        name=$(_wgh_user_node "$u"); uid=$(id -u "$u" 2>/dev/null)
        [ -z "$name" ] && continue
        if [ -z "$uid" ] || [ "$uid" -lt 1000 ] 2>/dev/null; then
            _p "${u} está asignado a '${name}' pero su UID es ${uid:-?}." "Solo se enruta UID >= 1000."
        else
            _v "${u} -> ${name}"; asign=$((asign+1))
        fi
    done < <(_wgh_get_client_users | cut -d: -f1)
    [ "$asign" -eq 0 ] && _i "Nadie asignado a un nodo: todos salen por la IP del VPS."
    _i "Por el nodo pasa el TCP de las sesiones OpenSSH (directas, SSL y WebSocket)."
    _i "El UDP (BadVPN, llamadas, juegos) sale siempre por la IP del VPS."
    [ -n "${PORT_DROPBEAR:-}" ] && _i "Dropbear abre las conexiones como root: sus clientes pueden salir por el VPS."
    ui_blank

    # --- 4. Reglas ---
    echo -e "${UI_PAD}${YL}4 · Reglas aplicadas${CR}"
    if ! _wgh_routing_is_active; then
        _p "La salida residencial está APAGADA." "Enciéndela con la opción 3 del menú del gateway."
    else
        _v "Salida residencial encendida."
        local marcados
        marcados=$(_wgh_rule_pkts mangle OUTPUT HOMEVPN_MARK)
        if [ "$asign" -gt 0 ] && [ "${marcados:-0}" -eq 0 ]; then
            _p "Ni un paquete marcado todavía." "O el cliente no está navegando, o su tráfico no sale con su UID."
        elif [ "$asign" -gt 0 ]; then
            _v "${marcados} paquetes marcados: el tráfico de los clientes SÍ se desvía."
        fi
        local mark tbl ifc ruta natp redport
        while IFS='|' read -r name key idx type _; do
            [ -z "$idx" ] && continue
            mark=$(_wgn_mark "$idx")
            echo -e "${UI_PAD}  ${WH}${name}${CR} ${DM}(marca ${mark})${CR}"
            if [ "${type:-wg}" = "socks" ]; then
                redport=$(_wgn_redport "$idx")
                if _socks_redirect_present "$idx"; then
                    _v "  desvío TCP -> redsocks :${redport} ($(_wgh_rule_pkts nat OUTPUT "redir ports ${redport}") paquetes)"
                elif [ "$(_wgh_health_of "$name")" = "down" ]; then
                    _i "  desvío retirado por el vigilante (nodo caído)"
                else
                    _p "  falta el desvío hacia redsocks"
                fi
            else
                tbl=$(_wgn_table "$idx"); ifc=$(_wgn_iface "$idx")
                ip rule show | grep -q "fwmark ${mark} lookup" \
                    && _v "  regla fwmark -> tabla ${tbl}" \
                    || _p "  falta la regla fwmark ${mark} -> tabla ${tbl}"
                ruta=$(ip route show table "$tbl" 2>/dev/null | grep '^default')
                if [ -n "$ruta" ]; then _v "  ${ruta}"
                elif [ "$(_wgh_health_of "$name")" = "down" ]; then _i "  ruta retirada por el vigilante (nodo caído)"
                else _p "  la tabla ${tbl} no tiene ruta por defecto"; fi
                natp=$(_wgh_rule_pkts nat POSTROUTING "$ifc")
                [ "${natp:-0}" -gt 0 ] && _v "  NAT: ${natp} paquetes traducidos hacia el nodo" \
                                       || _i "  NAT: aún sin tráfico hacia este nodo"
            fi
        done < <(_wgh_nodes_list)
    fi
    ui_blank

    # --- 5. Protección contra caídas ---
    echo -e "${UI_PAD}${YL}5 · Protección contra caídas${CR}"
    _wgh_watchdog_is_on && systemctl is-active --quiet homevpn-watchdog 2>/dev/null \
        && _v "Vigilante activo y funcionando." \
        || _p "Vigilante apagado o detenido." "Sin él, si un nodo cae sus usuarios se quedan sin Internet. Opción 4."
    if _wgh_routing_is_active; then
        [ -f "$WGH_ROUTING_FLAG" ] && systemctl is-enabled --quiet homevpn-rules 2>/dev/null \
            && _v "Se restaurará sola si el VPS se reinicia." \
            || _p "No se restaurará tras un reinicio." "Apaga y enciende la salida residencial para registrarla."
    fi
    ui_blank

    # --- 6. Salida real ---
    echo -e "${UI_PAD}${YL}6 · Salida real a Internet${CR}"
    local ip_normal probe res
    ip_normal=$(_wgh_get_droplet_ip)
    _i "IP del VPS: ${ip_normal:-desconocida}"
    while IFS='|' read -r name key idx type _; do
        [ -z "$idx" ] && continue
        probe=$(_wgh_node_users "$name" | head -1)
        if [ -n "$probe" ] && _wgh_routing_is_active; then
            _i "Saliendo como '${probe}' por '${name}'..."
            res=$(runuser -u "$probe" -- curl -4 -s --max-time 15 https://api.ipify.org 2>/dev/null)
            if [ -z "$res" ]; then
                _p "  ${name}: sin respuesta." "El tráfico sale del VPS pero no vuelve: revisa en el nodo el reenvío y el NAT."
            elif [ "$res" = "$ip_normal" ]; then
                [ "$(_wgh_health_of "$name")" = "down" ] \
                    && _i "  ${name}: sale por la IP del VPS (el nodo está caído: es lo esperado)" \
                    || _p "  ${name}: ${res} es la IP del VPS, no la del nodo." "El desvío no se aplica a ese usuario."
            else
                _v "  ${name}: sale por ${res}"
            fi
            # La prueba que faltaba: con 'curl -4' todo parecia correcto
            # mientras el trafico IPv6 salia por el VPS.
            if _wgh_has_ipv6; then
                local res6
                res6=$(runuser -u "$probe" -- curl -6 -s --max-time 8 https://api64.ipify.org 2>/dev/null)
                if [ -n "$res6" ]; then
                    _p "  ${name}: por IPv6 sale con ${res6}, la del VPS." "Falta el bloqueo IPv6: apaga y enciende la salida residencial."
                else
                    _v "  ${name}: IPv6 bloqueado para sus usuarios (sin fuga)"
                fi
            fi
        elif [ "${type:-wg}" = "socks" ] && _socks_reverse_up "$idx"; then
            _i "Probando el SOCKS de '${name}'..."
            res=$(_socks_probe_ip "$idx")
            [ -n "$res" ] && _v "  ${name}: el móvil da salida por ${res}" \
                          || _p "  ${name}: el móvil está conectado pero no navega." "Revisa que el teléfono tenga datos."
        fi
    done < <(_wgh_nodes_list)

    ui_blank; ui_rule
    if [ "$problemas" -eq 0 ]; then
        echo -e "${UI_PAD}${GR}Todo correcto: el gateway está dando Internet.${CR}"
    else
        echo -e "${UI_PAD}${RD}${problemas} problema(s). Arregla primero el de más arriba:${CR}"
        echo -e "${UI_PAD}${DM}los de abajo suelen ser consecuencia suya.${CR}"
    fi
    ui_solid
    ui_pause
}

# =========================================================
# AVANZADO — lo que se toca una vez o nunca
# =========================================================
wghome_advanced_menu() {
    while true; do
        clear
        print_title 2>/dev/null || true
        ui_section "GATEWAY · AVANZADO"
        ui_blank
        local TAG_TUNNEL
        _wgh_is_up && TAG_TUNNEL="$(ui_tag_str on)" || TAG_TUNNEL="$(ui_tag_str off)"
        ui_opt "1" "INSTALAR / RECONFIG"  "asistente"
        ui_opt "2" "TÚNEL WG-HOME"        "encender/apagar" "$TAG_TUNNEL"
        ui_opt "3" "DIRECCIÓN PÚBLICA"    "endpoint del VPS"
        ui_opt "4" "CLAVE PÚBLICA DEL VPS" "y datos de nodos"
        ui_blank
        ui_opt_danger "5" "ELIMINAR CONFIGURACIÓN" "borra el gateway"
        ui_opt "0" "VOLVER"
        ui_solid
        ui_prompt "Elige una opción [0-5]"
        case "$REPLY_UI" in
            1) wghome_install ;;
            2) if _wgh_is_up; then wghome_tunnel_down; else wghome_tunnel_up; fi ;;
            3) wghome_fix_endpoint ;;
            4) wghome_show_pubkey ;;
            5) wghome_remove ;;
            0|"") break ;;
            *) ui_err "Opción no válida."; sleep 1 ;;
        esac
    done
}

# =========================================================
# MENU DEL GATEWAY RESIDENCIAL
# ---------------------------------------------------------
# Antes: 13 opciones, numeradas 1..11, 13, 12; cuatro de
# diagnostico y dos pantallas distintas para asignar usuarios
# (una de ellas, al pulsar "todos", borraba las asignaciones
# por nodo). Ahora: lo de uso diario arriba y lo de una sola
# vez en AVANZADO.
# =========================================================
wghome_menu() {
    _wgh_repair_conf_if_needed

    while true; do
        clear
        print_title 2>/dev/null || true
        ui_section "IP RESIDENCIAL" "cada usuario sale por el nodo que le asignes"
        ui_blank

        local TAG_ROUTING TAG_FB n_count n_ok n_down u_count name
        _wgh_routing_is_active && TAG_ROUTING="$(ui_tag_str on)" || TAG_ROUTING="$(ui_tag_str off)"
        _wgh_watchdog_is_on    && TAG_FB="$(ui_tag_str on)"      || TAG_FB="$(ui_tag_str off)"
        n_count=$(_wgh_nodes_count 2>/dev/null || echo 0)
        n_ok=0; n_down=0
        local st
        while IFS= read -r name; do
            [ -z "$name" ] && continue
            st=$(_wgh_node_status "$name")
            if [[ "$st" == *conectado* && "$st" != *desconectado* ]]; then n_ok=$((n_ok+1)); else n_down=$((n_down+1)); fi
        done < <(_wgh_nodes_names)
        u_count=$(_wgh_routed_users | wc -l)

        echo -e "${UI_PAD}$(ui_cell "Nodos" "${n_count:-0}" 14 "$CY")${DM}▸${CR} $(ui_cell "Conectados" "$n_ok" 17 "$GR")${DM}▸${CR} $(ui_cell "Caídos" "$n_down" 14 "$RD")"
        echo -e "${UI_PAD}$(ui_cell "Usuarios que salen por un nodo" "$u_count" 40 "$CY")"
        if _wgh_routing_is_active && ! _wgh_watchdog_is_on; then
            ui_warn "Vigilante apagado: si un nodo cae, sus usuarios se quedan sin Internet."
        fi
        ui_rule
        ui_blank

        ui_opt "1" "NODOS"              "registrar · datos"
        ui_opt "2" "ASIGNAR USUARIOS"   "quién sale por dónde"
        ui_opt "3" "SALIDA RESIDENCIAL" "encender/apagar" "$TAG_ROUTING"
        ui_opt "4" "NUNCA SIN INTERNET" "respaldos"       "$TAG_FB"
        ui_opt "5" "DIAGNÓSTICO"        "cadena completa"
        ui_blank
        ui_opt "6" "MÓVIL SIN ROOT"     "beta · su IP"
        ui_opt "9" "AVANZADO"           "túnel · endpoint"
        ui_opt "0" "VOLVER"
        ui_solid
        ui_prompt "Elige una opción [0-6 | 9]"

        case "$REPLY_UI" in
            1) wghome_manage_nodes ;;
            2) wghome_assign_users ;;
            3) if _wgh_routing_is_active; then wghome_routing_off; else wghome_routing_on; fi ;;
            4) wghome_configure_fallback ;;
            5) wghome_diagnose ;;
            6) mobile_beta_menu ;;
            9) wghome_advanced_menu ;;
            0|"") break ;;
            *) ui_err "Opción no válida."; sleep 1 ;;
        esac
    done
}

# =========================================================
# EJECUCION DIRECTA (servicios de systemd y guardian)
#   wg_home.sh --watchdog        el vigilante (homevpn-watchdog)
#   wg_home.sh --restore         rehace la salida tras un reinicio
#   wg_home.sh --check-restore   la rehace solo si falta algo
# Antes el servicio llamaba a '--watchdog' pero el script no
# leia ese argumento: cargaba sus funciones y terminaba, systemd
# lo relanzaba cada 5 s, y el vigilante no vigilaba nada.
# =========================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        --watchdog)      wghome_watchdog_loop ;;
        --restore)       wghome_restore ;;
        --check-restore) wghome_check_restore ;;
        *)               echo "Uso: $0 --watchdog | --restore | --check-restore" >&2; exit 2 ;;
    esac
fi
