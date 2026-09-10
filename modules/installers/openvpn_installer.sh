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
ui_section "OPENVPN"
echo -e "${UI_PAD}${DM}OpenVPN es el protocolo VPN más maduro y portable.${CR}"
echo -e "${UI_PAD}${DM}Genera un archivo .ovpn listo para el cliente.${CR}"
echo ""

ui_prompt "¿Instalar OpenVPN? (s/n)"; auth="$REPLY_UI"
if [[ "$auth" != "s" && "$auth" != "S" ]]; then exit 0; fi

ui_prompt "Puerto OpenVPN (Defecto: 1194)"; ovpn_port="$REPLY_UI"
if [ -z "$ovpn_port" ]; then ovpn_port=1194; fi

ui_prompt "Protocolo UDP o TCP [udp/tcp] (Defecto: udp)"; ovpn_proto="$REPLY_UI"
if [ -z "$ovpn_proto" ]; then ovpn_proto="udp"; fi

SERVER_IP=$(curl -4 -s ifconfig.me)

ui_info "Instalando OpenVPN y Easy-RSA..."
apt-get install -yq openvpn easy-rsa &>/dev/null

ui_info "Inicializando PKI (infraestructura de claves)..."
EASYRSA_DIR="/etc/openvpn/easy-rsa"
mkdir -p "$EASYRSA_DIR"
cp -r /usr/share/easy-rsa/* "$EASYRSA_DIR/" 2>/dev/null

cd "$EASYRSA_DIR"
./easyrsa --batch init-pki &>/dev/null
./easyrsa --batch build-ca nopass &>/dev/null
./easyrsa --batch gen-req server nopass &>/dev/null
./easyrsa --batch sign-req server server &>/dev/null
./easyrsa --batch gen-dh &>/dev/null
openvpn --genkey --secret /etc/openvpn/ta.key &>/dev/null

# FIX: el perfil de cliente necesita su propio certificado firmado por la CA.
# Antes el instalador prometia un .ovpn que nunca generaba.
ui_info "Generando certificado del cliente..."
./easyrsa --batch gen-req client nopass &>/dev/null
./easyrsa --batch sign-req client client &>/dev/null

# FIX: el log de estado vive en /var/log/openvpn/ (la ruta que lee el monitor
# de conexiones en modules/users.sh). Antes se escribia en /var/log/ a secas
# y el contador de usuarios OpenVPN siempre daba cero.
STATUS_DIR="/var/log/openvpn"
mkdir -p "$STATUS_DIR"

ui_info "Escribiendo configuración del servidor..."
cat <<EOF > /etc/openvpn/server.conf
port $ovpn_port
proto $ovpn_proto
dev tun
ca $EASYRSA_DIR/pki/ca.crt
cert $EASYRSA_DIR/pki/issued/server.crt
key $EASYRSA_DIR/pki/private/server.key
dh $EASYRSA_DIR/pki/dh.pem
tls-auth /etc/openvpn/ta.key 0
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 8.8.4.4"
keepalive 10 120
cipher AES-256-CBC
persist-key
persist-tun
status $STATUS_DIR/openvpn-status.log
verb 0
EOF

# FIX: no duplicar la linea en sysctl.conf en cada reinstalacion.
ui_info "Activando IP forwarding..."
if ! grep -qE "^net\.ipv4\.ip_forward\s*=\s*1" /etc/sysctl.conf 2>/dev/null; then
    sed -i -E '/^#?\s*net\.ipv4\.ip_forward/d' /etc/sysctl.conf
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
sysctl -w net.ipv4.ip_forward=1 &>/dev/null
sysctl -p &>/dev/null

# FIX: sin NAT los clientes conectaban pero no tenian salida a internet.
# 'redirect-gateway' manda todo el trafico al VPS y alli moria.
ui_info "Configurando NAT para la red 10.8.0.0/24..."
NET_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
if [ -n "$NET_IFACE" ]; then
    iptables -t nat -C POSTROUTING -s 10.8.0.0/24 -o "$NET_IFACE" -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$NET_IFACE" -j MASQUERADE
    iptables -C FORWARD -i tun0 -o "$NET_IFACE" -j ACCEPT 2>/dev/null \
        || iptables -I FORWARD 1 -i tun0 -o "$NET_IFACE" -j ACCEPT
    iptables -C FORWARD -i "$NET_IFACE" -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
        || iptables -I FORWARD 1 -i "$NET_IFACE" -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT

    # Persistir las reglas para que sobrevivan al reinicio
    apt-get install -yq iptables-persistent &>/dev/null
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null
fi

# FIX: UFW descarta el trafico reenviado por defecto (DEFAULT_FORWARD_POLICY=DROP),
# lo que bloqueaba la VPN aunque el NAT estuviera bien puesto.
if [ -f /etc/default/ufw ]; then
    sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
    ufw reload &>/dev/null
fi

systemctl enable openvpn@server &>/dev/null
systemctl restart openvpn@server &>/dev/null

if command -v ufw &>/dev/null; then
    ufw allow "$ovpn_port"/"$ovpn_proto" &>/dev/null
fi

# FIX: generar el perfil .ovpn unificado que el banner prometia.
ui_info "Generando perfil de cliente .ovpn..."
CLIENT_FILE="/root/cliente-openvpn.ovpn"
cat <<EOF > "$CLIENT_FILE"
client
dev tun
proto $ovpn_proto
remote $SERVER_IP $ovpn_port
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-CBC
verb 0
key-direction 1
<ca>
$(cat "$EASYRSA_DIR/pki/ca.crt")
</ca>
<cert>
$(openssl x509 -in "$EASYRSA_DIR/pki/issued/client.crt" 2>/dev/null)
</cert>
<key>
$(cat "$EASYRSA_DIR/pki/private/client.key")
</key>
<tls-auth>
$(cat /etc/openvpn/ta.key)
</tls-auth>
EOF
chmod 600 "$CLIENT_FILE"

echo ""
ui_solid
if systemctl is-active --quiet openvpn@server; then
    ui_ok "OpenVPN activo."
else
    ui_err "OpenVPN NO arrancó. Revisa: journalctl -u openvpn@server"
fi
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Servidor" "$SERVER_IP" 34)"
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Puerto" "$ovpn_port/$ovpn_proto" 34)"
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Cifrado" "AES-256-CBC" 34)"
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Red VPN" "10.8.0.0/24" 34)"
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Perfil" "$CLIENT_FILE" 34)"
ui_solid
ui_warn "Descarga el perfil al móvil/PC con:"
echo "    scp root@$SERVER_IP:$CLIENT_FILE ."
ui_solid
ui_pause
