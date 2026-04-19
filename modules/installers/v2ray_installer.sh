#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Error: Ejecutar como root."
  exit 1
fi

clear
echo "================================================="
echo "            V2RAY (VMess + WebSocket)            "
echo "================================================="
echo "V2Ray es un proxy moderno con enmascaramiento de"
echo "tráfico. Se configura con VMess sobre WebSocket."
echo ""

read -p "¿Instalar V2Ray? (s/n): " auth
if [[ "$auth" != "s" && "$auth" != "S" ]]; then exit 0; fi

read -p "Puerto WebSocket para V2Ray (Defecto: 8080): " v2_port
if [ -z "$v2_port" ]; then v2_port=8080; fi

V2_UUID=$(cat /proc/sys/kernel/random/uuid)

echo "[*] Instalando V2Ray..."
bash <(curl -sL https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh) &>/dev/null

if [ ! -f "/usr/local/bin/v2ray" ]; then
    echo "[-] Error al instalar V2Ray."
    sleep 2; exit 1
fi

echo "[*] Generando UUID: $V2_UUID"
echo "[*] Escribiendo configuración VMess+WS..."

mkdir -p /usr/local/etc/v2ray
cat <<EOF > /usr/local/etc/v2ray/config.json
{
  "log": {"loglevel": "none"},
  "inbounds": [
    {
      "port": $v2_port,
      "protocol": "vmess",
      "settings": {
        "clients": [{"id": "$V2_UUID", "alterId": 0}]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": "/v2ray"}
      }
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "settings": {}}
  ]
}
EOF

systemctl enable v2ray &>/dev/null
systemctl restart v2ray &>/dev/null

if command -v ufw &>/dev/null; then
    ufw allow "$v2_port"/tcp &>/dev/null
fi

SERVER_IP=$(curl -s ifconfig.me)

echo ""
echo "================================================="
echo "[+] V2Ray (VMess+WS) Activo."
echo "    Dirección : $SERVER_IP"
echo "    Puerto    : $v2_port"
echo "    UUID      : $V2_UUID"
echo "    Path WS   : /v2ray"
echo "    AlterID   : 0"
echo "    Seguridad : none (usa TLS externo)"
echo "================================================="
read -p "Presiona Enter para volver..."
