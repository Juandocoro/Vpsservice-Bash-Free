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
ui_section "WIREGUARD VPN"
echo -e "${UI_PAD}${DM}WireGuard es el protocolo VPN más moderno,${CR}"
echo -e "${UI_PAD}${DM}rápido y seguro. Basado en UDP/criptografía ChaCha20.${CR}"
echo ""

ui_prompt "¿Instalar WireGuard? (s/n)"; auth="$REPLY_UI"
if [[ "$auth" != "s" && "$auth" != "S" ]]; then exit 0; fi

ui_prompt "Puerto para WireGuard (Defecto: 51820)"; wg_port="$REPLY_UI"
if [ -z "$wg_port" ]; then wg_port=51820; fi

ui_info "Instalando WireGuard..."
apt-get install -yq wireguard &>/dev/null

ui_info "Generando claves del servidor..."
wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
chmod 600 /etc/wireguard/server_private.key

SERVER_PRIVATE=$(cat /etc/wireguard/server_private.key)
SERVER_PUBLIC=$(cat /etc/wireguard/server_public.key)

# Detectar interfaz de red principal
NET_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)

ui_info "Configurando interfaz wg0..."
cat <<EOF > /etc/wireguard/wg0.conf
[Interface]
Address = 10.9.0.1/24
ListenPort = $wg_port
PrivateKey = $SERVER_PRIVATE
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $NET_IFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $NET_IFACE -j MASQUERADE
EOF

# FIX: no duplicar la linea en sysctl.conf en cada reinstalacion.
ui_info "Activando IP forwarding..."
if ! grep -qE "^net\.ipv4\.ip_forward\s*=\s*1" /etc/sysctl.conf 2>/dev/null; then
    sed -i -E '/^#?\s*net\.ipv4\.ip_forward/d' /etc/sysctl.conf
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
sysctl -w net.ipv4.ip_forward=1 &>/dev/null
sysctl -p &>/dev/null

# FIX: UFW descarta el trafico reenviado por defecto y bloqueaba la VPN.
if [ -f /etc/default/ufw ]; then
    sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
    ufw reload &>/dev/null
fi

systemctl enable wg-quick@wg0 &>/dev/null
systemctl restart wg-quick@wg0 &>/dev/null

if command -v ufw &>/dev/null; then
    ufw allow "$wg_port"/udp &>/dev/null
fi

SERVER_IP=$(curl -4 -s ifconfig.me)

echo ""
ui_solid
ui_ok "WireGuard activo."
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Servidor" "$SERVER_IP" 34)"
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Puerto" "$wg_port/UDP" 34)"
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Red VPN" "10.9.0.0/24" 34)"
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Clave Pública" "$SERVER_PUBLIC" 34)"
ui_section "[!] Para agregar clientes usa: wg set wg0 peer <PUB_KEY> allowed-ips 10.9.0.x/32"
ui_pause
