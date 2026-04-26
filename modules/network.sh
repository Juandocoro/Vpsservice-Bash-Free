#!/bin/bash

# === PALETA (heredada del entorno si se llama desde main.sh) ===
CR="\033[0m"
CY="\033[1;36m"
GR="\033[1;32m"
RD="\033[0;31m"
YL="\033[0;33m"
WH="\033[1;37m"
DM="\033[2;37m"
SEP="${YL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CR}"

function extract_port() {
    local service=$1
    # -p incluye el nombre del proceso; funciona con la mayoría de servicios
    ss -tlpnp 2>/dev/null | grep -i "$service" | awk '{print $4}' | awk -F':' '{print $NF}' | sort -u | head -n1
}

function refresh_ports() {
    PORT_SSH=$(extract_port "sshd")
    PORT_SSL=$(extract_port "stunnel")
    # BadVPN escucha en TCP 127.0.0.1 — detectar via ss con nombres de proceso
    PORT_UDP=$(ss -tlpnp 2>/dev/null | grep -i "badvpn" | awk '{print $4}' | awk -F':' '{print $NF}' | sort -u | head -n1)
    # Fallback: leer el puerto desde el archivo de servicio si el proceso está activo
    if [ -z "$PORT_UDP" ] && systemctl is-active --quiet badvpn 2>/dev/null; then
        PORT_UDP=$(grep -o '\-\-listen-addr [^ ]*' /etc/systemd/system/badvpn.service 2>/dev/null | awk -F':' '{print $NF}')
    fi
    PORT_WS=$(extract_port "python3.*proxy.py")
    if [ -z "$PORT_WS" ]; then
        PORT_WS=$(ss -tlpn | grep "python3" | awk '{print $4}' | awk -F':' '{print $NF}' | sort -u | head -n1 2>/dev/null)
    fi
    PORT_DROPBEAR=$(extract_port "dropbear")
    PORT_SLOWDNS=$(ss -ulpn | grep "slowdns" | awk '{print $4}' | awk -F':' '{print $NF}' | sort -u | head -n1 2>/dev/null)
    if systemctl is-active --quiet slowdns 2>/dev/null && [ -z "$PORT_SLOWDNS" ]; then PORT_SLOWDNS="5300"; fi
    PORT_SQUID=$(extract_port "squid")
    PORT_V2RAY=$(ss -tlpn | grep "v2ray" | awk '{print $4}' | awk -F':' '{print $NF}' | sort -u | head -n1 2>/dev/null)
    if systemctl is-active --quiet v2ray 2>/dev/null && [ -z "$PORT_V2RAY" ]; then
        PORT_V2RAY=$(grep '"port"' /usr/local/etc/v2ray/config.json 2>/dev/null | head -n1 | grep -o '[0-9]*')
    fi
    PORT_SS=$(ss -tlpn | grep "ss-server\|shadowsocks" | awk '{print $4}' | awk -F':' '{print $NF}' | sort -u | head -n1 2>/dev/null)
    if systemctl is-active --quiet shadowsocks-libev 2>/dev/null && [ -z "$PORT_SS" ]; then
        PORT_SS=$(grep '"server_port"' /etc/shadowsocks-libev/config.json 2>/dev/null | grep -o '[0-9]*')
    fi
    PORT_OVPN=$(ss -ulpn | grep "openvpn" | awk '{print $4}' | awk -F':' '{print $NF}' | sort -u | head -n1 2>/dev/null)
    if systemctl is-active --quiet openvpn@server 2>/dev/null && [ -z "$PORT_OVPN" ]; then
        PORT_OVPN=$(grep '^port' /etc/openvpn/server.conf 2>/dev/null | awk '{print $2}')
    fi
    PORT_WG=""
    if ip link show wg0 &>/dev/null; then
        PORT_WG=$(grep 'ListenPort' /etc/wireguard/wg0.conf 2>/dev/null | awk '{print $3}')
    fi

    # Auto-firewall driller
    if command -v ufw &>/dev/null; then
        [ -n "$PORT_SSH" ]      && ufw allow "$PORT_SSH"/tcp      &>/dev/null
        [ -n "$PORT_SSL" ]      && ufw allow "$PORT_SSL"/tcp      &>/dev/null
        [ -n "$PORT_UDP" ]      && ufw allow "$PORT_UDP"/udp      &>/dev/null
        [ -n "$PORT_WS" ]       && ufw allow "$PORT_WS"/tcp       &>/dev/null
        [ -n "$PORT_DROPBEAR" ] && ufw allow "$PORT_DROPBEAR"/tcp &>/dev/null
        [ -n "$PORT_SQUID" ]    && ufw allow "$PORT_SQUID"/tcp    &>/dev/null
        [ -n "$PORT_V2RAY" ]    && ufw allow "$PORT_V2RAY"/tcp    &>/dev/null
        [ -n "$PORT_SS" ]       && ufw allow "$PORT_SS"/tcp       &>/dev/null
        [ -n "$PORT_OVPN" ]     && ufw allow "$PORT_OVPN"/udp     &>/dev/null
        [ -n "$PORT_WG" ]       && ufw allow "$PORT_WG"/udp       &>/dev/null
    fi
}

