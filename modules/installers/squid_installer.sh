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

echo "[*] Instalando Squid..."
apt-get install -yq squid &>/dev/null

echo "[*] Escribiendo configuración /etc/squid/squid.conf..."
cat <<EOF > /etc/squid/squid.conf
# vpsservice Script FREE - Squid Config
http_port $squid_port

# ACL - Permitir acceso total
acl all src 0.0.0.0/0
http_access allow all

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
read -p "Presiona Enter para volver..."
