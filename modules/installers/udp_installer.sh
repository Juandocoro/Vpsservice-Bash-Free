#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Error: Ejecutar como root."
  exit 1
fi

# ─── Colores ──────────────────────────────────────────────────────────────────
CR="\033[0m"
GR="\033[1;32m"
RD="\033[0;31m"
YL="\033[0;33m"
CY="\033[1;36m"
WH="\033[1;37m"
DM="\033[2;37m"

_ok()   { echo -e "  ${GR}[+]${CR} $1"; }
_info() { echo -e "  ${YL}[*]${CR} $1"; }
_err()  { echo -e "  ${RD}[-]${CR} $1"; }

# ─── Cabecera ─────────────────────────────────────────────────────────────────
clear
echo -e "${YL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CR}"
echo -e "${WH}           UDP CUSTOM — BadVPN Gateway            ${CR}"
echo -e "${YL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CR}"
echo ""

read -p "$(echo -e ${DM})¿Instalar/Reparar UDP Custom? (s/n): $(echo -e ${CR})" auth
if [[ "$auth" != "s" && "$auth" != "S" ]]; then
    exit 0
fi

echo ""

# ─── PASO 1: Obtener el binario ───────────────────────────────────────────────
_info "Buscando binario de badvpn-udpgw..."

BINARY_SOURCES=(
    "https://raw.githubusercontent.com/daybreakersx/premscript/master/badvpn-udpgw64"
    "https://github.com/Kurosaki-io/BadVPN-UDPGateway/releases/download/1.0/badvpn-udpgw"
    "https://raw.githubusercontent.com/SaggyFunky/badvpn/master/badvpn-udpgw"
)

BINARY_OK=false

# Verificar si ya existe y funciona
if [ -f "/usr/local/bin/badvpn-udpgw" ] && file /usr/local/bin/badvpn-udpgw 2>/dev/null | grep -q "ELF"; then
    _ok "Binario ya existe y es válido. Saltando descarga."
    BINARY_OK=true
fi

# Intentar descargar de cada fuente
if [ "$BINARY_OK" = false ]; then
    for URL in "${BINARY_SOURCES[@]}"; do
        _info "Probando: $(echo $URL | awk -F'/' '{print $3}')"
        if wget -q --timeout=20 -O /tmp/badvpn-udpgw-tmp "$URL" 2>/dev/null; then
            if file /tmp/badvpn-udpgw-tmp 2>/dev/null | grep -q "ELF"; then
                mv /tmp/badvpn-udpgw-tmp /usr/local/bin/badvpn-udpgw
                chmod +x /usr/local/bin/badvpn-udpgw
                _ok "Binario descargado correctamente."
                BINARY_OK=true
                break
            else
                _err "El archivo descargado no es un binario válido. Probando siguiente..."
                rm -f /tmp/badvpn-udpgw-tmp
            fi
        else
            _err "No se pudo descargar desde esa fuente. Probando siguiente..."
        fi
    done
fi

# Fallback: compilar desde fuente
if [ "$BINARY_OK" = false ]; then
    _info "Todos los mirrors fallaron — compilando desde fuente..."
    _info "Instalando dependencias: cmake build-essential gcc git"

    if ! apt-get install -y cmake build-essential gcc git &>/dev/null; then
        _err "Error instalando dependencias de compilación."
        sleep 3; exit 1
    fi

    cd /tmp
    rm -rf badvpn
    _info "Clonando repositorio badvpn..."
    if ! git clone https://github.com/ambrop72/badvpn.git &>/dev/null; then
        _err "Error clonando repositorio. Verifica conexión a internet."
        sleep 3; exit 1
    fi

    cd badvpn && mkdir -p build && cd build
    _info "Compilando con cmake..."
    if ! cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 &>/dev/null; then
        _err "Error en cmake. Compilación fallida."
        sleep 3; exit 1
    fi
    if ! make install &>/dev/null; then
        _err "Error en make install. Compilación fallida."
        sleep 3; exit 1
    fi

    if file /usr/local/bin/badvpn-udpgw 2>/dev/null | grep -q "ELF"; then
        chmod +x /usr/local/bin/badvpn-udpgw
        _ok "Compilado e instalado correctamente."
        BINARY_OK=true
    fi
fi

# Verificación final del binario
if [ ! -f "/usr/local/bin/badvpn-udpgw" ] || ! file /usr/local/bin/badvpn-udpgw 2>/dev/null | grep -q "ELF"; then
    _err "No se pudo obtener el binario badvpn-udpgw por ningún método."
    sleep 3; exit 1
