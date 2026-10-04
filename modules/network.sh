#!/bin/bash

# La paleta y los helpers de dibujo viven en modules/ui.sh
_NET_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$_NET_DIR/ui.sh"

# =========================================================
# DETECCION DE PUERTOS
# ---------------------------------------------------------
# 'ss' se invoca UNA vez por familia y el resultado se cachea.
# Antes cada protocolo lanzaba su propia tuberia con ss: mas de
# una docena de procesos en cada redibujado del menu, algo que
# se nota en un VPS de 1 nucleo.
# =========================================================
_SS_TCP=""
_SS_UDP=""

_ss_snapshot() {
    _SS_TCP=$(ss -tlpn 2>/dev/null)
    _SS_UDP=$(ss -ulpn 2>/dev/null)
}

# _port_of <familia: tcp|udp> <patron> [filtro_extra]
# Devuelve el primer puerto en escucha cuyo proceso casa con el patron.
_port_of() {
    local fam="$1" pat="$2" extra="${3:-}"
    local data
    [ "$fam" = "udp" ] && data="$_SS_UDP" || data="$_SS_TCP"
    [ -n "$extra" ] && data=$(echo "$data" | grep -F "$extra")
    echo "$data" | grep -iE "$pat" | awk '{print $4}' | awk -F':' '{print $NF}' \
        | grep -E '^[0-9]+$' | sort -un | head -n1
}

# Se mantiene el nombre antiguo por compatibilidad con codigo externo.
function extract_port() { _port_of tcp "$1"; }

function refresh_ports() {
    _ss_snapshot

    # Se ignora lo que escucha solo en 127.0.0.1: tras cambiar el puerto
    # SSH se deja el 22 en local para stunnel y WebSocket, y ese no es el
    # puerto que hay que dar a los clientes.
    PORT_SSH=$(echo "$_SS_TCP" | grep -iE "sshd" | awk '{print $4}' | grep -v '^127\.' \
        | awk -F':' '{print $NF}' | grep -E '^[0-9]+$' | sort -un | head -n1)
    [ -z "$PORT_SSH" ] && PORT_SSH=$(_port_of tcp "sshd")
    PORT_SSL=$(_port_of tcp "stunnel")
    PORT_DROPBEAR=$(_port_of tcp "dropbear")
    PORT_SQUID=$(_port_of tcp "squid")

    # UDP Custom — Hysteria2 (escucha en UDP, publico, sin SSH)
    PORT_UDPCUSTOM=$(_port_of udp "hysteria")
    if [ -z "$PORT_UDPCUSTOM" ] && systemctl is-active --quiet hysteria-server 2>/dev/null; then
        PORT_UDPCUSTOM=$(grep '^listen:' /etc/hysteria/config.yaml 2>/dev/null | awk -F: '{print $NF}' | tr -d ' ')
    fi
    # Compatibilidad: PORT_UDP apunta a UDP Custom para no romper logica existente
    PORT_UDP="$PORT_UDPCUSTOM"

    # BadVPN — escucha solo en 127.0.0.1 (requiere un tunel SSH activo)
    PORT_BADVPN=$(_port_of tcp "badvpn" "127.0.0.1")
    if [ -z "$PORT_BADVPN" ] && systemctl is-active --quiet badvpn 2>/dev/null; then
        PORT_BADVPN=$(grep -o '\-\-listen-addr [^ ]*' /etc/systemd/system/badvpn.service 2>/dev/null | awk -F':' '{print $NF}')
    fi

    PORT_WS=$(_port_of tcp "proxy\.py")
    [ -z "$PORT_WS" ] && PORT_WS=$(_port_of tcp "python3")

    PORT_SLOWDNS=$(_port_of udp "slowdns")
    if [ -z "$PORT_SLOWDNS" ] && systemctl is-active --quiet slowdns 2>/dev/null; then
        PORT_SLOWDNS="5300"
    fi

    PORT_V2RAY=$(_port_of tcp "v2ray")
    if [ -z "$PORT_V2RAY" ] && systemctl is-active --quiet v2ray 2>/dev/null; then
        PORT_V2RAY=$(grep '"port"' /usr/local/etc/v2ray/config.json 2>/dev/null | head -n1 | grep -o '[0-9]*')
    fi

    PORT_SS=$(_port_of tcp "ss-server|shadowsocks")
    if [ -z "$PORT_SS" ] && systemctl is-active --quiet shadowsocks-libev 2>/dev/null; then
        PORT_SS=$(grep '"server_port"' /etc/shadowsocks-libev/config.json 2>/dev/null | grep -o '[0-9]*')
    fi

    PORT_OVPN=$(_port_of udp "openvpn")
    if [ -z "$PORT_OVPN" ] && systemctl is-active --quiet openvpn@server 2>/dev/null; then
        PORT_OVPN=$(grep '^port' /etc/openvpn/server.conf 2>/dev/null | awk '{print $2}')
    fi

    PORT_WG=""
    if ip link show wg0 &>/dev/null; then
        PORT_WG=$(grep 'ListenPort' /etc/wireguard/wg0.conf 2>/dev/null | awk '{print $3}')
    fi

    # wg-home — Gateway Residencial (modulo wg_home.sh)
    PORT_WGHOME=""
    if ip link show wg-home &>/dev/null; then
        PORT_WGHOME=$(grep 'ListenPort' /etc/wireguard/wg-home.conf 2>/dev/null | awk '{print $3}')
        [ -z "$PORT_WGHOME" ] && PORT_WGHOME="51820"
    fi
}

