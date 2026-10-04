#!/bin/bash
# =========================================================
# UDP CUSTOM — tunel UDP directo de HTTP Custom
# ---------------------------------------------------------
# Lo que dice el binario oficial (http-custom/udp-custom),
# comprobado sobre el propio ejecutable:
#  · se arranca con 'udp-custom server' (el panel lo lanzaba
#    sin 'server' y no llegaba a escuchar);
#  · autentica por PAM, o sea con las CUENTAS DEL PANEL: la
#    lista de usuarios aparte que mantenia el panel no se usaba;
#  · el mismo pone la regla de iptables que le manda TODO el UDP
#    entrante (1-65535).
#
# Eso ultimo se llevaba por delante cualquier otro servicio UDP:
# los nodos WireGuard del gateway (51820+), WireGuard, OpenVPN,
# SlowDNS, Shadowsocks... Ademas el panel anadia otra regla igual
# por su cuenta. Ahora una cadena propia, colocada POR ENCIMA de la
# del binario, deja esos puertos fuera; el guardian la recoloca si
# hiciera falta.
# =========================================================
_INST_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$_INST_DIR/_common.sh"

UDP_DIR=/root/udp
BIN=$UDP_DIR/udp-custom
CONF=$UDP_DIR/config.json
EXTRA=$UDP_DIR/protegidos.conf          # puertos extra que el admin protege
UNIT=/etc/systemd/system/udp-custom.service
INTERNAL=36712
CHAIN=UDPC_PROTECT
BIN_URL="https://raw.githubusercontent.com/http-custom/udp-custom/main/bin/udp-custom-linux-amd64"

# ---------------------------------------------------------
# Puertos que UDP Custom NUNCA debe quedarse
# ---------------------------------------------------------
# Funcion pura sobre ficheros de config (se prueba sin root):
# imprime puertos o rangos "a:b", uno por linea.
_udpc_protected() {
    local etc="${1:-/etc}" f p
    echo "51820:51835"                                          # nodos del gateway (wg-home*)
    p=$(grep -E 'ListenPort' "$etc/wireguard/wg0.conf" 2>/dev/null | grep -oE '[0-9]+'); [ -n "$p" ] && echo "$p"
    if grep -qE '^proto udp' "$etc/openvpn/server.conf" 2>/dev/null || ! grep -qE '^proto ' "$etc/openvpn/server.conf" 2>/dev/null; then
        p=$(grep -E '^port ' "$etc/openvpn/server.conf" 2>/dev/null | awk '{print $2}'); [ -n "$p" ] && echo "$p"
    fi
    p=$(grep '"server_port"' "$etc/shadowsocks-libev/config.json" 2>/dev/null | grep -oE '[0-9]+'); [ -n "$p" ] && echo "$p"
    [ -f "$etc/systemd/system/slowdns.service" ] && echo "5300"
    for f in "$etc"/wireguard/wg-home*.conf; do
        [ -f "$f" ] || continue
        p=$(grep -E 'ListenPort' "$f" | grep -oE '[0-9]+'); [ -n "$p" ] && echo "$p"
    done
    grep -oE '^[0-9]+(:[0-9]+)?' "$EXTRA" 2>/dev/null
}

# Reglas de la cadena (funcion pura).
#   _udpc_rules <con_slowdns 0|1> <puertos...>
_udpc_rules() {
    local sdns="$1"; shift
    local p
    echo "-A $CHAIN -i lo -j ACCEPT"
    # El 53 solo se aparta si hay SlowDNS, y entonces se le entrega a el.
    # Sin SlowDNS se deja a UDP Custom: muchas cuentas usan el 53 porque
    # los operadores casi nunca lo bloquean.
    [ "$sdns" = "1" ] && echo "-A $CHAIN -p udp --dport 53 -j REDIRECT --to-ports 5300"
    for p in $(printf '%s\n' "$@" | sort -u); do
        echo "-A $CHAIN -p udp --dport $p -j ACCEPT"
    done
}

