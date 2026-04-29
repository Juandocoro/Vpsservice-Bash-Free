#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Error: Ejecutar como root."
  exit 1
fi

clear
echo "================================================="
echo "                  OPENVPN                        "
echo "================================================="
echo "OpenVPN es el protocolo VPN más maduro y portable."
echo "Genera un archivo .ovpn listo para el cliente."
echo ""

read -p "¿Instalar OpenVPN? (s/n): " auth
if [[ "$auth" != "s" && "$auth" != "S" ]]; then exit 0; fi

read -p "Puerto OpenVPN (Defecto: 1194): " ovpn_port
if [ -z "$ovpn_port" ]; then ovpn_port=1194; fi

read -p "Protocolo UDP o TCP [udp/tcp] (Defecto: udp): " ovpn_proto
if [ -z "$ovpn_proto" ]; then ovpn_proto="udp"; fi

SERVER_IP=$(curl -s ifconfig.me)

echo "[*] Instalando OpenVPN y Easy-RSA..."
apt-get install -yq openvpn easy-rsa &>/dev/null

echo "[*] Inicializando PKI (infraestructura de claves)..."
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

echo "[*] Escribiendo configuración del servidor..."
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
status /var/log/openvpn-status.log
verb 0
EOF

echo "[*] Activando IP forwarding..."
# Idempotente: solo agrega si no existe
if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
sysctl -p &>/dev/null

systemctl enable openvpn@server &>/dev/null
systemctl restart openvpn@server &>/dev/null

if command -v ufw &>/dev/null; then
    ufw allow "$ovpn_port"/"$ovpn_proto" &>/dev/null
fi

echo ""
echo "================================================="
echo "[+] OpenVPN activo."
echo "    Servidor : $SERVER_IP"
echo "    Puerto   : $ovpn_port/$ovpn_proto"
echo "    Cifrado  : AES-256-CBC"
echo "    Red VPN  : 10.8.0.0/24"
echo "================================================="
read -p "Presiona Enter para volver..."
