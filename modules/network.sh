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

    PORT_SSH=$(_port_of tcp "sshd")
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
function sync_firewall() {
    echo -e "  ${YL}[*] Analizando puertos y aplicando reglas del cortafuegos (UFW)...${CR}"
    
    # 1. Asegurar instalación de UFW
    if ! command -v ufw &>/dev/null; then
        echo -e "  ${YL}[*] Instalando UFW...${CR}"
        apt-get update -y &>/dev/null
        apt-get install ufw -y &>/dev/null
    fi

    # Refrescar las variables de puertos actuales
    refresh_ports

    # 2. Resetear el cortafuegos para limpieza absoluta (borra reglas externas)
    echo "y" | ufw reset &>/dev/null
    
    # 3. Políticas Base
    ufw default deny incoming &>/dev/null
    ufw default allow outgoing &>/dev/null
    
    # 4. Reglas Inquebrantables (SSH, Web básica)
    # Protegemos el puerto 22, pero también leemos si hay un puerto custom SSH ($PORT_SSH)
    ufw allow 22/tcp &>/dev/null
    ufw allow 80/tcp &>/dev/null
    ufw allow 443/tcp &>/dev/null
    
    # 5. Escaneo dinámico: Habilitamos solo lo que esté activo en el script
    [ -n "$PORT_SSH" ]          && ufw allow "$PORT_SSH"/tcp          &>/dev/null
    [ -n "$PORT_SSL" ]          && ufw allow "$PORT_SSL"/tcp          &>/dev/null
    [ -n "$PORT_UDPCUSTOM" ]    && ufw allow "$PORT_UDPCUSTOM"/udp    &>/dev/null
    [ -n "$PORT_UDPCUSTOM" ]    && ufw allow "$PORT_UDPCUSTOM"/tcp    &>/dev/null
    [ -n "$PORT_WS" ]           && ufw allow "$PORT_WS"/tcp           &>/dev/null
    [ -n "$PORT_DROPBEAR" ]     && ufw allow "$PORT_DROPBEAR"/tcp     &>/dev/null
    [ -n "$PORT_SQUID" ]        && ufw allow "$PORT_SQUID"/tcp        &>/dev/null
    [ -n "$PORT_V2RAY" ]        && ufw allow "$PORT_V2RAY"/tcp        &>/dev/null
    [ -n "$PORT_SS" ]           && ufw allow "$PORT_SS"/tcp           &>/dev/null
    [ -n "$PORT_OVPN" ]         && ufw allow "$PORT_OVPN"/udp         &>/dev/null
    [ -n "$PORT_WG" ]           && ufw allow "$PORT_WG"/udp           &>/dev/null
    # FIX: SlowDNS necesita su puerto UDP y el 53 (DNS). Sin estas reglas el
    # 'ufw reset' de arriba cerraba el tunel DNS en cada sincronizacion.
    if [ -n "$PORT_SLOWDNS" ]; then
        ufw allow "$PORT_SLOWDNS"/udp &>/dev/null
        ufw allow 53/udp              &>/dev/null
    fi
    # wg-home — Gateway Residencial: solo abrir si está activa
    [ -n "$PORT_WGHOME" ]       && ufw allow "$PORT_WGHOME"/udp       &>/dev/null
    
    # 6. Activar definitivamente
    echo "y" | ufw enable &>/dev/null
    echo -e "  ${GR}[+] Cortafuegos seguro activado.${CR}"
    sleep 2
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
    [ "$total" -eq 0 ] && { echo -e "${UI_PAD}${RD}Sin protocolos activos — instala uno desde la opcion [2]${CR}"; return; }

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
    RAM_U=$(free -m | awk '/Mem:/ {print $3}')
    RAM_T=$(free -m | awk '/Mem:/ {print $2}')
    RAM_PCT=0
    [ "${RAM_T:-0}" -gt 0 ] && RAM_PCT=$(( RAM_U * 100 / RAM_T ))

    DISK_U=$(df -h / | awk 'NR==2 {print $3}')
    DISK_T=$(df -h / | awk 'NR==2 {print $2}')
    DISK_PCT=$(df / | awk 'NR==2 {gsub(/%/,""); print $5}' 2>/dev/null)
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
}
