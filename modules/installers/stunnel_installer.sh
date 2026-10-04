#!/bin/bash
# Instalador Stunnel — SSH dentro de TLS
_INST_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$_INST_DIR/_common.sh"
source "$_INST_DIR/../system.sh"
inst_root

PEM=/etc/stunnel/stunnel.pem
CONF=/etc/stunnel/stunnel.conf

inst_header "STUNNEL SSL" "SSH dentro de TLS"
echo -e "${UI_PAD}${DM}El cliente habla TLS con este puerto y stunnel lo entrega${CR}"
echo -e "${UI_PAD}${DM}al SSH local (127.0.0.1:22).${CR}"
ui_blank

actual=$(grep -E '^\s*accept\s*=' "$CONF" 2>/dev/null | grep -oE '[0-9]+$')
inst_ask_port "Puerto TLS" "${actual:-443}" tcp stunnel || exit 0
ssl_port="$INST_PORT"

ui_info "Instalando stunnel..."
inst_apt stunnel4 openssl || { ui_err "No se pudo instalar stunnel4."; ui_pause; exit 1; }
mkdir -p /etc/stunnel

# El certificado solo se crea si no existe: rehacerlo en cada
# reinstalacion no aporta nada y rompe a los clientes que lo fijaron.
if [ ! -s "$PEM" ]; then
    ui_info "Generando certificado (10 años)..."
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
        -subj "/C=US/ST=State/L=City/O=Injector/CN=localhost" \
        -keyout "$PEM" -out "$PEM" 2>/dev/null
fi
chmod 600 "$PEM"

# Destino: el 22 local. Aunque se cambie el puerto publico de SSH, el
# panel deja siempre el 22 escuchando en 127.0.0.1 para esto.
cat > "$CONF" <<EOF
pid = /var/run/stunnel4.pid
cert = $PEM
client = no
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[ssh-tls]
accept = $ssl_port
connect = 127.0.0.1:22
EOF

ui_info "Configurando SSH para el túnel..."
ssh_apply_tunnel_config

sed -i 's/ENABLED=0/ENABLED=1/' /etc/default/stunnel4 2>/dev/null
systemctl enable stunnel4 &>/dev/null
systemctl restart stunnel4 &>/dev/null
inst_ufw_allow "$ssl_port/tcp"
inst_mark stunnel4

ui_blank
ui_solid
inst_check_service stunnel4 "Stunnel SSL"
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Escuchando en" "$ssl_port/TCP" 34 "$CY")"
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Entrega a    " "127.0.0.1:22" 34 "$CY")"
ui_solid
ui_pause
