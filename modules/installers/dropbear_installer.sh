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
ui_section "DROPBEAR SSH"
echo -e "${UI_PAD}${DM}Dropbear es un servidor SSH alternativo, ligero${CR}"
echo -e "${UI_PAD}${DM}y eficiente. Ideal para correr en puertos extra.${CR}"
echo ""

ui_prompt "¿Puerto para Dropbear (Enter = 442 · 0 = cancelar)"; db_port="$REPLY_UI"
[ "$db_port" = "0" ] && exit 0
[ -z "$db_port" ] && db_port=442

ui_info "Instalando Dropbear..."
apt-get install -yq dropbear &>/dev/null

ui_info "Configurando puerto $db_port..."
sed -i "s/^DROPBEAR_PORT=.*/DROPBEAR_PORT=$db_port/" /etc/default/dropbear 2>/dev/null
sed -i "s/^NO_START=.*/NO_START=0/" /etc/default/dropbear 2>/dev/null

# Si no existe la línea, la agregamos
if ! grep -q "^DROPBEAR_PORT" /etc/default/dropbear 2>/dev/null; then
    echo "DROPBEAR_PORT=$db_port" >> /etc/default/dropbear
    echo "NO_START=0" >> /etc/default/dropbear
fi

# Asegurarse que no colisione con OpenSSH
if [ "$db_port" == "22" ]; then
    ui_warn "Advertencia: El puerto 22 es usado por OpenSSH. Se recomienda usar otro."
fi

systemctl enable dropbear &>/dev/null
systemctl restart dropbear &>/dev/null

# Abrir en firewall si aplica
if command -v ufw &>/dev/null; then
    ufw allow "$db_port"/tcp &>/dev/null
fi

echo ""
ui_solid
ui_ok "Dropbear SSH instalado y activo."
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Puerto" "$db_port/TCP" 34)"
ui_solid
ui_pause
