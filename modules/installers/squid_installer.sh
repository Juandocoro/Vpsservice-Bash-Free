#!/bin/bash
# Instalador Squid — proxy HTTP para entrar al SSH del VPS
_INST_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$_INST_DIR/_common.sh"
inst_root

inst_header "SQUID HTTP PROXY" "entrada por proxy HTTP hacia el SSH del VPS"
echo -e "${UI_PAD}${DM}Los inyectores HTTP se conectan a Squid y piden un CONNECT${CR}"
echo -e "${UI_PAD}${DM}hacia el SSH de este mismo servidor.${CR}"
ui_blank

actual=$(grep -E '^\s*http_port' /etc/squid/squid.conf 2>/dev/null | grep -oE '[0-9]+' | head -1)
inst_ask_port "Puerto para Squid" "${actual:-3128}" tcp squid || exit 0
squid_port="$INST_PORT"

ui_info "Instalando Squid..."
inst_apt squid || { ui_err "No se pudo instalar squid."; ui_pause; exit 1; }

# Destinos permitidos: SOLO este servidor. Antes era 'http_access
# allow all' sin contraseña: un proxy abierto a todo Internet. Los
# bots lo encuentran en horas, lo usan para spam y ataques, la IP
# acaba en listas negras o el proveedor suspende el VPS, y entonces
# se quedan sin servicio TODOS los clientes, no solo los de Squid.
local_ips="127.0.0.1"
for ip in $(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1) "$(_public_ip)"; do
    [[ "$ip" =~ ^[0-9.]+$ ]] && [[ " $local_ips " != *" $ip "* ]] && local_ips="$local_ips $ip"
done

ui_info "Escribiendo /etc/squid/squid.conf..."
cat > /etc/squid/squid.conf <<EOF
# VPSService - Squid: solo da paso hacia este mismo servidor.
http_port $squid_port

acl este_vps dst $local_ips

http_access allow este_vps
http_access deny all

visible_hostname vpsservice
cache deny all
access_log none
EOF

systemctl enable squid &>/dev/null
systemctl restart squid &>/dev/null
inst_ufw_allow "$squid_port/tcp"
inst_mark squid

ui_blank
ui_solid
inst_check_service squid "Squid"
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Puerto" "$squid_port/TCP" 34)"
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Destinos" "solo este VPS" 34)"
echo -e "${UI_PAD}${DM}Payload típico: CONNECT 127.0.0.1:22 HTTP/1.1${CR}"
ui_solid
ui_pause
