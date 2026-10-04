#!/bin/bash
# Instalador BadVPN udpgw — UDP (juegos, llamadas) dentro del tunel SSH
_INST_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$_INST_DIR/_common.sh"
inst_root

BIN=/usr/local/bin/badvpn-udpgw
UNIT=/etc/systemd/system/badvpn.service

inst_header "BADVPN UDPGW" "UDP de juegos y llamadas por dentro del túnel SSH"
echo -e "${UI_PAD}${DM}Escucha solo en 127.0.0.1: el cliente lo usa a través de su${CR}"
echo -e "${UI_PAD}${DM}sesión SSH. No es un túnel por sí mismo.${CR}"
ui_blank

actual=$(grep -o '\-\-listen-addr [^ ]*' "$UNIT" 2>/dev/null | awk -F':' '{print $NF}')
inst_ask_port "Puerto local de BadVPN" "${actual:-7300}" tcp badvpn || exit 0
bvpn_port="$INST_PORT"

# Solo desde el codigo oficial. Antes se descargaba primero un binario
# precompilado de repositorios de terceros y se ejecutaba como root: quien
# controlara esos repos controlaba el VPS. Compilar tarda un minuto.
# Un binario que no compilo el panel (las versiones anteriores lo bajaban
# de terceros) se sustituye por el oficial.
if [ -x "$BIN" ] && [ -f "$BIN.oficial" ]; then
    ui_ok "Binario oficial ya compilado: se reutiliza."
else
    ui_info "Compilando BadVPN desde el código oficial (1-2 minutos)..."
    inst_apt cmake build-essential git file || { ui_err "No se pudieron instalar las herramientas de compilación."; ui_pause; exit 1; }
    src=$(mktemp -d)
    if git clone --depth 1 https://github.com/ambrop72/badvpn.git "$src/badvpn" &>/dev/null \
       && mkdir -p "$src/badvpn/build" && cd "$src/badvpn/build" \
       && cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 &>/dev/null \
       && make -j"$(nproc)" install &>/dev/null; then
        ui_ok "Compilado e instalado."
        touch "$BIN.oficial"
    fi
    cd / && rm -rf "$src"
    [ -f "$BIN.oficial" ] || { ui_err "La compilación falló: el servicio actual sigue como estaba."; ui_pause; exit 1; }
fi

cat > "$UNIT" <<EOF
[Unit]
Description=BadVPN UDP Gateway (para llamadas y juegos via SSH)
After=network.target

[Service]
Type=simple
User=root
ExecStart=$BIN --listen-addr 127.0.0.1:${bvpn_port} --max-clients 500 --max-connections-for-client 10 --client-socket-sndbuf 10000
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable badvpn &>/dev/null
systemctl restart badvpn &>/dev/null
inst_mark badvpn

ui_blank
ui_solid
if inst_check_service badvpn "BadVPN"; then
    echo -e "${UI_PAD}${DM}En la app: conecta por SSH y activa UDP Gateway con${CR}"
    echo -e "${UI_PAD}${WH}127.0.0.1:${bvpn_port}${CR}"
fi
ui_solid
ui_pause
