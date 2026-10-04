#!/bin/bash
# =========================================================
# Instalador WireGuard (wg0)
# ---------------------------------------------------------
# Antes: cada ejecucion regeneraba las claves del servidor (todos
# los clientes dejaban de conectar) y no creaba ningun cliente;
# solo decia "usa wg set...". Ahora las claves se conservan y cada
# ejecucion puede añadir un cliente con su .conf y su codigo QR.
# =========================================================
_INST_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$_INST_DIR/_common.sh"
inst_root

WG=/etc/wireguard
CONF=$WG/wg0.conf
NET=10.9.0

# Siguiente IP libre de la red de clientes (funcion pura sobre el conf).
_wg_next_ip() {
    local n
    for n in $(seq 2 254); do
        grep -q "AllowedIPs *= *${NET}\.${n}/32" "${1:-$CONF}" 2>/dev/null || { echo "${NET}.${n}"; return 0; }
    done
    return 1
}

wg_add_client() {
    local name ip priv pub psk file spub port host
    ui_blank
    ui_prompt "Nombre del cliente (ej: movil-juan) (Enter = cancelar)"
    name=$(echo "$REPLY_UI" | tr -cd 'A-Za-z0-9_-' | cut -c1-20)
    [ -z "$name" ] && return 1
    grep -q "^# cliente: ${name}$" "$CONF" && { ui_err "Ya existe ese cliente."; sleep 2; return 1; }
    ip=$(_wg_next_ip) || { ui_err "No quedan direcciones libres."; return 1; }
    priv=$(wg genkey); pub=$(echo "$priv" | wg pubkey); psk=$(wg genpsk)
    spub=$(cat "$WG/server_public.key"); port=$(awk -F'= *' '/ListenPort/{print $2}' "$CONF")
    host=$(_public_ip)

    cat >> "$CONF" <<EOF

[Peer]
# cliente: ${name}
PublicKey = ${pub}
PresharedKey = ${psk}
AllowedIPs = ${ip}/32
EOF
    # En caliente: los clientes conectados no se cortan.
    wg syncconf wg0 <(wg-quick strip wg0) 2>/dev/null || systemctl restart wg-quick@wg0

    file="/root/wg-${name}.conf"
    cat > "$file" <<EOF
[Interface]
PrivateKey = ${priv}
Address = ${ip}/32
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = ${spub}
PresharedKey = ${psk}
Endpoint = ${host}:${port}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
    chmod 600 "$file"
    ui_ok "Cliente '${name}' creado (${ip}). Archivo: ${file}"
    if command -v qrencode &>/dev/null; then
        echo -e "${UI_PAD}${DM}Escanéalo con la app de WireGuard:${CR}"
        qrencode -t ansiutf8 < "$file"
    fi
    return 0
}

wg_install() {
    inst_ask_port "Puerto para WireGuard" "$(awk -F'= *' '/ListenPort/{print $2}' "$CONF" 2>/dev/null | head -1 | grep . || echo 51820)" udp wg || return 1
    local port="$INST_PORT" iface
    ui_info "Instalando WireGuard..."
    inst_apt wireguard qrencode || inst_apt wireguard || { ui_err "No se pudo instalar WireGuard."; ui_pause; return 1; }
    mkdir -p "$WG"

    if [ ! -s "$WG/server_private.key" ]; then
        (umask 077; wg genkey > "$WG/server_private.key")
        wg pubkey < "$WG/server_private.key" > "$WG/server_public.key"
    else
        ui_ok "Se conservan las claves del servidor: los clientes siguen valiendo."
    fi
    iface=$(ip route show default | awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')

    # Se conservan los [Peer] existentes al reescribir la cabecera.
    local peers=""
    [ -f "$CONF" ] && peers=$(awk '/^\[Peer\]/{p=1} p' "$CONF")
    {
        echo "[Interface]"
        echo "Address = ${NET}.1/24"
        echo "ListenPort = $port"
        echo "PrivateKey = $(cat "$WG/server_private.key")"
        echo "PostUp = iptables -I FORWARD 1 -i wg0 -j ACCEPT; iptables -I FORWARD 1 -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -A POSTROUTING -s ${NET}.0/24 -o $iface -j MASQUERADE"
        echo "PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -D POSTROUTING -s ${NET}.0/24 -o $iface -j MASQUERADE"
        [ -n "$peers" ] && { echo; echo "$peers"; }
    } > "$CONF"
    chmod 600 "$CONF"

    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/90-vpsservice-forward.conf
    sysctl -w net.ipv4.ip_forward=1 &>/dev/null
    if [ -f /etc/default/ufw ] && grep -q '^DEFAULT_FORWARD_POLICY="DROP"' /etc/default/ufw; then
        sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
        ufw reload &>/dev/null
    fi

    systemctl enable wg-quick@wg0 &>/dev/null
    systemctl restart wg-quick@wg0 &>/dev/null
    inst_ufw_allow "$port/udp"
    inst_mark "wg-quick@wg0"
    inst_check_service wg-quick@wg0 "WireGuard"
}

while true; do
    inst_header "WIREGUARD VPN" "clientes con .conf y código QR"
    ui_blank
    if [ -f "$CONF" ]; then
        echo -e "${UI_PAD}$(ui_cell "Clientes" "$(grep -c '^# cliente:' "$CONF")" 20 "$CY")"
        echo -e "${UI_PAD}${DM}$(grep '^# cliente:' "$CONF" | cut -d: -f2 | paste -sd, -)${CR}"
        ui_rule
        ui_opt "1" "AÑADIR CLIENTE"        ".conf + QR"
        ui_opt "2" "REINSTALAR / PUERTO"   "conserva claves"
        ui_opt "0" "VOLVER"
        ui_solid
        ui_prompt "Elige una opción [0-2]"
        case "$REPLY_UI" in
            1) wg_add_client; ui_pause ;;
            2) wg_install; ui_pause ;;
            0|"") exit 0 ;;
        esac
    else
        wg_install && { ui_blank; ui_info "Crea ahora el primer cliente."; wg_add_client; }
        ui_pause
        exit 0
    fi
done
