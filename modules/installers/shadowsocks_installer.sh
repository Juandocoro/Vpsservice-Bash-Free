#!/bin/bash
# Instalador Shadowsocks-libev — proxy cifrado
_INST_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$_INST_DIR/_common.sh"
inst_root

CONF=/etc/shadowsocks-libev/config.json

inst_header "SHADOWSOCKS" "proxy cifrado aes-256-gcm · TCP + UDP"
ui_blank

actual=$(grep '"server_port"' "$CONF" 2>/dev/null | grep -oE '[0-9]+')
inst_ask_port "Puerto para Shadowsocks" "${actual:-8388}" tcp ss-server || exit 0
ss_port="$INST_PORT"

# Antes, si se dejaba vacia, la clave era fija ("vpsservice2024") e
# igual en todos los VPS que usaran el panel: un proxy abierto para
# cualquiera que conociera el script. Ahora se genera una aleatoria.
ui_prompt "Contraseña (Enter = generar una segura)"
ss_pass="$REPLY_UI"
[ -z "$ss_pass" ] && ss_pass=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
ss_pass=${ss_pass//\"/}

ui_info "Instalando Shadowsocks-libev..."
inst_apt shadowsocks-libev || { ui_err "No se pudo instalar shadowsocks-libev."; ui_pause; exit 1; }

cat > "$CONF" <<EOF
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
chmod 640 "$CONF"

systemctl enable shadowsocks-libev &>/dev/null
systemctl restart shadowsocks-libev &>/dev/null
inst_ufw_allow "$ss_port/tcp" "$ss_port/udp"
inst_mark shadowsocks-libev

SERVER_IP=$(_public_ip)
# Enlace ss:// (SIP002): la mayoria de apps lo importan de un toque.
LINK="ss://$(printf '%s' "aes-256-gcm:${ss_pass}" | base64 -w0)@${SERVER_IP}:${ss_port}#VPSService"

ui_blank
ui_solid
inst_check_service shadowsocks-libev "Shadowsocks"
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Servidor" "$SERVER_IP" 34)"
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Puerto" "$ss_port" 34)"
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Cifrado" "aes-256-gcm" 34)"
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Password" "$ss_pass" 34)"
ui_rule
echo -e "${UI_PAD}${DM}Enlace para importar en la app:${CR}"
echo "$LINK"
ui_solid
ui_pause
