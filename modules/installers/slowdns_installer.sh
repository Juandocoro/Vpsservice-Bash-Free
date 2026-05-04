#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Error: Ejecutar como root."
  exit 1
fi

clear
echo "================================================="
echo "                  SLOWDNS                        "
echo "================================================="
echo "SlowDNS permite tunelizar tráfico SSH a través"
echo "del protocolo DNS, util para bypasses de red."
echo ""

read -p "¿Instalar SlowDNS? (s/n): " auth
if [[ "$auth" != "s" && "$auth" != "S" ]]; then exit 0; fi

read -p "Tu dominio/subdominio DNS (ej: ns1.tudominio.com): " dns_domain
if [ -z "$dns_domain" ]; then
    echo "[-] Error: Se requiere un dominio NS."
    sleep 2; exit 1
fi

read -p "IP pública del servidor (Enter para auto-detectar): " server_ip
if [ -z "$server_ip" ]; then
    server_ip=$(curl -s ifconfig.me)
fi

echo "[*] Instalando dependencias..."
apt-get install -yq dnsutils golang git &>/dev/null

echo "[*] Descargando SlowDNS..."
cd /tmp
rm -rf slowdns
git clone https://github.com/riza/slowdns.git &>/dev/null

if [ ! -d "/tmp/slowdns" ]; then
    echo "[-] Error al clonar SlowDNS."
    sleep 2; exit 1
fi

cd /tmp/slowdns
echo "[*] Compilando binarios..."
go build -o /usr/local/bin/slowdns-server ./server &>/dev/null

if [ ! -f "/usr/local/bin/slowdns-server" ]; then
    echo "[-] Error de compilación. Verifica que Go esté instalado."
    sleep 2; exit 1
fi

echo "[*] Generando par de claves RSA..."
mkdir -p /etc/slowdns
cd /etc/slowdns
if [ ! -f "server.key" ]; then
    openssl genrsa -out server.key 2048 &>/dev/null
    openssl rsa -in server.key -pubout -out server.pub &>/dev/null
fi

PUBLIC_KEY=$(cat /etc/slowdns/server.pub | grep -v "PUBLIC KEY" | tr -d '\n')

echo "[*] Registrando servicio systemd..."
cat <<EOF > /etc/systemd/system/slowdns.service
[Unit]
Description=SlowDNS Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/slowdns-server -server $server_ip:5300 -privateKey /etc/slowdns/server.key $dns_domain
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable slowdns &>/dev/null
systemctl restart slowdns &>/dev/null

if command -v ufw &>/dev/null; then
    ufw allow 5300/udp &>/dev/null
    ufw allow 53/udp &>/dev/null
fi

echo ""
echo "================================================="
echo "[+] SlowDNS Instalado y Activo."
echo "    Servidor: $server_ip:5300"
echo "    Dominio NS: $dns_domain"
echo "    Clave Pública:"
echo "    $PUBLIC_KEY" | cut -c1-50
echo "================================================="
echo "[!] Recuerda apuntar tu registro NS a: $server_ip"
echo "================================================="
        [ "$WEB_PANEL" = "1" ] && exit 0
read -p "Presiona Enter para volver..."
