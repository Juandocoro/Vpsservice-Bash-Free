#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Error: Ejecutar como root."
  exit 1
fi

clear
echo "================================================="
echo "              SQUID HTTP PROXY                   "
echo "================================================="
echo "Squid es un proxy HTTP/HTTPS de alto rendimiento."
echo "Permite a los clientes navegar a través del VPS."
echo ""

read -p "¿Instalar Squid? (s/n): " auth
if [[ "$auth" != "s" && "$auth" != "S" ]]; then exit 0; fi

read -p "Puerto para Squid (Defecto: 3128): " squid_port
if [ -z "$squid_port" ]; then squid_port=3128; fi

# Validar puerto
if ! [[ "$squid_port" =~ ^[0-9]+$ ]] || [ "$squid_port" -lt 1 ] || [ "$squid_port" -gt 65535 ]; then
    echo "[-] Puerto inválido. Usando 3128."
    squid_port=3128
fi

echo "[*] Instalando Squid..."
apt-get install -yq squid &>/dev/null

echo "[*] Escribiendo configuración /etc/squid/squid.conf..."
cat <<EOF > /etc/squid/squid.conf
# vpsservice Script FREE - Squid Config (HARDENED)
http_port $squid_port

# ACL - Restringir acceso solo a localhost y VPS propias
acl localhost src 127.0.0.1/32 ::1/128
acl localnet src 10.0.0.0/8
acl localnet src 172.16.0.0/12
acl localnet src 192.168.0.0/16
acl all src 0.0.0.0/0

# DENEGADO por defecto, permitido solo para red local
http_access deny all
http_access allow localhost
http_access allow localnet

# Respuesta de bienvenida (para inyectores HTTP)
visible_hostname vpsservice

# Rendimiento
cache deny all
dns_v4_first on

# Silenciar logs innecesarios
access_log none
cache_log /dev/null
EOF

systemctl enable squid &>/dev/null
systemctl restart squid &>/dev/null

if command -v ufw &>/dev/null; then
    ufw allow "$squid_port"/tcp &>/dev/null
fi

echo ""
echo "================================================="
echo "[+] Squid HTTP Proxy activo."
echo "    Puerto: $squid_port/TCP"
echo "    Acceso: Abierto (sin auth)"
echo "================================================="
        [ "$WEB_PANEL" = "1" ] && exit 0
read -p "Presiona Enter para volver..."
