#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Error: Ejecutar como root."
  exit 1
fi

clear
echo "================================================="
echo "               SHADOWSOCKS                       "
echo "================================================="
echo "Shadowsocks es un proxy cifrado SOCKS5 diseñado"
echo "para evadir censura y restricciones de red."
echo ""

read -p "¿Instalar Shadowsocks? (s/n): " auth
if [[ "$auth" != "s" && "$auth" != "S" ]]; then exit 0; fi

read -p "Puerto para Shadowsocks (Defecto: 8388): " ss_port
if [ -z "$ss_port" ]; then ss_port=8388; fi

read -s -p "Contraseña de cifrado: " ss_pass
echo ""
if [ -z "$ss_pass" ]; then ss_pass="vpsservice2024"; fi

echo "[*] Instalando Shadowsocks-libev..."
apt-get install -yq shadowsocks-libev &>/dev/null

echo "[*] Escribiendo configuración..."
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

SERVER_IP=$(curl -s ifconfig.me)

echo ""
echo "================================================="
echo "[+] Shadowsocks activo."
echo "    Servidor : $SERVER_IP"
echo "    Puerto   : $ss_port"
echo "    Cifrado  : aes-256-gcm"
echo "    Password : $ss_pass"
echo "    Modo     : TCP + UDP"
echo "================================================="
read -p "Presiona Enter para volver..."