# =========================================================
# PROTECCIÓN Y SINCRONIZACIÓN DEL CORTAFUEGOS (UFW)
# =========================================================
# Puertos que los servicios tienen CONFIGURADOS, esten corriendo o no.
# Se leen de sus ficheros: si el cortafuegos solo abriera lo que escucha
# en ese instante, un servicio que se estuviera reiniciando quedaria
# bloqueado al volver, y sus clientes sin conexion hasta que alguien
# sincronizara otra vez a mano.
#   salida: una linea "puerto/proto" por regla
_configured_ports() {
    local p
    p=$(grep -E '^\s*accept\s*=' /etc/stunnel/stunnel.conf 2>/dev/null | grep -oE '[0-9]+$')
    [ -n "$p" ] && echo "$p/tcp"
    p=$(grep -oE 'WS_PORT=[0-9]+' /etc/systemd/system/websocket_proxy.service 2>/dev/null | cut -d= -f2)
    [ -n "$p" ] && echo "$p/tcp"
    p=$(sed -n 's/^DROPBEAR_PORT=//p' /etc/default/dropbear 2>/dev/null | grep -oE '[0-9]+' | head -1)
    [ -n "$p" ] && echo "$p/tcp"
    p=$(grep -E '^\s*http_port' /etc/squid/squid.conf 2>/dev/null | grep -oE '[0-9]+' | head -1)
    [ -n "$p" ] && echo "$p/tcp"
    p=$(grep '"port"' /usr/local/etc/v2ray/config.json 2>/dev/null | head -1 | grep -oE '[0-9]+')
    [ -n "$p" ] && echo "$p/tcp"
    p=$(grep '"server_port"' /etc/shadowsocks-libev/config.json 2>/dev/null | grep -oE '[0-9]+')
    [ -n "$p" ] && { echo "$p/tcp"; echo "$p/udp"; }
    p=$(grep -E '^port ' /etc/openvpn/server.conf 2>/dev/null | awk '{print $2}')
    if [ -n "$p" ]; then
        local proto
        proto=$(grep -E '^proto ' /etc/openvpn/server.conf 2>/dev/null | awk '{print $2}' | grep -oE 'tcp|udp')
        echo "$p/${proto:-udp}"
    fi
    p=$(grep -E 'ListenPort' /etc/wireguard/wg0.conf 2>/dev/null | grep -oE '[0-9]+')
    [ -n "$p" ] && echo "$p/udp"
    if systemctl is-enabled --quiet slowdns 2>/dev/null; then echo "5300/udp"; echo "53/udp"; fi
    # Nodos residenciales: cada nodo WireGuard escucha en su propio puerto.
    local f
    for f in /etc/wireguard/wg-home*.conf; do
        [ -f "$f" ] || continue
        p=$(grep -E 'ListenPort' "$f" 2>/dev/null | grep -oE '[0-9]+')
        [ -n "$p" ] && echo "$p/udp"
    done
}

