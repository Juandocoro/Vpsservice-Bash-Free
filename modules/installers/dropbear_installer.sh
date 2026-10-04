#!/bin/bash
# Instalador Dropbear — servidor SSH ligero en un puerto extra
_INST_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$_INST_DIR/_common.sh"
inst_root

inst_header "DROPBEAR SSH" "servidor SSH ligero en un puerto extra"
echo -e "${UI_PAD}${DM}Dropbear acepta las mismas cuentas que el panel. Útil como${CR}"
echo -e "${UI_PAD}${DM}puerto alternativo cuando el operador bloquea el de OpenSSH.${CR}"
ui_blank

actual=$(sed -n 's/^DROPBEAR_PORT=//p' /etc/default/dropbear 2>/dev/null | grep -oE '[0-9]+' | head -1)
inst_ask_port "Puerto para Dropbear" "${actual:-442}" tcp dropbear || exit 0
db_port="$INST_PORT"
[ "$db_port" = "22" ] && { ui_err "El 22 es de OpenSSH: elige otro."; sleep 2; exit 1; }

ui_info "Instalando Dropbear..."
inst_apt dropbear || { ui_err "No se pudo instalar dropbear."; ui_pause; exit 1; }

# El formato de /etc/default/dropbear cambia entre versiones de Ubuntu
# (NO_START existe en unas y no en otras), y con el de serie Dropbear
# intentaba arrancar en el 22, chocaba con OpenSSH y quedaba caido.
# Un override de systemd fija el arranque igual en todas.
ui_info "Configurando el puerto $db_port..."
touch /etc/default/dropbear
sed -i '/^DROPBEAR_PORT=/d; /^NO_START=/d' /etc/default/dropbear
printf 'DROPBEAR_PORT=%s\nNO_START=0\n' "$db_port" >> /etc/default/dropbear
mkdir -p /etc/systemd/system/dropbear.service.d
cat > /etc/systemd/system/dropbear.service.d/vpsservice.conf <<EOF
# Generado por VPSService: Dropbear en primer plano, en su puerto.
# -W 65536: ventana de recepcion mayor, mas caudal por tunel.
[Service]
Type=simple
ExecStart=
ExecStart=/usr/sbin/dropbear -EF -p ${db_port} -W 65536
Restart=always
RestartSec=3
EOF
systemctl daemon-reload
systemctl enable dropbear &>/dev/null
systemctl restart dropbear &>/dev/null
inst_ufw_allow "$db_port/tcp"
inst_mark dropbear

ui_blank
ui_solid
inst_check_service dropbear "Dropbear"
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Puerto" "$db_port/TCP" 34)"
ui_solid
ui_pause