fi

# ─── PASO 2: Puerto ───────────────────────────────────────────────────────────
echo ""

# Detectar puerto existente si ya hay servicio instalado
CURRENT_PORT=$(grep -o '\-\-listen-addr [^ ]*' /etc/systemd/system/badvpn.service 2>/dev/null | awk -F':' '{print $NF}')
if [ -n "$CURRENT_PORT" ]; then
    _info "Puerto actual detectado: ${CY}$CURRENT_PORT${CR}"
    read -p "$(echo -e ${DM})Nuevo puerto (Enter para mantener $CURRENT_PORT): $(echo -e ${CR})" udp_port
    [ -z "$udp_port" ] && udp_port="$CURRENT_PORT"
else
    read -p "$(echo -e ${DM})Puerto para BadVPN (Defecto: 7300): $(echo -e ${CR})" udp_port
    [ -z "$udp_port" ] && udp_port=7300
fi

# Validar puerto
if ! [[ "$udp_port" =~ ^[0-9]+$ ]] || [ "$udp_port" -lt 1 ] || [ "$udp_port" -gt 65535 ]; then
    _err "Puerto inválido. Usando 7300."
    udp_port=7300
fi

# ─── PASO 3: Crear/actualizar servicio systemd ────────────────────────────────
_info "Escribiendo archivo de servicio systemd..."

cat > /etc/systemd/system/badvpn.service <<EOF
[Unit]
Description=BadVPN UDP Gateway (UDP-Custom Tunnel)
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:${udp_port} --max-clients 500 --max-connections-for-client 10 --client-socket-sndbuf 10000
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# ─── PASO 4: Registrar y arrancar en systemd ──────────────────────────────────
_info "Recargando daemon de systemd..."
systemctl daemon-reload

_info "Habilitando servicio para arranque automático..."
systemctl enable badvpn &>/dev/null

# Detener si ya corría
systemctl stop badvpn &>/dev/null
sleep 1

_info "Iniciando servicio badvpn..."
systemctl start badvpn
sleep 3

# ─── PASO 5: Verificación y diagnóstico automático ────────────────────────────
echo ""
echo -e "${YL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CR}"
echo -e "${WH}                 DIAGNÓSTICO                      ${CR}"
echo -e "${YL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CR}"

# Verificar systemd activo
if systemctl is-active --quiet badvpn; then
    _ok "Servicio badvpn: ${GR}ACTIVO${CR}"
else
    _err "Servicio badvpn: ${RD}INACTIVO${CR}"
    echo ""
    echo -e "  ${YL}--- Últimos logs del servicio ---${CR}"
    journalctl -u badvpn -n 15 --no-pager 2>/dev/null | sed 's/^/  /'
    echo ""
    echo -e "  ${YL}--- Estado de systemd ---${CR}"
    systemctl status badvpn --no-pager 2>/dev/null | sed 's/^/  /'
    echo ""
    _err "El servicio no arrancó. Revisa los logs arriba."
    sleep 5
    exit 1
fi

# Verificar que escucha en el puerto
LISTENING=$(ss -tlpnp 2>/dev/null | grep "badvpn" | awk '{print $4}')
if [ -n "$LISTENING" ]; then
    _ok "Escuchando en: ${CY}$LISTENING${CR}"
else
    # Fallback: checar por puerto directamente
    LISTENING=$(ss -tlpnp 2>/dev/null | grep ":${udp_port}")
    if [ -n "$LISTENING" ]; then
        _ok "Puerto ${CY}$udp_port${CR} en escucha."
    else
        _info "Nota: badvpn escucha en 127.0.0.1 (solo local, normal para gateway UDP)."
    fi
fi

# Firewall - abrir puerto si ufw está activo
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
    ufw allow "${udp_port}/udp" &>/dev/null
    ufw allow "${udp_port}/tcp" &>/dev/null
    _ok "Firewall UFW: puerto $udp_port abierto (TCP+UDP)."
fi

echo ""
echo -e "${YL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CR}"
echo -e "  ${GR}[✓] BadVPN UDP Gateway instalado correctamente.${CR}"
echo -e "  ${WH}Puerto:${CR}  ${CY}$udp_port${CR}"
echo -e "  ${WH}Acceso:${CR}  ${DM}127.0.0.1:$udp_port${CR}"
echo -e "${YL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CR}"
sleep 2
