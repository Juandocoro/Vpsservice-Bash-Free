#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Error: Ejecutar como root."
  exit 1
fi

CR="\033[0m"; GR="\033[1;32m"; RD="\033[0;31m"
YL="\033[0;33m"; CY="\033[1;36m"; WH="\033[1;37m"; DM="\033[2;37m"

_ok()   { echo -e "  ${GR}[+]${CR} $1"; }
_info() { echo -e "  ${YL}[*]${CR} $1"; }
_err()  { echo -e "  ${RD}[-]${CR} $1"; }

clear
echo -e "${YL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CR}"
echo -e "${WH}        BadVPN — Gateway UDP para SSH             ${CR}"
echo -e "${YL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CR}"
echo ""
echo -e "  ${DM}BadVPN permite tunnelizar tráfico UDP (juegos,${CR}"
echo -e "  ${DM}llamadas VoIP) a través del túnel SSH activo.${CR}"
echo -e "  ${DM}Se usa junto con SSH — NO es un túnel directo.${CR}"
echo ""

read -p "$(echo -e ${DM})¿Instalar BadVPN UDP Gateway? (s/n): $(echo -e ${CR})" auth
if [[ "$auth" != "s" && "$auth" != "S" ]]; then exit 0; fi

echo ""

# ── obtener binario ────────────────────────────────────────────────────────────
BINARY_SOURCES=(
    "https://raw.githubusercontent.com/daybreakersx/premscript/master/badvpn-udpgw64"
    "https://github.com/Kurosaki-io/BadVPN-UDPGateway/releases/download/1.0/badvpn-udpgw"
)

BINARY_OK=false
if [ -f "/usr/local/bin/badvpn-udpgw" ] && file /usr/local/bin/badvpn-udpgw 2>/dev/null | grep -q "ELF"; then
    _ok "Binario ya existe. Reutilizando."; BINARY_OK=true
fi

if [ "$BINARY_OK" = false ]; then
    for URL in "${BINARY_SOURCES[@]}"; do
        _info "Descargando binario..."
        if wget -q --timeout=20 -O /tmp/badvpn-tmp "$URL" 2>/dev/null && \
           file /tmp/badvpn-tmp 2>/dev/null | grep -q "ELF"; then
            mv /tmp/badvpn-tmp /usr/local/bin/badvpn-udpgw
            chmod +x /usr/local/bin/badvpn-udpgw
            _ok "Binario descargado."; BINARY_OK=true; break
        fi
        rm -f /tmp/badvpn-tmp
    done
fi

if [ "$BINARY_OK" = false ]; then
    _info "Compilando desde fuente..."
    apt-get install -y cmake build-essential gcc git &>/dev/null
    cd /tmp && rm -rf badvpn
    git clone https://github.com/ambrop72/badvpn.git &>/dev/null
    cd badvpn && mkdir -p build && cd build
    cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 &>/dev/null && make install &>/dev/null
    [ -f "/usr/local/bin/badvpn-udpgw" ] && BINARY_OK=true
fi

if [ "$BINARY_OK" = false ]; then
    _err "No se pudo obtener el binario. Abortando."; sleep 3; exit 1
fi

# ── puerto ─────────────────────────────────────────────────────────────────────
CURRENT=$(grep -o '\-\-listen-addr [^ ]*' /etc/systemd/system/badvpn.service 2>/dev/null | awk -F':' '{print $NF}')
[ -n "$CURRENT" ] && echo -e "  ${DM}Puerto actual: ${CY}$CURRENT${CR}"
read -p "$(echo -e ${DM})Puerto BadVPN (Defecto: 7300): $(echo -e ${CR})" bvpn_port
[ -z "$bvpn_port" ] && bvpn_port=${CURRENT:-7300}
[[ ! "$bvpn_port" =~ ^[0-9]+$ ]] && bvpn_port=7300

# ── servicio systemd ───────────────────────────────────────────────────────────
# BadVPN escucha solo en 127.0.0.1 (local) — se usa junto con SSH
cat > /etc/systemd/system/badvpn.service <<EOF
[Unit]
Description=BadVPN UDP Gateway (para llamadas y juegos via SSH)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:${bvpn_port} --max-clients 500 --max-connections-for-client 10 --client-socket-sndbuf 10000
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable badvpn &>/dev/null
systemctl stop badvpn &>/dev/null; sleep 1
systemctl start badvpn; sleep 2

echo ""
echo -e "${YL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CR}"
if systemctl is-active --quiet badvpn; then
    _ok "BadVPN activo en ${CY}127.0.0.1:$bvpn_port${CR}"
    echo ""
    echo -e "  ${YL}━━━ CÓMO USAR EN HTTP INJECTOR ━━━${CR}"
    echo -e "  ${DM}1. Conéctate primero por SSH${CR}"
    echo -e "  ${DM}2. Settings → UDP Custom → Enable${CR}"
    echo -e "  ${DM}3. UDP Custom Host: ${CR}${WH}127.0.0.1${CR}"
    echo -e "  ${DM}4. UDP Custom Port: ${CR}${CY}$bvpn_port${CR}"
    echo -e "  ${DM}   El tráfico de juegos/llamadas pasa por el túnel.${CR}"
else
    _err "BadVPN no arrancó."
    journalctl -u badvpn -n 10 --no-pager 2>/dev/null | sed 's/^/  /'
fi
echo -e "${YL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CR}"
sleep 2
