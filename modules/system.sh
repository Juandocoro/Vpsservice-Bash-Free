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

# ---------------------------------------------------------
# Copia de seguridad y vuelta atras de la configuracion de sshd.
# Un sshd_config roto no avisa hasta el reinicio, y entonces ya
# es tarde: SSH cae para TODOS los clientes y para el admin. Por
# eso cada cambio se hace sobre una copia y se valida antes.
# ---------------------------------------------------------
SSHD_SNAP="/var/lib/vpsservice/sshd-backup"

ssh_snapshot() {
    mkdir -p "$SSHD_SNAP" 2>/dev/null || return 0
    rm -rf "${SSHD_SNAP:?}/"* 2>/dev/null
    cp -p "$SSHD_CONF" "$SSHD_SNAP/sshd_config" 2>/dev/null
    [ -d /etc/ssh/sshd_config.d ] && cp -rp /etc/ssh/sshd_config.d "$SSHD_SNAP/" 2>/dev/null
    return 0
}

ssh_rollback() {
    [ -f "$SSHD_SNAP/sshd_config" ] || return 1
    cp -p "$SSHD_SNAP/sshd_config" "$SSHD_CONF"
    if [ -d "$SSHD_SNAP/sshd_config.d" ]; then
        rm -rf /etc/ssh/sshd_config.d
        cp -rp "$SSHD_SNAP/sshd_config.d" /etc/ssh/
    fi
}

# Huella de la configuracion efectiva: si no cambia, no hay que
# tocar el servicio.
ssh_conf_sum() {
    cat "$SSHD_CONF" /etc/ssh/sshd_config.d/*.conf 2>/dev/null | md5sum | cut -d' ' -f1
}

# Reinicia sshd SOLO si la configuracion es valida. Si no lo es,
# deshace el cambio y deja el servicio como estaba. Se usa reload:
# sshd se re-ejecuta y las sesiones abiertas no se tocan.
ssh_restart() {
    local err
    if command -v sshd &>/dev/null && ! err=$(sshd -t 2>&1); then
        echo -e "${UI_PAD:-  }${RD:-}[-]${CR:-} Configuracion SSH invalida: ${err}" >&2
        if ssh_rollback && sshd -t &>/dev/null; then
            echo -e "${UI_PAD:-  }${YL:-}[!]${CR:-} Se ha vuelto a la configuracion anterior. SSH sigue funcionando." >&2
        fi
        return 1
    fi
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || \
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
}

# =========================================================
# CONFIGURACION SSH PARA TUNELING
# Esta funcion es la unica fuente de verdad. Antes el mismo
# bloque estaba copiado en setup.sh, main.sh, users.sh y
# stunnel_installer.sh, con el riesgo de que se desincronizaran.
# =========================================================
ssh_apply_tunnel_config() {
    local new_user="${1:-}" before
    before=$(ssh_conf_sum)
    ssh_snapshot

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

    # CAPA 4 — drop-in propio, que gana sobre el resto. Se conservan
    # las lineas que ponen otras opciones del panel (Port, ListenAddress,
    # PermitRootLogin): reescribirlo a ciegas deshacia esos cambios.
    if [ -d /etc/ssh/sshd_config.d ]; then
        rm -f /etc/ssh/sshd_config.d/99-vpsservice.conf 2>/dev/null
        local keep
        keep=$(grep -E '^(Port|ListenAddress|PermitRootLogin) ' "$SSHD_DROPIN" 2>/dev/null)
        {
            cat <<'SSHEOF'
PasswordAuthentication yes
KbdInteractiveAuthentication yes
ChallengeResponseAuthentication yes
AllowTcpForwarding yes
GatewayPorts no
X11Forwarding no
# Sesiones fantasma: si el movil del cliente pierde la senal, sin
# esto la sesion sigue contando para su limite durante horas y el
# auto-killer le corta al reconectar. Asi se cierra en ~2 minutos.
ClientAliveInterval 30
ClientAliveCountMax 4
SSHEOF
            [ -n "$keep" ] && echo "$keep"
        } > "$SSHD_DROPIN"
    fi

    # Solo se recarga sshd si de verdad cambio algo. Antes se reiniciaba
    # en cada alta de cuenta sin motivo.
    [ "$(ssh_conf_sum)" != "$before" ] && ssh_restart
    return 0
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

    ssh_snapshot
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
    sed -i '/^PermitRootLogin/d' "$SSHD_DROPIN" 2>/dev/null
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

    ssh_snapshot
    ssh_set "$SSHD_CONF" "PermitRootLogin" "no"
    sed -i '/^PermitRootLogin/d' "$SSHD_DROPIN" 2>/dev/null
    ssh_restart
    ui_blank
    ui_ok "Login de root por SSH deshabilitado."
    ui_pause
}

# =========================================================
# PUERTO SSH
# ---------------------------------------------------------
# Stunnel (SSL) y el proxy WebSocket entregan el trafico de los
# clientes a 127.0.0.1:22. Si el puerto publico cambia y el 22
# deja de escuchar, todos esos clientes se caen a la vez. Por eso
# el 22 se mantiene SOLO en la interfaz local: los tuneles siguen
# funcionando y desde fuera el SSH ya solo entra por el puerto nuevo.
# =========================================================
_ssh_listen_lines() {
    local port="$1"
    [ -d /etc/ssh/sshd_config.d ] || return 0
    sed -i -E '/^(Port|ListenAddress) /d' "$SSHD_DROPIN" 2>/dev/null
    echo "Port $port" >> "$SSHD_DROPIN"
    if [ "$port" != "22" ]; then
        {
            echo "ListenAddress 0.0.0.0:${port}"
            # IPv6 solo si el sistema lo tiene: un bind fallido no tumba sshd,
            # pero ensucia el log en cada arranque.
            [ -f /proc/net/if_inet6 ] && echo "ListenAddress [::]:${port}"
            echo "ListenAddress 127.0.0.1:22"
        } >> "$SSHD_DROPIN"
    fi
}

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

    ssh_snapshot
    ssh_set "$SSHD_CONF" "Port" "$nuevo"
    _ssh_listen_lines "$nuevo"

    # Ubuntu 22.10+ arranca sshd por socket: sin esto el puerto no cambia.
    if systemctl is-enabled ssh.socket &>/dev/null; then
        mkdir -p /etc/systemd/system/ssh.socket.d
        if [ "$nuevo" = "22" ]; then
            printf '[Socket]\nListenStream=\nListenStream=22\n' \
                > /etc/systemd/system/ssh.socket.d/port.conf
        else
            printf '[Socket]\nListenStream=\nListenStream=%s\nListenStream=127.0.0.1:22\n' "$nuevo" \
                > /etc/systemd/system/ssh.socket.d/port.conf
        fi
        systemctl daemon-reload
        systemctl restart ssh.socket 2>/dev/null
    fi
    if ! ssh_restart; then
        ui_err "El cambio no se aplicó: SSH sigue en el puerto ${actual}."
        ui_pause; return
    fi

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
