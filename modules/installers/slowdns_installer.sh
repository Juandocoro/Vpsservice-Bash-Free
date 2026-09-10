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
ui_section "SLOWDNS"
echo -e "${UI_PAD}${DM}SlowDNS permite tunelizar tráfico SSH a través${CR}"
echo -e "${UI_PAD}${DM}del protocolo DNS, util para bypasses de red.${CR}"
echo ""

ui_prompt "¿Instalar SlowDNS? (s/n)"; auth="$REPLY_UI"
if [[ "$auth" != "s" && "$auth" != "S" ]]; then exit 0; fi

ui_prompt "Tu dominio/subdominio DNS (ej: ns1.tudominio.com)"; dns_domain="$REPLY_UI"
if [ -z "$dns_domain" ]; then
    ui_err "Error: Se requiere un dominio NS."
    sleep 2; exit 1
fi

ui_prompt "IP pública del servidor (Enter para auto-detectar)"; server_ip="$REPLY_UI"
if [ -z "$server_ip" ]; then
    server_ip=$(curl -4 -s ifconfig.me)
fi

ui_info "Instalando dependencias..."
apt-get install -yq dnsutils golang git &>/dev/null

ui_info "Descargando SlowDNS..."
cd /tmp
rm -rf slowdns
git clone https://github.com/riza/slowdns.git &>/dev/null

if [ ! -d "/tmp/slowdns" ]; then
    ui_err "Error al clonar SlowDNS."
    sleep 2; exit 1
fi

cd /tmp/slowdns
ui_info "Compilando binarios..."
go build -o /usr/local/bin/slowdns-server ./server &>/dev/null

if [ ! -f "/usr/local/bin/slowdns-server" ]; then
    ui_err "Error de compilación. Verifica que Go esté instalado."
    sleep 2; exit 1
fi

ui_info "Generando par de claves RSA..."
mkdir -p /etc/slowdns
cd /etc/slowdns
if [ ! -f "server.key" ]; then
    openssl genrsa -out server.key 2048 &>/dev/null
    openssl rsa -in server.key -pubout -out server.pub &>/dev/null
fi

PUBLIC_KEY=$(cat /etc/slowdns/server.pub | grep -v "PUBLIC KEY" | tr -d '\n')

ui_info "Registrando servicio systemd..."
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
ui_solid
ui_ok "SlowDNS Instalado y Activo."
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Servidor" "$server_ip:5300" 34)"
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Dominio NS" "$dns_domain" 34)"
echo "    Clave Pública:"
echo "    $PUBLIC_KEY" | cut -c1-50
ui_section "[!] Recuerda apuntar tu registro NS a: $server_ip"
ui_pause
