#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Error: Ejecutar como root."
  exit 1
fi

clear
echo "================================================="
echo "                  UDP CUSTOM                     "
echo "================================================="

read -p "¿Instalar UDP Custom? (s/n): " auth
if [[ "$auth" != "s" && "$auth" != "S" ]]; then
    exit 0
fi

echo "[*] Compilando..."
apt-get install -y cmake build-essential gcc &>/dev/null

cd /tmp
rm -rf badvpn
git clone https://github.com/ambrop72/badvpn.git &>/dev/null

cd badvpn
mkdir build
cd build
cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 &>/dev/null
make install &>/dev/null

if [ ! -f "/usr/local/bin/badvpn-udpgw" ]; then
    echo "[-] Error de compilación UDP."
    sleep 3
    exit 1
fi

read -p "¿Qué puerto asignar? (Defecto: 7300): " udp_port
if [ -z "$udp_port" ]; then
    udp_port=7300
fi

cat <<EOF > /etc/systemd/system/badvpn.service
[Unit]
Description=Protocolo Core UDP-Custom BadVPN (Túneles)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:$udp_port --max-clients 500 --max-connections-for-client 10 --client-socket-sndbuf 10000 --client-socket-rcvbuf 10000
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable badvpn &>/dev/null
systemctl restart badvpn &>/dev/null

echo "================================================="
echo "[+] Protocolo instalado."
echo "================================================="
sleep 2