function sync_firewall() {
    ui_info "Analizando puertos y aplicando reglas del cortafuegos (UFW)..."

    # 1. Asegurar instalación de UFW
    if ! command -v ufw &>/dev/null; then
        ui_info "Instalando UFW..."
        apt-get update -y &>/dev/null
        apt-get install ufw -y &>/dev/null
    fi
    command -v ufw &>/dev/null || { ui_err "No se pudo instalar UFW."; sleep 2; return 1; }

    refresh_ports

    # 2. Sin 'ufw reset'. Antes se borraba todo y se reabria solo lo que
    # escuchaba en ese momento: un servicio reiniciandose, los puertos de
    # los nodos 2..N o el 'allow in on wg-homeN' se quedaban fuera, y con
    # ellos sus clientes. Ahora solo se AÑADEN reglas; 'ufw allow' es
    # idempotente, asi que repetirlo no duplica nada.
    ufw default deny incoming &>/dev/null
    ufw default allow outgoing &>/dev/null

    local -a reglas=("22/tcp" "80/tcp" "443/tcp")
    [ -n "$PORT_SSH" ]       && reglas+=("$PORT_SSH/tcp")
    [ -n "$PORT_SSL" ]       && reglas+=("$PORT_SSL/tcp")
    [ -n "$PORT_UDPCUSTOM" ] && reglas+=("$PORT_UDPCUSTOM/udp" "$PORT_UDPCUSTOM/tcp")
    [ -n "$PORT_WS" ]        && reglas+=("$PORT_WS/tcp")
    [ -n "$PORT_DROPBEAR" ]  && reglas+=("$PORT_DROPBEAR/tcp")
    [ -n "$PORT_SQUID" ]     && reglas+=("$PORT_SQUID/tcp")
    [ -n "$PORT_V2RAY" ]     && reglas+=("$PORT_V2RAY/tcp")
    [ -n "$PORT_SS" ]        && reglas+=("$PORT_SS/tcp")
    [ -n "$PORT_OVPN" ]      && reglas+=("$PORT_OVPN/udp")
    [ -n "$PORT_WG" ]        && reglas+=("$PORT_WG/udp")
    [ -n "$PORT_SLOWDNS" ]   && reglas+=("$PORT_SLOWDNS/udp" "53/udp")
    [ -n "$PORT_WGHOME" ]    && reglas+=("$PORT_WGHOME/udp")
    local r
    while read -r r; do [ -n "$r" ] && reglas+=("$r"); done < <(_configured_ports)

    for r in $(printf '%s\n' "${reglas[@]}" | sort -u); do
        ufw allow "$r" &>/dev/null
    done

    # La entrada POR el tunel de cada nodo (pings de prueba, trafico que
    # inicia el nodo). Solo abre su interfaz, no Internet.
    local ifc
    for ifc in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^wg-home[0-9]*$'); do
        ufw allow in on "$ifc" &>/dev/null
    done

    echo "y" | ufw enable &>/dev/null
    ui_ok "Cortafuegos activo. Reglas existentes conservadas."
    sleep 2
}

# =========================================================
# ESTADO DE LOS SERVICIOS
# ---------------------------------------------------------
# Distinguir "no instalado" de "instalado pero caido" es lo que
# de verdad necesita el admin: lo segundo deja clientes sin
# servicio y hay que saberlo nada mas abrir el panel.
# =========================================================
# Servicios del panel: unidad|nombre visible
VPS_SERVICES=(
    "stunnel4|SSL"
    "dropbear|Dropbear"
    "websocket_proxy|WebSocket"
    "badvpn|BadVPN"
    "udp-custom|UDP Custom"
    "slowdns|SlowDNS"
    "squid|Squid"
    "v2ray|V2Ray"
    "shadowsocks-libev|Shadowsocks"
    "openvpn@server|OpenVPN"
    "wg-quick@wg0|WireGuard"
)

