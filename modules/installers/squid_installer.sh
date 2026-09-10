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
ui_section "SQUID HTTP PROXY"
echo -e "${UI_PAD}${DM}Squid es un proxy HTTP/HTTPS de alto rendimiento.${CR}"
echo -e "${UI_PAD}${DM}Permite a los clientes navegar a través del VPS.${CR}"
echo ""

ui_prompt "¿Instalar Squid? (s/n)"; auth="$REPLY_UI"
if [[ "$auth" != "s" && "$auth" != "S" ]]; then exit 0; fi

ui_prompt "Puerto para Squid (Defecto: 3128)"; squid_port="$REPLY_UI"
if [ -z "$squid_port" ]; then squid_port=3128; fi

ui_info "Instalando Squid..."
apt-get install -yq squid &>/dev/null

ui_info "Escribiendo configuración /etc/squid/squid.conf..."
cat <<EOF > /etc/squid/squid.conf
# vpsservice Script FREE - Squid Config
http_port $squid_port

# ACL - Permitir acceso total
# NOTA: 'all' es una ACL predefinida desde Squid 3.1. Redefinirla provoca
# un error fatal de parseo y el servicio no arranca, por eso solo se usa.
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
ui_solid
ui_ok "Squid HTTP Proxy activo."
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Puerto" "$squid_port/TCP" 34)"
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Acceso" "Abierto (sin auth)" 34)"
ui_solid
ui_pause
