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
_wgh_get_droplet_ip() {
    local ip
    ip=$(curl -4 -s --max-time 5 https://api.ipify.org 2>/dev/null || curl -4 -s --max-time 5 https://ifconfig.me 2>/dev/null || true)
    if [ -z "$ip" ]; then
        ip=$(ip route show table main | grep '^default' | awk '{print $5}' | head -1 | xargs -I {} ip -4 addr show dev {} 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)
    fi
    [ -z "$ip" ] && ip="167.99.4.37"
    echo "$ip"
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

# Verificar si el túnel está activo a nivel de interfaz de red
_wgh_is_up() {
    ip link show "${WGH_IFACE}" &>/dev/null 2>&1
}

# Verificar si la salida residencial está activa en policy routing
_wgh_routing_is_active() {
    ip rule show | grep -qE "lookup (${WGH_RT_NAME}|${WGH_RT_TABLE})"
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

    if [ -n "$peer_pub" ]; then
        cat <<EOF
[Peer]
# PC doméstico en Colombia (CachyOS / Linux)
PublicKey           = ${peer_pub}
AllowedIPs          = 0.0.0.0/0
PersistentKeepalive = 0
EOF
    else
        cat <<EOF
# [Peer] — Pendiente registrar clave pública del PC doméstico.
# Usa la opción 3 del menú para registrarla.
EOF
    fi
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

    local droplet_pub_ip
    droplet_pub_ip=$(_wgh_get_droplet_ip)

    # 1. Asegurar ruta por defecto en tabla 200 apuntando al PC doméstico
    ip route replace default via "${WGH_PEER_IP}" dev "${WGH_IFACE}" table "${WGH_RT_TABLE}" 2>/dev/null
    _wgh_log "Ruta default instalada en tabla ${WGH_RT_TABLE} via ${WGH_PEER_IP} dev ${WGH_IFACE}"

    # 2. Regla base para pruebas locales desde la interfaz wg-home (10.77.77.1)
    if ! ip rule show | grep -q "from ${WGH_DROPLET_IP} lookup ${WGH_RT_NAME}"; then
        ip rule add from "${WGH_DROPLET_IP}" table "${WGH_RT_TABLE}" priority 1000 2>/dev/null || true
    fi

    # 3. Regla para paquetes marcados con 0x77
    if ! ip rule show | grep -q "fwmark ${WGH_FWMARK} lookup ${WGH_RT_NAME}"; then
        ip rule add fwmark "${WGH_FWMARK}" table "${WGH_RT_TABLE}" priority 1002 2>/dev/null || true
    fi

    # 4. EXCLUSIONES DE SEGURIDAD EN IPTABLES MANGLE OUTPUT (Prevención de bucles y protección SSH)
    # Evita que el propio túnel WireGuard, SSH, loopback o subred VPN sean marcados
    local -a excludes=(
        "-d 127.0.0.0/8"
        "-d ${WGH_SUBNET}"
        "-d ${droplet_pub_ip}"
        "-p udp --dport ${WGH_PORT}"
        "-p udp --sport ${WGH_PORT}"
        "-p tcp --sport 22"
    )
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

    # 5. Marcar tráfico por UID de cada usuario HTTP Injector configurado
    local -a users=()
    if [ -f "$WGH_USERS_CONF" ]; then
        while IFS= read -r cu; do
            [ -n "$cu" ] && users+=("$cu")
        done < <(_wgh_get_configured_users)
    fi

    local u uid
    for u in "${users[@]}"; do
        uid=$(id -u "$u" 2>/dev/null || true)
        if [ -n "$uid" ] && [ "$uid" -ge 1000 ]; then
            iptables -t mangle -C OUTPUT -m owner --uid-owner "$uid" -m comment --comment "HOMEVPN_HTTP_INJECTOR" -j MARK --set-mark "${WGH_FWMARK}" 2>/dev/null || \
                iptables -t mangle -A OUTPUT -m owner --uid-owner "$uid" -m comment --comment "HOMEVPN_HTTP_INJECTOR" -j MARK --set-mark "${WGH_FWMARK}" 2>/dev/null || true
            _wgh_log "Marcado fwmark ${WGH_FWMARK} aplicado para usuario $u (UID $uid)"
        fi
    done

    # 6. NAT y Reenvío en iptables para interfaz wg-home
    iptables -t nat -C POSTROUTING -o "${WGH_IFACE}" -m comment --comment "HOMEVPN_NAT" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o "${WGH_IFACE}" -m comment --comment "HOMEVPN_NAT" -j MASQUERADE 2>/dev/null || true
    iptables -C FORWARD -o "${WGH_IFACE}" -m comment --comment "HOMEVPN_FORWARD" -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -o "${WGH_IFACE}" -m comment --comment "HOMEVPN_FORWARD" -j ACCEPT 2>/dev/null || true
    iptables -C FORWARD -i "${WGH_IFACE}" -m state --state RELATED,ESTABLISHED -m comment --comment "HOMEVPN_FORWARD" -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i "${WGH_IFACE}" -m state --state RELATED,ESTABLISHED -m comment --comment "HOMEVPN_FORWARD" -j ACCEPT 2>/dev/null || true

    # 7. Registrar en log
    _wgh_log "Enrutamiento residencial activado exitosamente para ${#users[@]} usuario(s)"
}

# Elimina ÚNICAMENTE las reglas creadas por este módulo (CAMBIO 7)
_wgh_routing_off_internal() {
    _wgh_log "Iniciando desactivación de salida residencial..."

    # Guardar snapshot antes de limpiar
    _wgh_backup &>/dev/null

    # 1. Eliminar reglas ip rule asociadas a tabla 200 / homevpn
    while ip rule show | grep -qE "lookup (${WGH_RT_NAME}|${WGH_RT_TABLE})"; do
        ip rule del table "${WGH_RT_TABLE}" 2>/dev/null || break
    done

    # 2. Vaciar tabla de rutas 200
    ip route flush table "${WGH_RT_TABLE}" 2>/dev/null || true

    # 3. Eliminar marcas y exclusiones creadas por HOMEVPN en iptables mangle
    while iptables -t mangle -D OUTPUT -m comment --comment "HOMEVPN_HTTP_INJECTOR" -j MARK --set-mark "${WGH_FWMARK}" 2>/dev/null; do :; done
    while iptables -t mangle -D OUTPUT -m comment --comment "HOMEVPN_EXCLUDE" -j RETURN 2>/dev/null; do :; done

    # 4. Eliminar NAT y reenvío creados por HOMEVPN en iptables nat/filter
    while iptables -t nat -D POSTROUTING -o "${WGH_IFACE}" -m comment --comment "HOMEVPN_NAT" -j MASQUERADE 2>/dev/null; do :; done
    while iptables -D FORWARD -o "${WGH_IFACE}" -m comment --comment "HOMEVPN_FORWARD" -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -i "${WGH_IFACE}" -m state --state RELATED,ESTABLISHED -m comment --comment "HOMEVPN_FORWARD" -j ACCEPT 2>/dev/null; do :; done

    # 5. Asegurar que tabla main y ruta SSH permanezcan 100% intactas
    _wgh_verify_ssh_route
    _wgh_log "Desactivación completada. Reglas del módulo eliminadas."
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

    # Paso 4: Generar claves Droplet
    echo -e "  ${YL}[*]${CR} Generando par de claves para la Droplet..."
    mkdir -p /etc/wireguard
    (umask 077; wg genkey > "${WGH_PRIV_KEY}")
    wg pubkey < "${WGH_PRIV_KEY}" > "${WGH_PUB_KEY}"
    chmod 600 "${WGH_PRIV_KEY}"
    chmod 644 "${WGH_PUB_KEY}"
    echo -e "  ${GR}[+]${CR} Claves generadas (clave privada protegida chmod 600)."

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

    # Inicializar fallback por defecto en ON si no existe
    [ ! -f "$WGH_FALLBACK_CONF" ] && _wgh_set_fallback "ON"

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
    echo -e "${WH}     CLAVE PÚBLICA DE LA DROPLET${CR}"
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
    echo -e "  ${DM}IP pública Droplet :${CR} ${GR}${ip_pub}${CR}"
    echo -e "  ${DM}Puerto WireGuard   :${CR} ${CY}${WGH_PORT}/UDP${CR}"
    echo ""
    echo -e "  ${YL}[ Clave Pública Droplet ]${CR}"
    echo -e "  ${WH}${pub}${CR}"
    echo ""
    echo -e "  ${DM}━━━ Configuración para el PC doméstico (CachyOS) ━━━${CR}"
    echo -e "  ${DM}Guarda esto en /etc/wireguard/wg-home.conf en tu PC:${CR}"
    echo ""
    echo -e "  ${CY}[Interface]${CR}"
    echo -e "  ${WH}PrivateKey          = <CLAVE_PRIVADA_DE_TU_PC>${CR}"
    echo -e "  ${WH}Address             = ${WGH_PEER_IP}/24${CR}"
    echo -e "  ${DM}# Comandos para compartir tu salida residencial wlan0 en Linux:${CR}"
    echo -e "  ${DM}PostUp = iptables -A FORWARD -i ${WGH_IFACE} -j ACCEPT; iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE${CR}"
    echo -e "  ${DM}PostDown = iptables -D FORWARD -i ${WGH_IFACE} -j ACCEPT; iptables -t nat -D POSTROUTING -o wlan0 -j MASQUERADE${CR}"
    echo ""
    echo -e "  ${CY}[Peer]${CR}"
    echo -e "  ${WH}PublicKey           = ${pub}${CR}"
    echo -e "  ${WH}Endpoint            = ${ip_pub}:${WGH_PORT}${CR}"
    echo -e "  ${WH}AllowedIPs          = ${WGH_DROPLET_IP}/32${CR}"
    echo -e "  ${WH}PersistentKeepalive = 25${CR}"
    echo ""
    echo -e "  ${YL}[!] La clave privada de la Droplet NUNCA se comparte ni se expone.${CR}"
    echo -e "$SEP"
    read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
}

# =========================================================
# 3. REGISTRAR CLAVE PÚBLICA DEL PC DOMÉSTICO
# =========================================================
wghome_register_peer() {
    clear
    print_title 2>/dev/null || true
    echo -e "$SEP"
    echo -e "${WH}     REGISTRAR PC DOMÉSTICO (Peer)${CR}"
    echo -e "$SEP"

    if ! _wgh_is_installed; then
        echo -e "  ${RD}[-]${CR} El gateway no está instalado. Usa la opción 1 primero."
        sleep 2; return
    fi

    echo ""
    echo -e "  ${DM}Introduce la clave pública del PC doméstico (CachyOS).${CR}"
    echo -e "  ${DM}(Generada en el PC con: wg pubkey < privatekey)${CR}"
    echo ""
    read -p "$(echo -e ${CY})PublicKey del PC: $(echo -e ${CR})" peer_pub

    if [ -z "$peer_pub" ]; then
        echo -e "  ${RD}[-]${CR} Clave vacía. Cancelado."; sleep 1; return
    fi

    if ! echo "$peer_pub" | grep -qE '^[A-Za-z0-9+/]{43}=$'; then
        echo -e "  ${YL}[!]${CR} Formato no estándar (WireGuard base64 son 44 chars)."
        read -p "$(echo -e ${DM})¿Continuar de todas formas? (s/n): $(echo -e ${CR})" resp
        if [[ "$resp" != "s" && "$resp" != "S" ]]; then
            echo -e "  ${GR}[+]${CR} Operación cancelada."; sleep 1; return
        fi
    fi

    mkdir -p /etc/wireguard 2>/dev/null
    echo "${peer_pub}" > "${WGH_PEER_KEY}"
    chmod 644 "${WGH_PEER_KEY}"

    local priv
    priv=$(cat "${WGH_PRIV_KEY}")
    _wgh_render_conf "$priv" "$peer_pub" > "${WGH_CONF}"
    chmod 600 "${WGH_CONF}"

    _wgh_log "Peer registrado en Droplet con AllowedIPs = 0.0.0.0/0"
    echo -e "  ${GR}[+]${CR} Clave del PC registrada con AllowedIPs = 0.0.0.0/0."

    if _wgh_is_up; then
        echo -e "  ${YL}[*]${CR} Sincronizando WireGuard en caliente..."
        wg syncconf "${WGH_IFACE}" <(wg-quick strip "${WGH_IFACE}" 2>/dev/null) 2>/dev/null && \
            echo -e "  ${GR}[+]${CR} Túnel actualizado sin cortes." || \
            systemctl restart "wg-quick@${WGH_IFACE}" 2>/dev/null
    fi

    echo ""
    read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
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

    echo -e "  ${YL}[*]${CR} Haciendo ping a ${WGH_PEER_IP} (PC doméstico en Colombia)..."
    echo ""
    if ping -c 4 -W 2 "${WGH_PEER_IP}" 2>/dev/null; then
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

    # VALIDACIÓN 2: Túnel UP
    if ! _wgh_is_up; then
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

    # VALIDACIÓN 5: Handshake WireGuard
    if ! _wgh_has_handshake; then
        echo -e "  ${YL}[!] ADVERTENCIA: No se detecta handshake reciente en WireGuard.${CR}"
        echo -e "  ${YL}[!] El PC doméstico puede no haber iniciado sesión aún.${CR}"
        echo ""
        read -p "$(echo -e ${DM})¿Continuar de todas formas? (s/n) [s]: $(echo -e ${CR})" resp
        resp=${resp:-s}
        if [[ "$resp" != "s" && "$resp" != "S" ]]; then
            echo -e "  ${GR}[+]${CR} Operación cancelada."; sleep 1; return
        fi
    fi

    # VALIDACIÓN 6: Conectividad ICMP a 10.77.77.2
    echo -e "  ${YL}[*]${CR} Verificando ping a ${WGH_PEER_IP}..."
    if ! ping -c 2 -W 2 "${WGH_PEER_IP}" &>/dev/null; then
        echo -e "  ${YL}[!] El PC doméstico no respondió al ping en 10.77.77.2.${CR}"
        read -p "$(echo -e ${DM})¿Continuar aplicando configuración? (s/n) [s]: $(echo -e ${CR})" resp_ping
        resp_ping=${resp_ping:-s}
        if [[ "$resp_ping" != "s" && "$resp_ping" != "S" ]]; then
            echo -e "  ${GR}[+]${CR} Operación cancelada."; sleep 1; return
        fi
    else
        echo -e "  ${GR}[+]${CR} Conectividad con 10.77.77.2 verificada [OK]."
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
        echo -e "  ${DM}• Salida hacia PC doméstico        : ${WH}${WGH_PEER_IP}${CR}"
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
    echo -e "$SEP"
    echo -e "${WH}     VERIFICAR IP DE SALIDA (NORMAL VS RESIDENCIAL)${CR}"
    echo -e "$SEP"
    echo ""

    _wgh_repair_conf_if_needed

    echo -e "  ${YL}[*]${CR} Consultando IP pública del Droplet (tabla main)..."
    local ip_normal country_normal
    ip_normal=$(_wgh_get_droplet_ip)
    country_normal=$(curl -4 -s --max-time 4 "http://ip-api.com/json/${ip_normal}?fields=country,city,isp" 2>/dev/null | grep -oE '"country":"[^"]*"' | cut -d: -f2 | tr -d '"' || echo "DigitalOcean")
    [ -z "$country_normal" ] && country_normal="DigitalOcean Cloud"

    echo -e "  ${DM}IP pública normal Droplet :${CR} ${GR}${ip_normal}${CR}"
    echo -e "  ${DM}País / Origen             :${CR} ${WH}${country_normal}${CR}"
    echo ""

    # Datos WireGuard
    local hs_sec hs_str rx_tx
    hs_sec=$(_wgh_handshake_seconds)
    if [ "$hs_sec" = "never" ]; then
        hs_str="${RD}Sin handshake registrado${CR}"
    else
        hs_str="${CY}${hs_sec}s atrás${CR}"
    fi

    rx_tx=$(wg show "${WGH_IFACE}" transfer 2>/dev/null | awk '{printf "RX: %s bytes | TX: %s bytes", $2, $3}' || echo "N/A")

    echo -e "  ${DM}Estado interfaz wg-home   :${CR} $(_wgh_is_up && echo -e "${GR}UP${CR}" || echo -e "${RD}DOWN${CR}")"
    echo -e "  ${DM}Estado Gateway Residencial:${CR} $(_wgh_routing_is_active && echo -e "${GR}ACTIVO${CR}" || echo -e "${RD}INACTIVO${CR}")"
    echo -e "  ${DM}Último handshake          :${CR} ${hs_str}"
    echo -e "  ${DM}Transferencia             :${CR} ${WH}${rx_tx}${CR}"
    echo ""

    if _wgh_is_up; then
        echo -e "  ${YL}[*]${CR} Consultando IP residencial vía gateway doméstico (10.77.77.2)..."

        # Asegurar regla temporal para prueba si la salida residencial no está activa globalmente
        local temp_rule=false
        if ! _wgh_routing_is_active; then
            ip route replace default via "${WGH_PEER_IP}" dev "${WGH_IFACE}" table "${WGH_RT_TABLE}" 2>/dev/null || true
            ip rule add from "${WGH_DROPLET_IP}" table "${WGH_RT_TABLE}" priority 1000 2>/dev/null || true
            temp_rule=true
        fi

        local ip_res country_res
        ip_res=$(curl -4 -s --max-time 7 --interface "${WGH_IFACE}" https://api.ipify.org 2>/dev/null || \
                 curl -4 -s --max-time 7 --interface "${WGH_IFACE}" https://ifconfig.me 2>/dev/null || \
                 curl -4 -s --max-time 7 --interface "${WGH_IFACE}" https://icanhazip.com 2>/dev/null || echo "N/A")
        ip_res=$(echo "$ip_res" | tr -d ' \r\n')

        if [ "$temp_rule" = true ]; then
            ip rule del from "${WGH_DROPLET_IP}" table "${WGH_RT_TABLE}" 2>/dev/null || true
            ip route flush table "${WGH_RT_TABLE}" 2>/dev/null || true
        fi

        if [ -n "$ip_res" ] && [ "$ip_res" != "N/A" ]; then
            country_res=$(curl -4 -s --max-time 4 "http://ip-api.com/json/${ip_res}?fields=country,city,isp" 2>/dev/null | grep -oE '"country":"[^"]*"' | cut -d: -f2 | tr -d '"' || echo "Colombia")
            [ -z "$country_res" ] && country_res="Colombia (Residencial)"

            echo -e "  ${DM}IP residencial (wg-home)  :${CR} ${CY}${ip_res}${CR}"
            echo -e "  ${DM}País / ISP Residencial    :${CR} ${WH}${country_res}${CR}"
            echo ""
            if [ "$ip_normal" != "$ip_res" ]; then
                echo -e "  ${GR}[✓] ¡GATEWAY RESIDENCIAL FUNCIONANDO CORRECTAMENTE!${CR}"
                echo -e "  ${DM}    Las IPs son diferentes. El tráfico sale por el PC doméstico.${CR}"
            else
                echo -e "  ${YL}[!] La IP detectada es igual a la de la Droplet.${CR}"
                echo -e "  ${DM}    Verifica NAT/MASQUERADE en wlan0 del PC doméstico.${CR}"
            fi
        else
            echo -e "  ${RD}[-] IP residencial : N/A (Sin respuesta desde 10.77.77.2)${CR}"
            echo -e "  ${DM}    Verifica:${CR}"
            echo -e "  ${DM}    1. Que el PC doméstico (CachyOS) tenga WireGuard activo.${CR}"
            echo -e "  ${DM}    2. Que tenga iptables MASQUERADE en su interfaz wlan0.${CR}"
            echo -e "  ${DM}    3. Prueba ping con la opción 7 del menú.${CR}"
        fi
    else
        echo -e "  ${YL}[!] El túnel wg-home está inactivo. Actívalo con la opción 4.${CR}"
    fi

    echo ""
    read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
}

# =========================================================
# CAMBIO 9: 11. DIAGNÓSTICO COMPLETO ([OK], [WARN], [ERROR])
# =========================================================
wghome_diagnose() {
    clear
    print_title 2>/dev/null || true
    echo -e "$SEP"
    echo -e "${WH}     DIAGNÓSTICO COMPLETO — Gateway Residencial${CR}"
    echo -e "$SEP"
    echo ""

    _wgh_repair_conf_if_needed

    # 1. WIREGUARD
    echo -e "  ${YL}[ 1/5 ] ESTADO WIREGUARD${CR}"
    local svc_status
    svc_status=$(systemctl is-active "wg-quick@${WGH_IFACE}" 2>/dev/null || echo "inactive")
    if [ "$svc_status" = "active" ]; then
        echo -e "    ${GR}[OK]${CR} Servicio wg-quick@${WGH_IFACE}: ACTIVO"
    else
        echo -e "    ${RD}[ERROR]${CR} Servicio wg-quick@${WGH_IFACE}: INACTIVO"
    fi
    if _wgh_is_up; then
        echo -e "    ${GR}[OK]${CR} Interfaz ${WGH_IFACE}: UP"
        local hs_sec
        hs_sec=$(_wgh_handshake_seconds)
        if [ "$hs_sec" != "never" ] && [ "$hs_sec" -lt 180 ]; then
            echo -e "    ${GR}[OK]${CR} Handshake reciente: ${hs_sec}s atrás"
        else
            echo -e "    ${YL}[WARN]${CR} Handshake no reciente (${hs_sec}s)"
        fi
        local allowed
        allowed=$(grep -E '^\s*AllowedIPs\s*=' "${WGH_CONF}" 2>/dev/null | awk -F'=' '{print $2}' | xargs)
        if [ "$allowed" = "0.0.0.0/0" ]; then
            echo -e "    ${GR}[OK]${CR} AllowedIPs en Droplet: 0.0.0.0/0 (Internet Gateway habilitado)"
        else
            echo -e "    ${RD}[ERROR]${CR} AllowedIPs en Droplet: ${allowed:-desconocido} (Debe ser 0.0.0.0/0)"
        fi
        if grep -q "Table[[:space:]]*=[[:space:]]*off" "${WGH_CONF}" 2>/dev/null; then
            echo -e "    ${GR}[OK]${CR} Table = off configurado (tabla main protegida)"
        else
            echo -e "    ${YL}[WARN]${CR} Table = off no detectado en ${WGH_CONF}"
        fi
    else
        echo -e "    ${RD}[ERROR]${CR} Interfaz ${WGH_IFACE}: DOWN (túnel detenido)"
    fi
    echo ""

    # 2. ROUTING & POLICY ROUTING
    if _wgh_is_up; then
        echo ""
        echo -e "    ${DM}$(wg show "${WGH_IFACE}" 2>/dev/null | sed 's/^/    /' | head -12)${CR}"
    fi
    echo ""
    echo -e "  ${YL}[ 2/5 ] ENRUTAMIENTO Y POLICY ROUTING${CR}"
    local def_main
    def_main=$(ip route show table main | grep '^default' | head -1)
    if echo "$def_main" | grep -qv "wg-home"; then
        echo -e "    ${GR}[OK]${CR} Tabla main default: ${def_main}"
    else
        echo -e "    ${RD}[ERROR]${CR} Tabla main usa wg-home (SSH en riesgo!): ${def_main}"
    fi

    local rt200
    rt200=$(ip route show table "${WGH_RT_TABLE}" 2>/dev/null)
    if [ -n "$rt200" ]; then
        echo -e "    ${GR}[OK]${CR} Tabla 200 (${WGH_RT_NAME}): ${rt200}"
    else
        echo -e "    ${DM}[INFO]${CR} Tabla 200 vacía (salida residencial inactiva)"
    fi

    local rules
    rules=$(ip rule show | grep -E "homevpn|${WGH_RT_TABLE}" | head -5)
    if [ -n "$rules" ]; then
        echo -e "    ${GR}[OK]${CR} Reglas ip rule activas:"
        echo "$rules" | sed 's/^/         /'
    else
        echo -e "    ${DM}[INFO]${CR} Sin reglas ip rule activas hacia tabla 200"
    fi
    echo ""

    # 3. HTTP INJECTOR STACK
    echo -e "  ${YL}[ 3/5 ] STACK HTTP INJECTOR${CR}"
    local hi_info
    hi_info=$(_wgh_detect_http_injector)
    local ssl_p ssl_prc int_p final_s
    ssl_p=$(echo "$hi_info" | awk -F'|' '{print $1}' | cut -d= -f2)
    ssl_prc=$(echo "$hi_info" | awk -F'|' '{print $2}' | cut -d= -f2)
    int_p=$(echo "$hi_info" | awk -F'|' '{print $3}' | cut -d= -f2)
    final_s=$(echo "$hi_info" | awk -F'|' '{print $5}' | cut -d= -f2)

    echo -e "    Puerto SSL / TLS       : ${WH}${ssl_p}${CR} (${ssl_prc})"
    echo -e "    Destino Interno        : ${WH}${int_p}${CR}"
    echo -e "    Servicio SSH Final     : ${WH}${final_s}${CR}"

    local -a cusers=()
    while IFS= read -r cu; do [ -n "$cu" ] && cusers+=("$cu"); done < <(_wgh_get_configured_users)
    if [ ${#cusers[@]} -gt 0 ]; then
        echo -e "    ${GR}[OK]${CR} Usuarios enrutados por este módulo: ${WH}${cusers[*]}${CR}"
    else
        echo -e "    ${YL}[WARN]${CR} Ningún usuario configurado en ${WGH_USERS_CONF} (usa opción 12)"
    fi
    echo ""

    # 4. FIREWALL (IPTABLES / MANGLE)
    echo -e "  ${YL}[ 4/5 ] FIREWALL Y MARCAS (MANGLE/NAT)${CR}"
    local backend
    backend=$(_wgh_detect_firewall_backend)
    echo -e "    Backend detectado      : ${WH}${backend}${CR}"
    local mark_rules nat_rules
    mark_rules=$(iptables -t mangle -S OUTPUT 2>/dev/null | grep "HOMEVPN" | wc -l)
    nat_rules=$(iptables -t nat -S POSTROUTING 2>/dev/null | grep "HOMEVPN_NAT" | wc -l)
    echo -e "    Reglas mangle (marcado): ${WH}${mark_rules} regla(s) activas${CR}"
    echo -e "    Reglas NAT (masquerade): ${WH}${nat_rules} regla(s) activas${CR}"
    echo ""

    # 5. CONECTIVIDAD
    echo -e "  ${YL}[ 5/5 ] PRUEBAS DE CONECTIVIDAD${CR}"
    if _wgh_is_up; then
        if ping -c 2 -W 2 "${WGH_PEER_IP}" &>/dev/null; then
            echo -e "    ${GR}[OK]${CR} Ping a PC doméstico (${WGH_PEER_IP}): ÉXITO"
        else
            echo -e "    ${RD}[ERROR]${CR} Ping a PC doméstico (${WGH_PEER_IP}): FALLÓ"
        fi
    else
        echo -e "    ${DM}[INFO]${CR} Túnel inactivo, omitiendo ping a ${WGH_PEER_IP}"
    fi

    local ip_norm
    ip_norm=$(_wgh_get_droplet_ip)
    echo -e "    ${GR}[OK]${CR} Salida normal Droplet : ${ip_norm}"

    echo ""
    echo -e "$SEP"
    read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
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
    rm -f "${WGH_PEER_KEY}"
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
        ui_opt "6" "REGISTRAR CLAVE DEL PC" "peer doméstico"
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
        ui_opt_danger "12" "ELIMINAR CONFIGURACIÓN" "borra el gateway"
        ui_opt "0" "VOLVER"
        ui_solid
        ui_prompt "Elige una opción [0-12]"

        case "$REPLY_UI" in
            # Los pares activar/desactivar eran cuatro entradas de menu para dos
            # estados: ahora cada uno es un interruptor que alterna segun el tag.
            1)  wghome_install ;;
            2)  if _wgh_is_up; then wghome_tunnel_down; else wghome_tunnel_up; fi ;;
            3)  if _wgh_routing_is_active; then wghome_routing_off; else wghome_routing_on; fi ;;
            4)  wghome_configure_fallback ;;
            5)  wghome_show_pubkey ;;
            6)  wghome_register_peer ;;
            7)  wghome_view_users ;;
            8)  wghome_manage_users ;;
            9)  wghome_diagnose ;;
            10) wghome_ping_peer ;;
            11) wghome_check_ip ;;
            12) wghome_remove ;;
            0)  break ;;
            *)  ui_err "Opción no válida."; sleep 1 ;;
        esac
    done
}
