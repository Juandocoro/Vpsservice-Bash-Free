#!/bin/bash
# =========================================================
# Instalador OpenVPN
# ---------------------------------------------------------
# Cambios respecto a la version anterior, y por que:
#  · Reinstalar ya no borra la PKI. 'init-pki --batch' creaba
#    una CA nueva y todos los .ovpn entregados dejaban de valer.
#  · Sin iptables-persistent: en Ubuntu entra en conflicto con
#    UFW (podia desinstalar el cortafuegos del panel) y su
#    pregunta interactiva, oculta, dejaba el instalador "colgado".
#    El NAT lo pone y lo quita el propio servicio.
#  · Usuario y contraseña = las CUENTAS DEL PANEL (PAM). Antes
#    bastaba el archivo: no caducaba nunca y el monitor no sabia
#    quien era quien. Un solo perfil sirve para todos.
#  · 'dh none' (curvas elipticas): sin generar parametros DH, que
#    en un VPS de un nucleo tardaba varios minutos.
# =========================================================
_INST_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$_INST_DIR/_common.sh"
inst_root

EASYRSA_DIR=/etc/openvpn/easy-rsa
CONF=/etc/openvpn/server.conf
NAT=/etc/openvpn/vpsservice-nat.sh
PROFILE=/root/cliente-openvpn.ovpn
STATUS_DIR=/var/log/openvpn

inst_header "OPENVPN" "perfil .ovpn + usuario y contraseña del panel"
ui_blank

act_port=$(awk '/^port /{print $2}' "$CONF" 2>/dev/null)
act_proto=$(awk '/^proto /{print $2}' "$CONF" 2>/dev/null)
while true; do
    ui_prompt "Protocolo udp o tcp (Enter = ${act_proto:-udp})"
    proto="${REPLY_UI:-${act_proto:-udp}}"
    [[ "$proto" == "udp" || "$proto" == "tcp" ]] && break
    ui_err "Escribe udp o tcp."
done
inst_ask_port "Puerto OpenVPN" "${act_port:-1194}" "$proto" openvpn || exit 0
port="$INST_PORT"

SERVER_IP=$(_public_ip)
[[ "$SERVER_IP" =~ ^[0-9.]+$ ]] || { ui_err "No se pudo averiguar la IP pública del VPS."; ui_pause; exit 1; }

ui_info "Instalando OpenVPN y Easy-RSA..."
inst_apt openvpn easy-rsa || { ui_err "No se pudo instalar OpenVPN."; ui_pause; exit 1; }

# --- PKI: se reutiliza si existe ---
if [ -s "$EASYRSA_DIR/pki/ca.crt" ] && [ -s "$EASYRSA_DIR/pki/issued/server.crt" ]; then
    ui_ok "Se conserva la PKI existente: los perfiles entregados siguen valiendo."
