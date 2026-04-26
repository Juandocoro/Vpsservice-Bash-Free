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
    # UDP Custom — Hysteria2 (escucha en UDP, público, sin SSH)
    PORT_UDPCUSTOM=$(ss -ulpnp 2>/dev/null | grep -i "hysteria" | awk '{print $4}' | awk -F':' '{print $NF}' | sort -u | head -n1)
    if [ -z "$PORT_UDPCUSTOM" ] && systemctl is-active --quiet hysteria-server 2>/dev/null; then
        PORT_UDPCUSTOM=$(grep '^listen:' /etc/hysteria/config.yaml 2>/dev/null | awk -F: '{print $NF}' | tr -d ' ')
    fi

    # BadVPN — escucha en 127.0.0.1 (local, requiere SSH activo)
    PORT_BADVPN=$(ss -tlpnp 2>/dev/null | grep -i "badvpn" | grep "127.0.0.1" | awk '{print $4}' | awk -F':' '{print $NF}' | sort -u | head -n1)
    if [ -z "$PORT_BADVPN" ] && systemctl is-active --quiet badvpn 2>/dev/null; then
        PORT_BADVPN=$(grep -o '\-\-listen-addr [^ ]*' /etc/systemd/system/badvpn.service 2>/dev/null | awk -F':' '{print $NF}')
    fi

    # Compatibilidad: PORT_UDP apunta a UDP Custom para no romper lógica existente
    PORT_UDP="$PORT_UDPCUSTOM"
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
    echo -e "  ${YL}[ ESTADO DE MÁQUINA ]${CR}"
    echo -e "  ${DM}RAM: ${RAM_U}MB/${RAM_T}MB  |  Disco: $DISK_U/$DISK_T  |  CPU: $CPU_U${CR}"
    echo ""
    echo -e "  ${YL}[ PROTOCOLOS ACTIVOS ]${CR}"
    echo ""

    # Cada entrada: "NOMBRE|PUERTO"
    local entries=()
    [ -n "$PORT_SSH" ]        && entries+=("SSH|$PORT_SSH")
    [ -n "$PORT_DROPBEAR" ]   && entries+=("Dropbear|$PORT_DROPBEAR")
    [ -n "$PORT_SSL" ]        && entries+=("Stunnel SSL|$PORT_SSL")
    [ -n "$PORT_WS" ]         && entries+=("WebSocket|$PORT_WS")
    [ -n "$PORT_UDPCUSTOM" ]  && entries+=("UDP Custom|$PORT_UDPCUSTOM")
    [ -n "$PORT_BADVPN" ]     && entries+=("BadVPN|$PORT_BADVPN")
    [ -n "$PORT_SLOWDNS" ]    && entries+=("SlowDNS|$PORT_SLOWDNS")
    [ -n "$PORT_SQUID" ]      && entries+=("Squid|$PORT_SQUID")
    [ -n "$PORT_V2RAY" ]      && entries+=("V2Ray|$PORT_V2RAY")
    [ -n "$PORT_SS" ]         && entries+=("Shadowsocks|$PORT_SS")
    [ -n "$PORT_OVPN" ]       && entries+=("OpenVPN|$PORT_OVPN")
    [ -n "$PORT_WG" ]         && entries+=("WireGuard|$PORT_WG")

    if [ ${#entries[@]} -eq 0 ]; then
        echo -e "  ${RD}Sin protocolos activos instalados${CR}"
        echo ""
    else
        local i=0
        while [ $i -lt ${#entries[@]} ]; do
            local left="${entries[$i]}"
            local right="${entries[$((i+1))]:-}"

            local lname lport
            IFS='|' read -r lname lport <<< "$left"
            local lcell
            lcell=$(printf "  ${GR}●${CR} ${WH}%-13s${CR}${DM}:${CR} ${CY}%-6s${CR}" "$lname" "$lport")

            if [ -n "$right" ]; then
                local rname rport
                IFS='|' read -r rname rport <<< "$right"
                local rcell
                rcell=$(printf "  ${GR}●${CR} ${WH}%-13s${CR}${DM}:${CR} ${CY}%-6s${CR}" "$rname" "$rport")
                echo -e "$lcell$rcell"
            else
                echo -e "$lcell"
            fi

            ((i+=2))
        done
        echo ""
    fi
}