udpc_protect() {
    local r sdns=0
    systemctl is-enabled --quiet slowdns 2>/dev/null && sdns=1
    iptables -t nat -N "$CHAIN" 2>/dev/null
    iptables -t nat -F "$CHAIN"
    while IFS= read -r r; do
        # shellcheck disable=SC2086
        [ -n "$r" ] && iptables -t nat $r 2>/dev/null
    done < <(_udpc_rules "$sdns" $(_udpc_protected))
    # Siempre la PRIMERA de PREROUTING, por encima de la del binario.
    while iptables -t nat -D PREROUTING -j "$CHAIN" 2>/dev/null; do :; done
    iptables -t nat -I PREROUTING 1 -j "$CHAIN"
    # Restos de versiones anteriores del panel: su propia redireccion
    # (duplicada con la del binario) y sus RETURN de exclusion.
    while iptables -t nat -D PREROUTING -p udp -j REDIRECT --to-ports "$INTERNAL" 2>/dev/null; do :; done
    local old
    while old=$(iptables -t nat -S PREROUTING 2>/dev/null | grep -E '^-A PREROUTING -p udp -m udp --dport [0-9]+ -j RETURN$' | head -1) && [ -n "$old" ]; do
        # shellcheck disable=SC2086
        iptables -t nat ${old/-A /-D } 2>/dev/null || break
    done
}

# Para el guardian: barato si todo esta en su sitio.
udpc_protect_check() {
    systemctl is-active --quiet udp-custom 2>/dev/null || return 0
    local primera
    primera=$(iptables -t nat -S PREROUTING 2>/dev/null | sed -n 2p)
    [ "$primera" = "-A PREROUTING -j $CHAIN" ] && return 0
    udpc_protect
    logger -t vpsservice-guardian "UDP Custom: proteccion de puertos recolocada" 2>/dev/null
}

udpc_unprotect() {
    while iptables -t nat -D PREROUTING -j "$CHAIN" 2>/dev/null; do :; done
    iptables -t nat -F "$CHAIN" 2>/dev/null; iptables -t nat -X "$CHAIN" 2>/dev/null
}

# ---------------------------------------------------------
# Instalacion
# ---------------------------------------------------------
udpc_install() {
    inst_header "INSTALAR UDP CUSTOM" "túnel UDP directo · HTTP Custom"
    ui_blank
    if [ "$(inst_arch)" != "amd64" ]; then
        ui_err "UDP Custom solo publica binario para x86_64 y este VPS es $(uname -m)."
        ui_pause; return
    fi
    ui_info "Descargando el binario oficial (http-custom/udp-custom)..."
    mkdir -p "$UDP_DIR"
    if ! wget -q --timeout=60 -O "$BIN.new" "$BIN_URL" || ! file "$BIN.new" 2>/dev/null | grep -q ELF; then
        rm -f "$BIN.new"; ui_err "No se pudo descargar. Revisa la conexión del VPS."; ui_pause; return
    fi
    mv -f "$BIN.new" "$BIN"; chmod 755 "$BIN"

    # Configuracion oficial: autenticacion 'passwords' sin lista = PAM,
    # es decir, las cuentas que crea el panel.
    cat > "$CONF" <<EOF
{
  "listen": ":${INTERNAL}",
  "stream_buffer": 33554432,
  "receive_buffer": 83886080,
  "auth": {
    "mode": "passwords"
  }
}
EOF
    chmod 600 "$CONF"
    [ -f "$UDP_DIR/users.conf" ] && mv -f "$UDP_DIR/users.conf" "$UDP_DIR/users.conf.sin-uso"

    cat > "$UNIT" <<EOF
[Unit]
Description=UDP Custom (HTTP Custom)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$UDP_DIR
ExecStart=$BIN server
ExecStartPost=-/bin/bash -c 'sleep 3; bash $_INST_DIR/udp_installer.sh --protect'
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable udp-custom &>/dev/null
    systemctl restart udp-custom &>/dev/null
    inst_ufw_allow "$INTERNAL/udp"
    inst_mark udp-custom
    sleep 4
    udpc_protect

    ui_blank
    ui_solid
    inst_check_service udp-custom "UDP Custom"
    echo -e "${UI_PAD}${DM}Cuentas: las mismas del panel (usuario y contraseña SSH).${CR}"
    echo -e "${UI_PAD}${DM}En la app, casilla UDP Custom, con este formato:${CR}"
    echo -e "${UI_PAD}${WH}$(_public_ip):1-65535@usuario:contraseña${CR}"
    ui_solid
    ui_pause
}

