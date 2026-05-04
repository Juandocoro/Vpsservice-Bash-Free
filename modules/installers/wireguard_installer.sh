#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Error: Ejecutar como root."
  exit 1
fi

clear
echo "================================================="
echo "                WIREGUARD VPN                    "
echo "================================================="
echo "WireGuard es el protocolo VPN más moderno,"
echo "rápido y seguro. Basado en UDP/criptografía ChaCha20."
echo ""

read -p "¿Instalar WireGuard? (s/n): " auth
if [[ "$auth" != "s" && "$auth" != "S" ]]; then exit 0; fi

read -p "Puerto para WireGuard (Defecto: 51820): " wg_port
if [ -z "$wg_port" ]; then wg_port=51820; fi

echo "[*] Instalando WireGuard..."
apt-get install -yq wireguard &>/dev/null

echo "[*] Generando claves del servidor..."
wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
chmod 600 /etc/wireguard/server_private.key

SERVER_PRIVATE=$(cat /etc/wireguard/server_private.key)
SERVER_PUBLIC=$(cat /etc/wireguard/server_public.key)

# Detectar interfaz de red principal
NET_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)

echo "[*] Configurando interfaz wg0..."
cat <<EOF > /etc/wireguard/wg0.conf
[Interface]
Address = 10.9.0.1/24
ListenPort = $wg_port
PrivateKey = $SERVER_PRIVATE
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $NET_IFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $NET_IFACE -j MASQUERADE
EOF

echo "[*] Activando IP forwarding..."
# Idempotente: solo agrega si no existe
if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
sysctl -p &>/dev/null

systemctl enable wg-quick@wg0 &>/dev/null
systemctl restart wg-quick@wg0 &>/dev/null

if command -v ufw &>/dev/null; then
    ufw allow "$wg_port"/udp &>/dev/null
fi

SERVER_IP=$(curl -s ifconfig.me)

echo ""
echo "================================================="
echo "[+] WireGuard activo."
echo "    Servidor     : $SERVER_IP"
echo "    Puerto       : $wg_port/UDP"
echo "    Red VPN      : 10.9.0.0/24"
echo "    Clave Pública: $SERVER_PUBLIC"
echo "================================================="
echo "[!] Para agregar clientes usa: wg set wg0 peer <PUB_KEY> allowed-ips 10.9.0.x/32"
echo "================================================="
        [ "$WEB_PANEL" = "1" ] && exit 0
read -p "Presiona Enter para volver..."