else
    ui_info "Creando la PKI (CA y certificado del servidor)..."
    mkdir -p "$EASYRSA_DIR"
    cp -r /usr/share/easy-rsa/* "$EASYRSA_DIR/" 2>/dev/null
    (
        cd "$EASYRSA_DIR" || exit 1
        ./easyrsa --batch init-pki &>/dev/null
        ./easyrsa --batch build-ca nopass &>/dev/null
        ./easyrsa --batch gen-req server nopass &>/dev/null
        ./easyrsa --batch sign-req server server &>/dev/null
        ./easyrsa --batch gen-req client nopass &>/dev/null
        ./easyrsa --batch sign-req client client &>/dev/null
    )
    [ -s "$EASYRSA_DIR/pki/issued/server.crt" ] || { ui_err "No se pudo crear la PKI."; ui_pause; exit 1; }
fi
[ -s /etc/openvpn/ta.key ] || openvpn --genkey secret /etc/openvpn/ta.key &>/dev/null \
    || openvpn --genkey --secret /etc/openvpn/ta.key &>/dev/null

PAM_PLUGIN=$(find /usr/lib -name 'openvpn-plugin-auth-pam.so' 2>/dev/null | head -1)
mkdir -p "$STATUS_DIR"

cat > "$CONF" <<EOF
port $port
proto $proto
dev tun
ca $EASYRSA_DIR/pki/ca.crt
cert $EASYRSA_DIR/pki/issued/server.crt
key $EASYRSA_DIR/pki/private/server.key
dh none
tls-auth /etc/openvpn/ta.key 0
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
keepalive 10 120
cipher AES-256-CBC
persist-key
persist-tun
status $STATUS_DIR/openvpn-status.log 10
# Formato v2: lineas CLIENT_LIST, que es lo que lee el monitor del panel.
# Con el v1 por defecto el contador de OpenVPN daba siempre 0.
status-version 2
verb 1
EOF
if [ -n "$PAM_PLUGIN" ]; then
    cat >> "$CONF" <<EOF
# Cuentas del panel: caducidad incluida. El nombre de usuario pasa a
# ser el del certificado, asi el monitor de conexiones lo muestra.
plugin $PAM_PLUGIN login
username-as-common-name
duplicate-cn
EOF
fi

# --- NAT gestionado por el propio servicio ---
cat > "$NAT" <<'EOF'
#!/bin/sh
# NAT de OpenVPN (VPSService). Lo llama systemd al arrancar y al parar.
IF=$(ip route show default | awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
A="-s 10.8.0.0/24 -o $IF -j MASQUERADE"
if [ "$1" = "up" ]; then
    iptables -t nat -C POSTROUTING $A 2>/dev/null || iptables -t nat -A POSTROUTING $A
    iptables -C FORWARD -i tun0 -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i tun0 -j ACCEPT
    iptables -C FORWARD -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD 1 -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT
else
    iptables -t nat -D POSTROUTING $A 2>/dev/null
    iptables -D FORWARD -i tun0 -j ACCEPT 2>/dev/null
    iptables -D FORWARD -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
fi
exit 0
EOF
chmod 755 "$NAT"
mkdir -p /etc/systemd/system/openvpn@server.service.d
cat > /etc/systemd/system/openvpn@server.service.d/vpsservice.conf <<EOF
[Service]
ExecStartPost=$NAT up
ExecStopPost=$NAT down
Restart=always
RestartSec=5
EOF

# Forwarding persistente sin tocar sysctl.conf a ciegas
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/90-vpsservice-forward.conf
sysctl -w net.ipv4.ip_forward=1 &>/dev/null
if [ -f /etc/default/ufw ] && grep -q '^DEFAULT_FORWARD_POLICY="DROP"' /etc/default/ufw; then
    sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
    ufw reload &>/dev/null
fi

systemctl daemon-reload
systemctl enable openvpn@server &>/dev/null
systemctl restart openvpn@server &>/dev/null
inst_ufw_allow "$port/$proto"
inst_mark "openvpn@server"

# --- Perfil unico ---
{
    echo "client"
    echo "dev tun"
    echo "proto $proto"
    echo "remote $SERVER_IP $port"
    echo "resolv-retry infinite"
    echo "nobind"
    echo "persist-key"
    echo "persist-tun"
    echo "remote-cert-tls server"
    echo "cipher AES-256-CBC"
    echo "verb 1"
    echo "key-direction 1"
    [ -n "$PAM_PLUGIN" ] && echo "auth-user-pass"
    echo "<ca>"; cat "$EASYRSA_DIR/pki/ca.crt"; echo "</ca>"
    echo "<cert>"; openssl x509 -in "$EASYRSA_DIR/pki/issued/client.crt" 2>/dev/null; echo "</cert>"
    echo "<key>"; cat "$EASYRSA_DIR/pki/private/client.key"; echo "</key>"
    echo "<tls-auth>"; cat /etc/openvpn/ta.key; echo "</tls-auth>"
} > "$PROFILE"
chmod 600 "$PROFILE"

ui_blank
ui_solid
inst_check_service openvpn@server "OpenVPN"
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Servidor" "$SERVER_IP" 34)"
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Puerto" "$port/$proto" 34)"
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Perfil" "$PROFILE" 34)"
if [ -n "$PAM_PLUGIN" ]; then
    echo -e "${UI_PAD}${DM}Un mismo perfil para todos: cada cliente entra con su usuario y${CR}"
    echo -e "${UI_PAD}${DM}contraseña del panel, y deja de entrar cuando su cuenta vence.${CR}"
else
    ui_warn "No se encontró el plugin PAM: el perfil entra sin usuario ni contraseña."
fi
echo -e "${UI_PAD}${DM}Descárgalo con: ${WH}scp root@${SERVER_IP}:${PROFILE} .${CR}"
ui_solid
ui_pause