udpc_ports_screen() {
    inst_header "PUERTOS PROTEGIDOS" "UDP que no se entrega a UDP Custom"
    ui_blank
    local p
    while IFS= read -r p; do echo -e "${UI_PAD}${GR}▪${CR} ${WH}${p/:/-}${CR}"; done < <(_udpc_protected | sort -u)
    systemctl is-enabled --quiet slowdns 2>/dev/null && echo -e "${UI_PAD}${GR}▪${CR} ${WH}53${CR} ${DM}-> SlowDNS${CR}"
    ui_blank
    echo -e "${UI_PAD}${DM}Se calculan solos a partir de lo instalado. Puedes añadir más${CR}"
    echo -e "${UI_PAD}${DM}(un puerto o rango a:b) o quitar uno tuyo escribiéndolo con '-'.${CR}"
    ui_prompt "Puerto a añadir / -puerto a quitar (Enter = volver)"
    p="$REPLY_UI"
    [ -z "$p" ] && return
    if [[ "$p" =~ ^-([0-9]+(:[0-9]+)?)$ ]]; then
        sed -i "/^${BASH_REMATCH[1]}\$/d" "$EXTRA" 2>/dev/null
    elif [[ "$p" =~ ^[0-9]+(:[0-9]+)?$ ]]; then
        echo "$p" >> "$EXTRA"
    else
        ui_err "Formato no válido."; sleep 2; return
    fi
    systemctl is-active --quiet udp-custom && udpc_protect
    ui_ok "Hecho."; sleep 1
}

udpc_uninstall() {
    ui_confirm "¿Desinstalar UDP Custom?" "n" || return
    systemctl disable --now udp-custom &>/dev/null
    rm -f "$UNIT"; systemctl daemon-reload
    # La regla del binario puede quedarse tras pararlo: se borra todo
    # lo que apunte a su puerto, o el UDP entrante iria a un puerto muerto.
    local r
    while r=$(iptables -t nat -S PREROUTING 2>/dev/null | grep -E "(--to-destination|--to-ports) [^ ]*${INTERNAL}" | head -1) && [ -n "$r" ]; do
        # shellcheck disable=SC2086
        iptables -t nat ${r/-A /-D } 2>/dev/null || break
    done
    udpc_unprotect
    rm -f "/var/lib/vpsservice/proto/udp-custom"
    ui_ok "UDP Custom desinstalado."; sleep 2
}

udpc_menu() {
    while true; do
        inst_header "UDP CUSTOM" "túnel UDP directo · cuentas del panel"
        ui_blank
        local est
        if systemctl is-active --quiet udp-custom 2>/dev/null; then est="${GR}[ ACTIVO ]${CR}"
        elif [ -f "$UNIT" ]; then est="${RD}[ CAÍDO ]${CR}"
        else est="${DM}[ NO INSTALADO ]${CR}"; fi
        echo -e "${UI_PAD}$(ui_cell "Estado" "" 10)${est}"
        echo -e "${UI_PAD}${DM}Formato en la app: ${WH}IP:1-65535@usuario:contraseña${CR}"
        ui_rule
        ui_blank
        ui_opt "1" "INSTALAR / REINSTALAR" "binario oficial"
        ui_opt "2" "PUERTOS PROTEGIDOS"    "no los toca"
        ui_opt "3" "REINICIAR"             ""
        ui_opt_danger "4" "DESINSTALAR"   ""
        ui_opt "0" "VOLVER"
        ui_solid
        ui_prompt "Elige una opción [0-4]"
        case "$REPLY_UI" in
            1) udpc_install ;;
            2) udpc_ports_screen ;;
            3) systemctl restart udp-custom &>/dev/null; inst_check_service udp-custom "UDP Custom"; sleep 2 ;;
            4) udpc_uninstall ;;
            0|"") break ;;
            *) ui_err "Opción no válida."; sleep 1 ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        --protect)       udpc_protect ;;
        --protect-check) udpc_protect_check ;;
        *)               inst_root; udpc_menu ;;
    esac
fi
