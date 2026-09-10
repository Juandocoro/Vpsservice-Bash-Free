#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Error: Ejecutar como root."
  exit 1
fi

# Lenguaje visual compartido del panel
_INST_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$_INST_DIR/../ui.sh"

clear

ui_header "FREE · INSTALADOR"
ui_section "SHADOWSOCKS"
echo -e "${UI_PAD}${DM}Shadowsocks es un proxy cifrado SOCKS5 diseñado${CR}"
echo -e "${UI_PAD}${DM}para evadir censura y restricciones de red.${CR}"
echo ""

ui_prompt "¿Instalar Shadowsocks? (s/n)"; auth="$REPLY_UI"
if [[ "$auth" != "s" && "$auth" != "S" ]]; then exit 0; fi

ui_prompt "Puerto para Shadowsocks (Defecto: 8388)"; ss_port="$REPLY_UI"
if [ -z "$ss_port" ]; then ss_port=8388; fi

read -s -p "Contraseña de cifrado: " ss_pass
echo ""
if [ -z "$ss_pass" ]; then ss_pass="vpsservice2024"; fi

ui_info "Instalando Shadowsocks-libev..."
apt-get install -yq shadowsocks-libev &>/dev/null

ui_info "Escribiendo configuración..."
cat <<EOF > /etc/shadowsocks-libev/config.json
{
    "server": "0.0.0.0",
    "server_port": $ss_port,
    "password": "$ss_pass",
    "timeout": 300,
    "method": "aes-256-gcm",
    "fast_open": false,
    "mode": "tcp_and_udp"
}
EOF

systemctl enable shadowsocks-libev &>/dev/null
systemctl restart shadowsocks-libev &>/dev/null

if command -v ufw &>/dev/null; then
    ufw allow "$ss_port"/tcp &>/dev/null
    ufw allow "$ss_port"/udp &>/dev/null
fi

SERVER_IP=$(curl -4 -s ifconfig.me)

echo ""
ui_solid
ui_ok "Shadowsocks activo."
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Servidor" "$SERVER_IP" 34)"
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Puerto" "$ss_port" 34)"
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Cifrado" "aes-256-gcm" 34)"
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Password" "$ss_pass" 34)"
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Modo" "TCP + UDP" 34)"
ui_solid
ui_pause
