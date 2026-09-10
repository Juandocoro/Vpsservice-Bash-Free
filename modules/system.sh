#!/bin/bash
# =========================================================
# MODULO SISTEMA — Configuracion del VPS
# ---------------------------------------------------------
# Acceso root, puerto SSH, zona horaria, reinicio y la
# configuracion SSH compartida que antes estaba duplicada en
# cuatro archivos distintos.
# =========================================================

_SYS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$_SYS_DIR/ui.sh"

SSHD_CONF="/etc/ssh/sshd_config"
SSHD_DROPIN="/etc/ssh/sshd_config.d/10-vpsservice.conf"

# =========================================================
# HELPERS SSH
# =========================================================

# Fija una directiva en un archivo de configuracion de sshd.
ssh_set() {
    local file="$1" key="$2" val="$3"
    if grep -qE "^#?\s*${key}\b" "$file" 2>/dev/null; then
        sed -i -E "s|^#?\s*${key}\s.*|${key} ${val}|g" "$file"
    else
        echo "${key} ${val}" >> "$file"
    fi
}

ssh_restart() {
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
}

# =========================================================
# CONFIGURACION SSH PARA TUNELING
# Esta funcion es la unica fuente de verdad. Antes el mismo
# bloque estaba copiado en setup.sh, main.sh, users.sh y
# stunnel_installer.sh, con el riesgo de que se desincronizaran.
# =========================================================
ssh_apply_tunnel_config() {
    local new_user="${1:-}"

    # CAPA 1 — sshd_config principal
    ssh_set "$SSHD_CONF" "UsePAM"                          "yes"
    ssh_set "$SSHD_CONF" "PasswordAuthentication"          "yes"
    ssh_set "$SSHD_CONF" "KbdInteractiveAuthentication"    "yes"   # Ubuntu 22+
    ssh_set "$SSHD_CONF" "ChallengeResponseAuthentication" "yes"   # Ubuntu 20
    ssh_set "$SSHD_CONF" "PermitEmptyPasswords"            "no"
    # AllowTcpForwarding es obligatorio para HTTP Injector: sin el, el usuario
    # se autentica pero el tunel cae justo despues del handshake.
    ssh_set "$SSHD_CONF" "AllowTcpForwarding"              "yes"
    ssh_set "$SSHD_CONF" "GatewayPorts"                    "no"
    ssh_set "$SSHD_CONF" "X11Forwarding"                   "no"

    # CAPA 2 — neutralizar los overrides que trae Ubuntu Cloud
    if [ -d /etc/ssh/sshd_config.d ]; then
        local f
        for f in /etc/ssh/sshd_config.d/*.conf; do
            [ -f "$f" ] || continue
            [ "$f" = "$SSHD_DROPIN" ] && continue
            sed -i -E 's|^#?\s*PasswordAuthentication.*|PasswordAuthentication yes|g' "$f"
            sed -i -E 's|^#?\s*KbdInteractiveAuthentication.*|KbdInteractiveAuthentication yes|g' "$f"
            sed -i -E 's|^#?\s*ChallengeResponseAuthentication.*|ChallengeResponseAuthentication yes|g' "$f"
        done
    fi

    # CAPA 3 — si hay lista blanca AllowUsers, incluir al usuario nuevo
    if [ -n "$new_user" ] && grep -qE "^AllowUsers" "$SSHD_CONF" 2>/dev/null; then
        if ! grep -qE "^AllowUsers.*\b${new_user}\b" "$SSHD_CONF"; then
            sed -i -E "s|^(AllowUsers.*)$|\1 ${new_user}|" "$SSHD_CONF"
        fi
    fi

    # CAPA 4 — drop-in propio, que gana sobre el resto
    if [ -d /etc/ssh/sshd_config.d ]; then
        rm -f /etc/ssh/sshd_config.d/99-vpsservice.conf 2>/dev/null
        cat > "$SSHD_DROPIN" <<'SSHEOF'
PasswordAuthentication yes
KbdInteractiveAuthentication yes
ChallengeResponseAuthentication yes
AllowTcpForwarding yes
GatewayPorts no
X11Forwarding no
SSHEOF
    fi

    ssh_restart
}

# =========================================================
# ACCESO ROOT
# =========================================================

# La cuenta root esta bloqueada cuando su hash empieza por '!' o '*'.
_root_locked() {
    local hash
    hash=$(getent shadow root 2>/dev/null | cut -d: -f2)
    [[ -z "$hash" || "$hash" == "!"* || "$hash" == "*"* ]]
}

_root_ssh_allowed() {
    local v
    v=$(sshd -T 2>/dev/null | grep -i '^permitrootlogin' | awk '{print $2}')
    [ "$v" = "yes" ]
}

root_access_menu() {
    while true; do
        clear
        print_title 2>/dev/null || true
        ui_section "ACCESO ROOT" "muchas imágenes cloud lo traen bloqueado"
        ui_blank

        local TAG_PASS TAG_SSH
        if _root_locked; then TAG_PASS="${RD}[ SIN CLAVE ]${CR}"; else TAG_PASS="${GR}[ CON CLAVE ]${CR}"; fi
        if _root_ssh_allowed; then TAG_SSH="$(ui_tag_str on)"; else TAG_SSH="$(ui_tag_str off)"; fi

        echo -e "${UI_PAD}$(ui_cell "Contraseña de root" "" 26)${TAG_PASS}"
        echo -e "${UI_PAD}$(ui_cell "Login root por SSH" "" 26)${TAG_SSH}"
        ui_rule
        ui_blank

        ui_opt "1" "HABILITAR ROOT"    "clave + SSH"
        ui_opt "2" "CAMBIAR CONTRASEÑA" "solo la clave"
        ui_opt "3" "BLOQUEAR ROOT"     "cerrar acceso"
        ui_blank
        ui_opt "0" "VOLVER"
        ui_solid
        ui_prompt "Elige una opción [0-3]"

        case "$REPLY_UI" in
            1) _root_enable ;;
            2) _root_passwd ;;
            3) _root_disable ;;
            0) break ;;
            *) ui_err "Opción inválida."; sleep 1 ;;
        esac
    done
}

_root_enable() {
    ui_blank
    ui_info "Se asignará una contraseña a root y se abrirá su login por SSH."
    ui_blank
    ui_prompt "Nueva contraseña para root"
    local pass="$REPLY_UI"
    if [ -z "$pass" ]; then ui_err "Contraseña vacía. Operación cancelada."; sleep 2; return; fi

    echo "root:$pass" | chpasswd
    # Un hash con prefijo '!' deja la cuenta bloqueada aunque tenga contraseña.
    passwd -u root &>/dev/null
    usermod -U root &>/dev/null

    ssh_set "$SSHD_CONF" "PermitRootLogin"        "yes"
    ssh_set "$SSHD_CONF" "PasswordAuthentication" "yes"

    # Las imágenes cloud desactivan root desde los drop-ins y desde una orden
    # forzada en authorized_keys; ambas hay que neutralizarlas.
    if [ -d /etc/ssh/sshd_config.d ]; then
        local f
        for f in /etc/ssh/sshd_config.d/*.conf; do
            [ -f "$f" ] || continue
            sed -i -E 's|^#?\s*PermitRootLogin.*|PermitRootLogin yes|g' "$f"
        done
    fi
    if [ -f /root/.ssh/authorized_keys ]; then
        sed -i 's|^.*command="echo .Please login as the user.*ssh-|ssh-|' /root/.ssh/authorized_keys
        sed -i 's|^no-port-forwarding,[^ ]* ||' /root/.ssh/authorized_keys
    fi
    echo "PermitRootLogin yes" >> "$SSHD_DROPIN" 2>/dev/null

    ssh_restart
    ui_blank
    if _root_ssh_allowed; then
        ui_ok "Root habilitado. Ya puedes entrar como ${WH}root${CR} con esa contraseña."
    else
        ui_warn "Contraseña asignada, pero sshd sigue rechazando el login de root."
        ui_info "Revisa: ${WH}sshd -T | grep permitrootlogin${CR}"
    fi
    ui_pause
}

_root_passwd() {
    ui_blank
    ui_prompt "Nueva contraseña para root"
    local pass="$REPLY_UI"
    if [ -z "$pass" ]; then ui_err "Contraseña vacía. Operación cancelada."; sleep 2; return; fi
    echo "root:$pass" | chpasswd
    passwd -u root &>/dev/null
    ui_blank
    ui_ok "Contraseña de root actualizada."
    ui_pause
}

_root_disable() {
    ui_blank
    ui_warn "Se cerrará el login de root por SSH."
    ui_warn "Asegúrate de tener otro usuario con sudo antes de continuar."
    ui_blank
    ui_prompt "¿Continuar? (s/n)"
    [[ "$REPLY_UI" != "s" && "$REPLY_UI" != "S" ]] && { ui_info "Cancelado."; sleep 1; return; }

    ssh_set "$SSHD_CONF" "PermitRootLogin" "no"
    sed -i '/^PermitRootLogin/d' "$SSHD_DROPIN" 2>/dev/null
    ssh_restart
    ui_blank
    ui_ok "Login de root por SSH deshabilitado."
    ui_pause
}

# =========================================================
# PUERTO SSH
# =========================================================
ssh_port_config() {
    clear
    print_title 2>/dev/null || true
    ui_section "PUERTO SSH" "el puerto por el que entra OpenSSH"
    ui_blank

    local actual
    actual=$(sshd -T 2>/dev/null | grep -i '^port ' | awk '{print $2}' | head -1)
    [ -z "$actual" ] && actual="22"
    echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Puerto actual" "$actual" 30 "$CY")"
    ui_blank
    ui_warn "Si cambias el puerto, tu sesión actual sigue viva, pero la próxima"
    ui_warn "conexión tendrá que usar el puerto nuevo. Se abrirá en UFW."
    ui_blank
    ui_prompt "Nuevo puerto (Enter = cancelar)"
    local nuevo="$REPLY_UI"
    [ -z "$nuevo" ] && { ui_info "Cancelado."; sleep 1; return; }
    if [[ ! "$nuevo" =~ ^[0-9]+$ ]] || [ "$nuevo" -lt 1 ] || [ "$nuevo" -gt 65535 ]; then
        ui_err "Puerto inválido (1-65535)."; sleep 2; return
    fi

    # Abrir el puerto ANTES de reiniciar sshd: si UFW lo bloquea despues del
    # cambio, la proxima conexion queda fuera y hay que entrar por consola.
    command -v ufw &>/dev/null && ufw allow "$nuevo"/tcp &>/dev/null

    ssh_set "$SSHD_CONF" "Port" "$nuevo"
    if [ -d /etc/ssh/sshd_config.d ]; then
        sed -i '/^Port /d' "$SSHD_DROPIN" 2>/dev/null
        echo "Port $nuevo" >> "$SSHD_DROPIN"
    fi
    # Ubuntu 22.10+ arranca sshd por socket: sin esto el puerto no cambia.
    if systemctl is-enabled ssh.socket &>/dev/null; then
        mkdir -p /etc/systemd/system/ssh.socket.d
        printf '[Socket]\nListenStream=\nListenStream=%s\n' "$nuevo" \
            > /etc/systemd/system/ssh.socket.d/port.conf
        systemctl daemon-reload
        systemctl restart ssh.socket 2>/dev/null
    fi
    ssh_restart

    ui_blank
    local ahora
    ahora=$(sshd -T 2>/dev/null | grep -i '^port ' | awk '{print $2}' | head -1)
    if [ "$ahora" = "$nuevo" ]; then
        ui_ok "SSH escuchando ahora en el puerto ${WH}$nuevo${CR}."
    else
        ui_err "El cambio no se aplicó (sshd sigue en ${ahora:-22})."
    fi
    ui_pause
}

# =========================================================
# ZONA HORARIA
# =========================================================
timezone_config() {
    clear
    print_title 2>/dev/null || true
    ui_section "ZONA HORARIA" "afecta a los logs y a la caducidad de cuentas"
    ui_blank
    echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Zona actual" "$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null)" 34 "$CY")"
    echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Hora local " "$(date '+%d/%m/%Y %H:%M:%S')" 34)"
    ui_blank
    ui_info "Ejemplos: America/Bogota · America/Mexico_City · Europe/Madrid"
    ui_blank
    ui_prompt "Nueva zona horaria (Enter = cancelar)"
    local tz="$REPLY_UI"
    [ -z "$tz" ] && { ui_info "Cancelado."; sleep 1; return; }

    if ! timedatectl list-timezones 2>/dev/null | grep -qx "$tz"; then
        ui_err "Zona horaria no reconocida: $tz"
        sleep 2; return
    fi
    timedatectl set-timezone "$tz" 2>/dev/null
    ui_blank
    ui_ok "Zona horaria: ${WH}$tz${CR} — $(date '+%d/%m/%Y %H:%M')"
    ui_pause
}

# =========================================================
# REINICIAR EL SERVIDOR
# =========================================================
reboot_vps() {
    clear
    print_title 2>/dev/null || true
    ui_section "REINICIAR EL SERVIDOR"
    ui_blank
    ui_warn "Se cerrarán todas las sesiones y túneles activos."
    ui_blank
    ui_prompt "Escribe REINICIAR para confirmar"
    if [ "$REPLY_UI" != "REINICIAR" ]; then
        ui_info "Cancelado."
        sleep 1; return
    fi
    ui_blank
    ui_ok "Reiniciando..."
    sleep 1
    reboot
}