# Servicios SysV: systemd no sabe si "estan habilitados", asi que se
# deduce de que el instalador del panel dejo su configuracion.
_svc_installed() {
    case "$1" in
        stunnel4) [ -f /etc/stunnel/stunnel.conf ] ;;
        dropbear) grep -q '^NO_START=0' /etc/default/dropbear 2>/dev/null ;;
        *)        systemctl is-enabled --quiet "$1" 2>/dev/null ;;
    esac
}

# _svc_state <unidad> -> on | down | off
_svc_state() {
    if systemctl is-active --quiet "$1" 2>/dev/null; then echo on
    elif systemctl is-enabled --quiet "$1" 2>/dev/null || _svc_installed "$1"; then echo down
    else echo off; fi
}

# Etiqueta para la fabrica de protocolos
ui_tag_svc() {
    local port="$1" unit="$2"
    if [ -n "$port" ]; then echo -e "${GR}[ ON  ]${CR}"
    elif [ "$(_svc_state "$unit")" = "down" ]; then echo -e "${RD}[CAIDO]${CR}"
    else echo -e "${DM}[ OFF ]${CR}"; fi
}

# Nombres de los servicios instalados que estan caidos ahora mismo.
# Dos llamadas a systemctl para todos (imprime un estado por unidad,
# en orden), no dos por servicio: esto se pinta en cada redibujado.
_services_down() {
    command -v systemctl &>/dev/null || return 0
    local -a units=()
    local e
    for e in "${VPS_SERVICES[@]}"; do units+=("${e%%|*}.service"); done
    # 'show' devuelve un bloque por unidad aunque no exista (is-enabled,
    # en cambio, no imprime nada para una unidad inexistente y descuadraria
    # la lista).
    systemctl show -p Id -p ActiveState -p UnitFileState "${units[@]}" 2>/dev/null \
        | _parse_services_down
}

# Lee la salida de 'systemctl show' y saca los nombres visibles de los
# servicios habilitados que no estan activos. Separada para poder probarla.
_parse_services_down() {
    local line id="" act="" ufs="" e
    _emit() {
        # Los servicios con script SysV (stunnel4, dropbear en algunas
        # versiones) salen como 'generated': se miran por su config.
        [ "$ufs" = "generated" ] && _svc_installed "${id%.service}" && ufs="enabled"
        if [ -n "$id" ] && [ "$ufs" = "enabled" ] && [ "$act" != "active" ] && [ "$act" != "activating" ] && [ "$act" != "reloading" ]; then
            for e in "${VPS_SERVICES[@]}"; do
                [ "${e%%|*}.service" = "$id" ] && echo "${e#*|}"
            done
        fi
        id=""; act=""; ufs=""
    }
    while IFS= read -r line; do
        case "$line" in
            Id=*)            id="${line#Id=}" ;;
            ActiveState=*)   act="${line#ActiveState=}" ;;
            UnitFileState=*) ufs="${line#UnitFileState=}" ;;
            "")              _emit ;;
        esac
    done
    _emit
}


# =========================================================
# TABLERO PRINCIPAL — bloque de estado del servidor
# =========================================================

# La IP publica se resuelve una sola vez por sesion: consultarla en cada
# redibujado del menu metia una latencia de red innecesaria.
_public_ip() {
    if [ -z "${VPS_PUBLIC_IP:-}" ]; then
        VPS_PUBLIC_IP=$(curl -4 -s --max-time 4 ifconfig.me 2>/dev/null)
        [ -z "$VPS_PUBLIC_IP" ] && VPS_PUBLIC_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
        [ -z "$VPS_PUBLIC_IP" ] && VPS_PUBLIC_IP="N/A"
    fi
    echo "$VPS_PUBLIC_IP"
}

_os_name() {
    local n
    n=$(grep -oP '(?<=^PRETTY_NAME=").*(?=")' /etc/os-release 2>/dev/null)
    [ -z "$n" ] && n=$(uname -s)
    # Recortar para que quepa en la celda
    echo "${n:0:14}"
}

_uptime_short() {
    local up
    up=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
    [ -z "$up" ] && { echo "N/A"; return; }
    if   [ "$up" -ge 86400 ]; then echo "$((up/86400))d $((up%86400/3600))h"
    elif [ "$up" -ge 3600 ];  then echo "$((up/3600))h $((up%3600/60))m"
    else                           echo "$((up/60))m"
    fi
}

