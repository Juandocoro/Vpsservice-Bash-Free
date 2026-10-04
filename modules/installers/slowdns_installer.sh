#!/bin/bash
# =========================================================
# Instalador SlowDNS — SSH por DNS (protocolo dnstt)
# ---------------------------------------------------------
# Las apps "SlowDNS" (HTTP Custom, SocksIP, etc.) hablan dnstt:
# piden el dominio NS y una clave publica en hexadecimal.
# El instalador anterior clonaba github.com/riza/slowdns, un
# repositorio que NO existe: fallaba siempre en el primer paso.
# Ademas generaba claves RSA, que ningun cliente SlowDNS acepta.
# =========================================================
_INST_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$_INST_DIR/_common.sh"
inst_root

DIR_CONF=/etc/slowdns
BIN=/usr/local/bin/slowdns-server
UNIT=/etc/systemd/system/slowdns.service
DNSTT_REPO="https://www.bamsoftware.com/git/dnstt.git"

inst_header "SLOWDNS (dnstt)" "SSH a través de consultas DNS"
echo -e "${UI_PAD}${DM}Necesitas un dominio propio. En tu proveedor DNS crea:${CR}"
echo -e "${UI_PAD}${WH}  A   ns.tudominio.com  ->  IP de este VPS${CR}"
echo -e "${UI_PAD}${WH}  NS  t.tudominio.com   ->  ns.tudominio.com${CR}"
echo -e "${UI_PAD}${DM}El dominio del túnel es el del registro NS (t.tudominio.com).${CR}"
ui_blank

actual=$(grep -oE '[a-zA-Z0-9.-]+ 127\.0\.0\.1:[0-9]+' "$UNIT" 2>/dev/null | awk '{print $1}')
ui_prompt "Dominio NS del túnel${actual:+ (Enter = $actual)} (0 = cancelar)"
dominio="${REPLY_UI:-$actual}"
[ "$dominio" = "0" ] || [ -z "$dominio" ] && exit 0
if ! [[ "$dominio" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]; then
    ui_err "Eso no parece un dominio."; ui_pause; exit 1
fi

owner=$(inst_port_owner 5300 udp)
if [ -n "$owner" ] && [[ "$owner" != *slowdns* ]]; then
    ui_err "El puerto 5300/udp ya lo usa '$owner'."; ui_pause; exit 1
fi

# --- Go >= 1.21 (dnstt lo exige; Ubuntu 22.04 trae 1.18) ---
_go_ok() {
    local v; v=$("${1:-go}" version 2>/dev/null | grep -oE 'go1\.[0-9]+' | cut -d. -f2)
    [ -n "$v" ] && [ "$v" -ge 21 ]
}
GO=go
if ! _go_ok go; then
    if _go_ok /usr/local/go/bin/go; then
        GO=/usr/local/go/bin/go
    else
        ui_info "Instalando Go oficial (el del sistema es antiguo)..."
        ver=$(curl -s --max-time 15 'https://go.dev/VERSION?m=text' | head -1)
        arch=$(inst_arch)
        if [ -z "$ver" ] || ! curl -sL --max-time 300 "https://go.dev/dl/${ver}.linux-${arch}.tar.gz" -o /tmp/go.tgz; then
            ui_err "No se pudo descargar Go."; ui_pause; exit 1
        fi
        rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz && rm -f /tmp/go.tgz
        GO=/usr/local/go/bin/go
        _go_ok "$GO" || { ui_err "Go no quedó instalado."; ui_pause; exit 1; }
    fi
fi

ui_info "Compilando dnstt-server (1-2 minutos)..."
inst_apt git || true
src=$(mktemp -d)
# Clon completo: el servidor de dnstt no admite --depth.
if ! git clone -q "$DNSTT_REPO" "$src/dnstt" &>/dev/null; then
    rm -rf "$src"; ui_err "No se pudo descargar dnstt."; ui_pause; exit 1
fi
if ! (cd "$src/dnstt/dnstt-server" && "$GO" build -o "$BIN.new" . ) &>/dev/null; then
    rm -rf "$src"; ui_err "La compilación falló."; ui_pause; exit 1
fi
rm -rf "$src"
mv -f "$BIN.new" "$BIN"; chmod 755 "$BIN"

# Usuario sin privilegios: dnstt no necesita root (escucha en 5300 y el
# 53 se le redirige con iptables).
id slowdns &>/dev/null || useradd -r -s /usr/sbin/nologin -d "$DIR_CONF" slowdns
mkdir -p "$DIR_CONF"
if [ ! -s "$DIR_CONF/server.key" ]; then
    ui_info "Generando claves..."
    "$BIN" -gen-key -privkey-file "$DIR_CONF/server.key" -pubkey-file "$DIR_CONF/server.pub" &>/dev/null
fi
chown -R slowdns:slowdns "$DIR_CONF"; chmod 600 "$DIR_CONF/server.key"
PUB=$(tr -d '[:space:]' < "$DIR_CONF/server.pub" 2>/dev/null)

IFACE=$(ip route show default 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
REDIR="-i ${IFACE:-eth0} -p udp --dport 53 -j REDIRECT --to-ports 5300"

# La redireccion del 53 la pone y la quita el propio servicio: asi
# sobrevive a los reinicios sin iptables-persistent.
cat > "$UNIT" <<EOF
[Unit]
Description=SlowDNS (dnstt) para SSH
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=slowdns
ExecStartPre=+/bin/sh -c 'iptables -t nat -C PREROUTING $REDIR 2>/dev/null || iptables -t nat -I PREROUTING $REDIR'
ExecStart=$BIN -udp :5300 -privkey-file $DIR_CONF/server.key $dominio 127.0.0.1:22
ExecStopPost=+/bin/sh -c 'iptables -t nat -D PREROUTING $REDIR 2>/dev/null; true'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable slowdns &>/dev/null
systemctl restart slowdns &>/dev/null
inst_ufw_allow 53/udp 5300/udp
inst_mark slowdns
# Si UDP Custom esta instalado, su proteccion de puertos debe saber que
# el 53 es de SlowDNS.
systemctl is-active --quiet udp-custom && bash "$_INST_DIR/udp_installer.sh" --protect &>/dev/null

ui_blank
ui_solid
inst_check_service slowdns "SlowDNS"
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Dominio NS " "$dominio" 40)"
echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Clave pública" "" 14)"
echo "$PUB"
ui_rule
echo -e "${UI_PAD}${DM}En la app: SlowDNS / DNSTT, pega el dominio NS y la clave, y usa${CR}"
echo -e "${UI_PAD}${DM}como DNS un resolver público (8.8.8.8 o 1.1.1.1) con la cuenta SSH.${CR}"
ui_solid
ui_pause