function show_network_status() {
    IP_PUBLICA=$(curl -s ifconfig.me 2>/dev/null)
    [ -z "$IP_PUBLICA" ] && IP_PUBLICA="N/A"

    refresh_ports

    RAM_U=$(free -m | awk '/Mem:/ {print $3}')
    RAM_T=$(free -m | awk '/Mem:/ {print $2}')
    DISK_U=$(df -h / | awk 'NR==2 {print $3}')
    DISK_T=$(df -h / | awk 'NR==2 {print $2}')
    CPU_U=$(grep -o "^cpu \+.*" /proc/stat | awk '{print int(100 - ($5 * 100 / ($2+$3+$4+$5+$6+$7+$8)))"%"}')

    echo -e "  ${WH}IP: ${GR}$IP_PUBLICA${CR}"
    echo ""
    echo -e "  ${YL}[ ESTADO DE MAQUINA ]${CR}"
    echo -e "  ${DM}RAM: ${RAM_U}MB / ${RAM_T}MB  |  Disco: $DISK_U / $DISK_T  |  CPU: $CPU_U${CR}"
    echo ""

    # Construir lista de servicios activos
    local services=()
    [ -n "$PORT_SSH" ]      && services+=("SSH")
    [ -n "$PORT_DROPBEAR" ] && services+=("Dropbear")
    [ -n "$PORT_SSL" ]      && services+=("SSL")
    [ -n "$PORT_UDP" ]      && services+=("UDP")
    [ -n "$PORT_WS" ]       && services+=("WebSocket")
    [ -n "$PORT_SLOWDNS" ]  && services+=("SlowDNS")
    [ -n "$PORT_SQUID" ]    && services+=("Squid")
    [ -n "$PORT_V2RAY" ]    && services+=("V2Ray")
    [ -n "$PORT_SS" ]       && services+=("Shadowsocks")
    [ -n "$PORT_OVPN" ]     && services+=("OpenVPN")
    [ -n "$PORT_WG" ]       && services+=("WireGuard")

    echo -e "  ${YL}[ ACTIVOS ]${CR}"

    if [ ${#services[@]} -eq 0 ]; then
        echo -e "  ${RD}Sin servicios activos${CR}"
    else
        local i=0
        local line=""
        for svc in "${services[@]}"; do
            if [ $((i % 2)) -eq 0 ] && [ $i -gt 0 ]; then
                echo -e "$line"
                line=""
            fi
            line+="  ${GR}●${CR} ${WH}$(printf '%-12s' "$svc")${CR}"
            ((i++))
        done
        [ -n "$line" ] && echo -e "$line"
    fi
    echo ""
}