# Pinta una fila de puertos en tres columnas (nombre: puerto)
_port_grid() {
    local entries=("$@")
    local total=${#entries[@]}
    [ "$total" -eq 0 ] && { echo -e "${UI_PAD}${RD}Sin protocolos activos — instala uno en PROTOCOLOS${CR}"; return; }

    local w=$(( (UI_W - 4) / 3 ))
    local i=0
    while [ $i -lt $total ]; do
        local row="${UI_PAD}"
        for col in 0 1 2; do
            local idx=$(( i + col ))
            if [ $idx -ge $total ]; then
                # Rellenar la fila incompleta para no romper la alineacion
                row="${row}$(printf '%*s' $((w+2)) '')"
                continue
            fi
            local ename eport
            IFS='|' read -r ename eport <<< "${entries[$idx]}"
            local sep="${DM}▸${CR} "
            [ $col -eq 2 ] && sep=""
            row="${row}${GR}▪${CR} $(ui_cell "$ename" "$eport" $((w-2)) "$CY")${sep}"
        done
        echo -e "$row"
        (( i += 3 ))
    done
}

function show_network_status() {
    refresh_ports

    # ── Identidad de la maquina ──
    local IP_PUBLICA OS ARCH CORES HORA UP
    IP_PUBLICA=$(_public_ip)
    OS=$(_os_name)
    ARCH=$(uname -m)
    CORES=$(nproc 2>/dev/null || echo "?")
    HORA=$(date +%H:%M:%S)
    UP=$(_uptime_short)

    ui_row3 "OS" "$OS" "ARCH" "$ARCH" "CORES" "$CORES"
    ui_row3 "IP" "$IP_PUBLICA" "HORA" "$HORA" "UPTIME" "$UP"
    ui_rule

    # ── Recursos ──
    local RAM_U RAM_T RAM_PCT DISK_U DISK_T DISK_PCT CPU_PCT
    # Una llamada a free y una a df (antes eran cinco por redibujado).
    read -r RAM_T RAM_U < <(free -m | awk '/Mem:/ {print $2, $3}')
    RAM_PCT=0
    [ "${RAM_T:-0}" -gt 0 ] && RAM_PCT=$(( RAM_U * 100 / RAM_T ))

    read -r DISK_T DISK_U DISK_PCT < <(df -h / | awk 'NR==2 {gsub(/%/,"",$5); print $2, $3, $5}')
    DISK_PCT=${DISK_PCT:-0}

    CPU_PCT=$(grep -o "^cpu \+.*" /proc/stat | awk '{print int(100 - ($5 * 100 / ($2+$3+$4+$5+$6+$7+$8)))}')
    CPU_PCT=${CPU_PCT:-0}

    printf "${UI_PAD}%b ${DM}RAM  ${CR}%b ${WH}%-15s${CR} ${DM}(%s%%)${CR}\n" \
        "$(ui_dot "$RAM_PCT")" "$(ui_bar "$RAM_PCT")" "${RAM_U}Mi/${RAM_T}Mi" "$RAM_PCT"
    printf "${UI_PAD}%b ${DM}DISCO${CR} %b ${WH}%-15s${CR} ${DM}(%s%%)${CR}\n" \
        "$(ui_dot "$DISK_PCT")" "$(ui_bar "$DISK_PCT")" "${DISK_U}/${DISK_T}" "$DISK_PCT"
    printf "${UI_PAD}%b ${DM}CPU  ${CR}%b ${WH}%-15s${CR} ${DM}(%s%%)${CR}\n" \
        "$(ui_dot "$CPU_PCT")" "$(ui_bar "$CPU_PCT")" "${CORES} nucleo(s)" "$CPU_PCT"
    ui_rule

    # ── Cuentas y sesiones ──
    # contar_cuentas y contar_online los aporta modules/users.sh
    if declare -F contar_cuentas >/dev/null 2>&1; then
        contar_cuentas
        echo -e "${UI_PAD}${YL}CUENTAS${CR}  ${DM}▸${CR} $(ui_cell "Activas" "${USR_ACTIVAS:-0}" 16 "$GR")${DM}▸${CR} $(ui_cell "Por vencer" "${USR_PORVENCER:-0}" 18 "$YL")${DM}▸${CR} $(ui_cell "Vencidas" "${USR_VENCIDAS:-0}" 14 "$RD")"
    fi
    if declare -F contar_online >/dev/null 2>&1; then
        contar_online
        echo -e "${UI_PAD}${YL}ONLINE${CR}   ${DM}▸${CR} $(ui_cell "SSH" "${ON_SSH:-0}" 16 "$CY")${DM}▸${CR} $(ui_cell "Dropbear" "${ON_DROPBEAR:-0}" 18 "$CY")${DM}▸${CR} $(ui_cell "OpenVPN" "${ON_OVPN:-0}" 14 "$CY")"
    fi
    ui_rule

    # ── Puertos activos ──
    local entries=()
    [ -n "$PORT_SSH" ]        && entries+=("SSH|$PORT_SSH")
    [ -n "$PORT_DROPBEAR" ]   && entries+=("Dropbear|$PORT_DROPBEAR")
    [ -n "$PORT_SSL" ]        && entries+=("SSL|$PORT_SSL")
    [ -n "$PORT_WS" ]         && entries+=("WebSocket|$PORT_WS")
    [ -n "$PORT_UDPCUSTOM" ]  && entries+=("UDP|$PORT_UDPCUSTOM")
    [ -n "$PORT_BADVPN" ]     && entries+=("BadVPN|$PORT_BADVPN")
    [ -n "$PORT_SLOWDNS" ]    && entries+=("SlowDNS|$PORT_SLOWDNS")
    [ -n "$PORT_SQUID" ]      && entries+=("Squid|$PORT_SQUID")
    [ -n "$PORT_V2RAY" ]      && entries+=("V2Ray|$PORT_V2RAY")
    [ -n "$PORT_SS" ]         && entries+=("Shadow|$PORT_SS")
    [ -n "$PORT_OVPN" ]       && entries+=("OpenVPN|$PORT_OVPN")
    [ -n "$PORT_WG" ]         && entries+=("WireGuard|$PORT_WG")
    [ -n "$PORT_WGHOME" ]     && entries+=("WG-Home|$PORT_WGHOME")

    _port_grid "${entries[@]}"

    _show_alerts
}

# =========================================================
# ALERTAS — lo que deja o puede dejar clientes sin servicio
# ---------------------------------------------------------
# Se pinta en el tablero para que se vea nada mas abrir el
# panel, sin tener que ir a buscarlo a cada submenu.
# =========================================================
_alert_lines() {
    local caidos nodos n
    caidos=$(_services_down | paste -sd',' - | sed 's/,/, /g')
    [ -n "$caidos" ] && echo "${RD}✗ Caído:${CR} ${caidos} ${DM}(el guardián lo reintenta cada minuto)${CR}"

    if [ -f /etc/wireguard/homevpn-routing.on ]; then
        nodos=$(grep '=down$' /run/homevpn-health 2>/dev/null | cut -d= -f1 | paste -sd',' - | sed 's/,/, /g')
        [ -n "$nodos" ] && echo "${YL}! Nodo caído:${CR} ${nodos} ${DM}(sus usuarios usan el respaldo)${CR}"
        systemctl is-active --quiet homevpn-watchdog 2>/dev/null || \
            echo "${RD}✗ Vigilante de nodos detenido:${CR} ${DM}si un nodo cae, sus usuarios se quedan sin Internet${CR}"
    fi

    n="${USR_VENCEN_HOY:-0}"
    [ "$n" -gt 0 ] 2>/dev/null && echo "${YL}! ${n} cuenta(s) vencen hoy${CR}"
    n="${USR_VENCIDAS:-0}"
    [ "$n" -gt 0 ] 2>/dev/null && echo "${DM}· ${n} cuenta(s) vencida(s): renuévalas o elimínalas${CR}"
}

_show_alerts() {
    local lines l
    lines=$(_alert_lines)
    ui_rule
    if [ -z "$lines" ]; then
        echo -e "${UI_PAD}${GR}✓ Todo funcionando${CR}"
    else
        while IFS= read -r l; do echo -e "${UI_PAD}${l}"; done <<<"$lines"
    fi
}
