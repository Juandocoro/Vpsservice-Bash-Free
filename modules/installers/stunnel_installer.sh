#!/bin/bash

# Lenguaje visual compartido del panel
_INST_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$_INST_DIR/../ui.sh"
# Módulo Instalador Stunnel

instalar_stunnel_service() {
    clear
    ui_header "FREE · INSTALADOR"
    ui_section "STUNNEL SSL" "SSH sobre TLS en el puerto 443"
    echo -e "${UI_PAD}${DM}Stunnel4 y Dropbear ya fueron instalados silenciosamente.${CR}"
    echo -e "${UI_PAD}${DM}Esta fase genera el certificado SSL y monta el proxy${CR}"
    echo -e "${UI_PAD}${DM}en el puerto 443 apuntando a SSH (22).${CR}"
    echo ""
    ui_prompt "¿Deseas configurar y levantar el túnel AHORA? (s/n)"; confirm="$REPLY_UI"
    if [[ "$confirm" != "s" && "$confirm" != "S" ]]; then return; fi

    ui_info "Generando certificado SSL TLS (10 años de validez)..."
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
        -subj "/C=US/ST=State/L=City/O=Injector/CN=localhost" \
        -keyout /etc/stunnel/stunnel.pem \
        -out /etc/stunnel/stunnel.pem 2>/dev/null

    chmod 600 /etc/stunnel/stunnel.pem

    ui_info "Escribiendo configuración /etc/stunnel/stunnel.conf..."
    cat <<EOF > /etc/stunnel/stunnel.conf
pid = /var/run/stunnel4.pid
cert = /etc/stunnel/stunnel.pem
client = no
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[ssh-tls]
accept = 443
connect = 127.0.0.1:22
EOF

    ui_info "Configurando SSH para autenticación por túnel SSL..."
    SSHD_CONF="/etc/ssh/sshd_config"

    _ssh_set() {
        local file="$1" key="$2" val="$3"
        if grep -qE "^#?\s*${key}" "$file" 2>/dev/null; then
            sed -i -E "s|^#?\s*${key}.*|${key} ${val}|g" "$file"
        else
            echo "${key} ${val}" >> "$file"
        fi
    }

    # CAPA 1 — sshd_config principal
    _ssh_set "$SSHD_CONF" "UsePAM"                       "yes"
    _ssh_set "$SSHD_CONF" "KbdInteractiveAuthentication"  "yes"
    _ssh_set "$SSHD_CONF" "ChallengeResponseAuthentication" "yes"
    _ssh_set "$SSHD_CONF" "PasswordAuthentication"        "yes"
    _ssh_set "$SSHD_CONF" "PermitEmptyPasswords"          "no"
    # FIX: necesario para HTTP Injector y tuneles SSH por Stunnel SSL
    _ssh_set "$SSHD_CONF" "AllowTcpForwarding"            "yes"
    _ssh_set "$SSHD_CONF" "GatewayPorts"                 "no"

    # CAPA 2 — neutralizar overrides en sshd_config.d/ (Ubuntu Cloud/VPS los activa)
    if [ -d /etc/ssh/sshd_config.d ]; then
        for f in /etc/ssh/sshd_config.d/*.conf; do
            [ -f "$f" ] || continue
            sed -i -E 's|^#?\s*PasswordAuthentication.*|PasswordAuthentication yes|g' "$f"
            sed -i -E 's|^#?\s*KbdInteractiveAuthentication.*|KbdInteractiveAuthentication yes|g' "$f"
            sed -i -E 's|^#?\s*ChallengeResponseAuthentication.*|ChallengeResponseAuthentication yes|g' "$f"
        done
    fi

    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null

    ui_info "Montando puertos en el sistema y arrancando el servicio..."
    sed -i 's/ENABLED=0/ENABLED=1/' /etc/default/stunnel4 2>/dev/null
    systemctl enable stunnel4
    systemctl restart stunnel4

    echo ""
    ui_solid
    if systemctl is-active --quiet stunnel4; then
        ui_ok "Túnel SSL montado correctamente."
    else
        ui_err "Stunnel no arrancó. Revisa: journalctl -u stunnel4"
    fi
    echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Escuchando en" "443/TCP" 34 "$CY")"
    echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Redirige a   " "127.0.0.1:22" 34 "$CY")"
    ui_solid
    ui_pause
}

instalar_stunnel_service
