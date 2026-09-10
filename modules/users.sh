#!/bin/bash
# Módulo de Usuarios — vpsservice Script FREE

# La paleta y los helpers de dibujo viven en modules/ui.sh
_USR_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$_USR_DIR/ui.sh"

DB_FILE="/root/.vps_users"

# =========================================================
# LISTADO BASE DE CUENTAS DEL PANEL
# =========================================================
_listar_cuentas() {
    awk -F':' '($3 >= 1000 && $3 != 65534 && $1 != "nobody" && $1 != "ubuntu") {print $1}' /etc/passwd
}

# Dias restantes de una cuenta. Devuelve un entero, o "inf" si no expira.
_dias_restantes() {
    local u="$1" exp_raw exp_sec
    # LANG=C fija el formato en ingles, independiente del locale del servidor
    exp_raw=$(LANG=C chage -l "$u" 2>/dev/null | grep "Account expires" | cut -d: -f2 | xargs)
    if [[ "$exp_raw" == "never" || -z "$exp_raw" ]]; then echo "inf"; return; fi
    exp_sec=$(date -d "$exp_raw" +%s 2>/dev/null)
    [ -z "$exp_sec" ] && { echo "?"; return; }
    echo $(( (exp_sec - $(date +%s)) / 86400 ))
}

# =========================================================
# CONTADORES PARA EL TABLERO (los consume modules/network.sh)
# =========================================================
contar_cuentas() {
    USR_ACTIVAS=0; USR_PORVENCER=0; USR_VENCIDAS=0; USR_TOTAL=0
    local u d
    # Sin pipe: un 'while read' al final de una tuberia corre en un subshell
    # y los contadores se perderian al terminar.
    while read -r u; do
        [ -z "$u" ] && continue
        USR_TOTAL=$(( USR_TOTAL + 1 ))
        d=$(_dias_restantes "$u")
        if   [ "$d" = "inf" ] || [ "$d" = "?" ]; then USR_ACTIVAS=$(( USR_ACTIVAS + 1 ))
        elif [ "$d" -lt 0 ];  then USR_VENCIDAS=$(( USR_VENCIDAS + 1 ))
        elif [ "$d" -le 3 ];  then USR_PORVENCER=$(( USR_PORVENCER + 1 ))
        else                       USR_ACTIVAS=$(( USR_ACTIVAS + 1 ))
        fi
    done < <(_listar_cuentas)
}

contar_online() {
    ON_SSH=0; ON_DROPBEAR=0; ON_OVPN=0
    local u
    while read -r u; do
        [ -z "$u" ] && continue
        ON_SSH=$(( ON_SSH + $(ps -u "$u" -o comm= 2>/dev/null | grep -c "^sshd$") ))
        ON_DROPBEAR=$(( ON_DROPBEAR + $(ps -u "$u" -o comm= 2>/dev/null | grep -c "^dropbear$") ))
    done < <(_listar_cuentas)

    local status
    status=$(_ovpn_status_file)
    if [ -n "$status" ]; then
        ON_OVPN=$(awk -F',' '/^CLIENT_LIST/ {c++} END {print c+0}' "$status" 2>/dev/null)
    fi
    ON_OVPN=${ON_OVPN:-0}
}

# La ruta del status log de OpenVPN varia segun quien instalo el servidor.
_ovpn_status_file() {
    local p
    for p in /var/log/openvpn/openvpn-status.log \
             /var/log/openvpn-status.log \
             /etc/openvpn/openvpn-status.log; do
        [ -f "$p" ] && { echo "$p"; return; }
    done
    echo ""
}

crear_usuario() {
    clear
    print_title 2>/dev/null || true
    ui_section "CREAR CUENTA NUEVA" "SSH · SSL · Dropbear"
    ui_blank

    ui_prompt "NOMBRE DE USUARIO"; USERNAME="$REPLY_UI"
    if [ -z "$USERNAME" ]; then ui_err "Nombre vacío."; sleep 1; return; fi
    if id "$USERNAME" &>/dev/null; then ui_err "El usuario ya existe."; sleep 1; return; fi

    read -s -p "$(echo -e "${UI_PAD}${DM}CONTRASEÑA ${CY}»${CR} ")" PASSWORD
    echo ""
    if [ -z "$PASSWORD" ]; then ui_err "Contraseña vacía."; sleep 1; return; fi

    ui_prompt "DURACIÓN (días)"; DAYS="$REPLY_UI"
    if [[ ! "$DAYS" =~ ^[0-9]+$ ]]; then ui_err "Formato numérico requerido."; sleep 1; return; fi

    ui_prompt "LÍMITE DE CONEXIONES"; LIMIT="$REPLY_UI"
    if [[ ! "$LIMIT" =~ ^[0-9]+$ ]]; then ui_err "Formato numérico requerido."; sleep 1; return; fi

    EXP_DATE=$(date -d "+$DAYS days" +%Y-%m-%d 2>/dev/null)
    SERVER_IP=$(_public_ip 2>/dev/null || curl -4 -s ifconfig.me 2>/dev/null || echo "N/A")

    ui_blank
    ui_info "Configurando SSH y creando la cuenta..."

    # ================================================================
    # FIX SSH — 4 capas para garantizar auth sin depender de
    # PasswordAuthentication (Ubuntu Cloud lo deshabilita por defecto)
    # ================================================================
    SSHD_CONF="/etc/ssh/sshd_config"

    # Helper: aplica una directiva en el archivo objetivo
    _ssh_set() {
        local file="$1" key="$2" val="$3"
        if grep -qE "^#?\s*${key}" "$file" 2>/dev/null; then
            sed -i -E "s|^#?\s*${key}.*|${key} ${val}|g" "$file"
        else
            echo "${key} ${val}" >> "$file"
        fi
    }

    # CAPA 1 — Parchar sshd_config principal
    _ssh_set "$SSHD_CONF" "UsePAM"                       "yes"
    _ssh_set "$SSHD_CONF" "KbdInteractiveAuthentication"  "yes"  # SSH moderno (Ubuntu 22+)
    _ssh_set "$SSHD_CONF" "ChallengeResponseAuthentication" "yes"  # SSH antiguo (Ubuntu 20)
    _ssh_set "$SSHD_CONF" "PasswordAuthentication"       "yes"
    _ssh_set "$SSHD_CONF" "PermitEmptyPasswords"         "no"
    # FIX: AllowTcpForwarding es REQUERIDO para HTTP Injector y cualquier tunel SSH.
    # Ubuntu 22+ Cloud lo deshabilita por defecto → los usuarios se autentican pero
    # no pueden crear el tunel (conexión cae inmediatamente después del handshake).
    _ssh_set "$SSHD_CONF" "AllowTcpForwarding"           "yes"
    _ssh_set "$SSHD_CONF" "GatewayPorts"                "no"
    _ssh_set "$SSHD_CONF" "X11Forwarding"               "no"

    # CAPA 2 — Neutralizar overrides en sshd_config.d/ (Ubuntu Cloud los pone aquí)
    # Cualquier archivo con PasswordAuthentication no o KbdInteractive no queda corregido
    if [ -d /etc/ssh/sshd_config.d ]; then
        for f in /etc/ssh/sshd_config.d/*.conf; do
            [ -f "$f" ] || continue
            sed -i -E 's|^#?\s*PasswordAuthentication.*|PasswordAuthentication yes|g' "$f"
            sed -i -E 's|^#?\s*KbdInteractiveAuthentication.*|KbdInteractiveAuthentication yes|g' "$f"
            sed -i -E 's|^#?\s*ChallengeResponseAuthentication.*|ChallengeResponseAuthentication yes|g' "$f"
        done
    fi

    # CAPA 3 — Si sshd tiene AllowUsers, agregar el usuario nuevo a la lista
    if grep -qE "^AllowUsers" "$SSHD_CONF" 2>/dev/null; then
        if ! grep -qE "^AllowUsers.*\b${USERNAME}\b" "$SSHD_CONF"; then
            sed -i -E "s|^(AllowUsers.*)$|\1 ${USERNAME}|" "$SSHD_CONF"
        fi
    fi

    # CAPA EXTRA — Drop-in que garantiza auth por contraseña Y forwarding para HTTP Injector
    if [ -d /etc/ssh/sshd_config.d ]; then
        rm -f /etc/ssh/sshd_config.d/99-vpsservice.conf 2>/dev/null
        cat > /etc/ssh/sshd_config.d/10-vpsservice.conf <<'SSHEOF'
PasswordAuthentication yes
KbdInteractiveAuthentication yes
ChallengeResponseAuthentication yes
AllowTcpForwarding yes
GatewayPorts no
X11Forwarding no
SSHEOF
    fi

    # Reiniciar sshd (restart garantiza que apliquen los cambios, no corta sesiones activas)
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null

    # Crear usuario sistema
    useradd -m -s /bin/bash -e "$EXP_DATE" -c "$LIMIT" "$USERNAME"
    echo "$USERNAME:$PASSWORD" | chpasswd

    # CAPA 4 — Desbloqueo forzado de la cuenta (passwd -u quita el prefijo ! del hash)
    passwd -u "$USERNAME" 2>/dev/null
    usermod -U "$USERNAME" 2>/dev/null

    # Log plano seguro
    touch "$DB_FILE"
    chmod 600 "$DB_FILE"
    sed -i "/^$USERNAME:/d" "$DB_FILE" 2>/dev/null
    echo "$USERNAME:$PASSWORD" >> "$DB_FILE"

    clear
    print_title 2>/dev/null || true
    ui_section "CUENTA ACTIVADA" "$USERNAME"
    ui_blank
    echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Servidor" "$SERVER_IP" 30 "$GR")"
    echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Usuario " "$USERNAME" 30)"
    echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Password" "$PASSWORD" 30)"
    echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Vence   " "$EXP_DATE ($DAYS días)" 30 "$YL")"
    echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Límite  " "$LIMIT dispositivo(s)" 30 "$CY")"
    ui_blank
    ui_solid
    ui_pause
}

# =========================================================
# TABLA DE USUARIOS — reutilizable por todas las acciones
# =========================================================
_tabla_usuarios() {
    ui_blank
    printf "${UI_PAD}${YL}%-3s %-14s %-12s %-11s %-6s %-7s %s${CR}\n" \
        "#" "USUARIO" "CLAVE" "VENCE" "DÍAS" "CONEX" "ESTADO"
    ui_rule

    local idx=0 u PASS EXP_RAW DIAS ESTADO LIMITE CONEX MARCA
    while read -r u; do
        [ -z "$u" ] && continue
        idx=$((idx + 1))

        PASS=$(grep "^$u:" "$DB_FILE" 2>/dev/null | cut -d: -f2)
        [ -z "$PASS" ] && PASS="—"

        EXP_RAW=$(LANG=C chage -l "$u" 2>/dev/null | grep "Account expires" | cut -d: -f2 | xargs)
        [ -z "$EXP_RAW" ] && EXP_RAW="never"

        DIAS=$(_dias_restantes "$u")
        case "$DIAS" in
            inf) DIAS="∞";  ESTADO="${GR}ACTIVO${CR}";     MARCA="${GR}▪${CR}" ;;
            \?)  DIAS="?";  ESTADO="${DM}DESCONOCIDO${CR}"; MARCA="${DM}▪${CR}" ;;
            *)
                if   [ "$DIAS" -lt 0 ]; then DIAS="0";   ESTADO="${RD}VENCIDO${CR}";    MARCA="${RD}▪${CR}"
                elif [ "$DIAS" -le 3 ]; then DIAS="${DIAS}d"; ESTADO="${YL}POR VENCER${CR}"; MARCA="${YL}▪${CR}"
                else                         DIAS="${DIAS}d"; ESTADO="${GR}ACTIVO${CR}";     MARCA="${GR}▪${CR}"
                fi ;;
        esac

        LIMITE=$(getent passwd "$u" | cut -d: -f5)
        [[ ! "$LIMITE" =~ ^[0-9]+$ ]] && LIMITE="1"
        CONEX=$(ps -u "$u" -o comm= 2>/dev/null | grep -cE "^(sshd|dropbear)$")

        printf "${UI_PAD}%b${CY}%-2s${CR} ${WH}%-14s${CR} ${DM}%-12s${CR} ${DM}%-11s${CR} ${CY}%-6s${CR} ${WH}%-7s${CR}" \
            "$MARCA" "$idx" "${u:0:14}" "${PASS:0:12}" "${EXP_RAW:0:11}" "$DIAS" "$CONEX/$LIMITE"
        echo -e "$ESTADO"
    done < <(_listar_cuentas)

    if [ "$idx" -eq 0 ]; then
        echo -e "${UI_PAD}${DM}No hay cuentas creadas todavía.${CR}"
    fi
    ui_rule
    ui_blank
}

administrar_usuarios() {
    while true; do
        clear
        print_title 2>/dev/null || true
        ui_section "ADMINISTRAR CUENTAS"
        ui_blank
        ui_opt "1" "LISTAR CUENTAS"      "tabla completa"
        ui_opt "2" "ELIMINAR CUENTA"     "borrado definitivo"
        ui_opt "3" "MODIFICAR VIGENCIA"  "cambiar días"
        ui_opt "4" "CAMBIAR CONTRASEÑA"  "reset de clave"
        ui_blank
        ui_opt "0" "VOLVER"
        ui_solid
        ui_prompt "Elige una opción [0-4]"; sub_opt="$REPLY_UI"

        case $sub_opt in
            1)
                clear
                print_title 2>/dev/null || true
                ui_section "LISTA DE CUENTAS"
                _tabla_usuarios
                ui_pause ;;

            2)
                clear
                print_title 2>/dev/null || true
                ui_section "ELIMINAR CUENTA"
                _tabla_usuarios
                ui_prompt "Usuario a ELIMINAR (0 = cancelar)"; DEL_USER="$REPLY_UI"
                [[ "$DEL_USER" == "0" || -z "$DEL_USER" ]] && continue
                if id "$DEL_USER" &>/dev/null; then
                    ui_prompt "¿Confirmar eliminación de '$DEL_USER'? (s/n)"; CONF="$REPLY_UI"
                    if [[ "$CONF" == "s" || "$CONF" == "S" ]]; then
                        # Cerrar sesiones activas antes de borrar
                        pkill -u "$DEL_USER" 2>/dev/null
                        userdel -r "$DEL_USER" 2>/dev/null
                        sed -i "/^$DEL_USER:/d" "$DB_FILE" 2>/dev/null
                        ui_ok "Cuenta ${WH}$DEL_USER${CR} eliminada correctamente."
                    else
                        ui_info "Operación cancelada."
                    fi
                else
                    ui_err "La cuenta '$DEL_USER' no existe."
                fi
                sleep 2 ;;

            3)
                clear
                print_title 2>/dev/null || true
                ui_section "MODIFICAR VIGENCIA"
                _tabla_usuarios
                ui_prompt "Usuario a modificar (0 = cancelar)"; MOD_USER="$REPLY_UI"
                [[ "$MOD_USER" == "0" || -z "$MOD_USER" ]] && continue
                if id "$MOD_USER" &>/dev/null; then
                    ui_prompt "Nuevos días desde hoy"; NEW_DAYS="$REPLY_UI"
                    if [[ "$NEW_DAYS" =~ ^[0-9]+$ ]]; then
                        NEW_EXP=$(date -d "+$NEW_DAYS days" +%Y-%m-%d)
                        usermod -e "$NEW_EXP" "$MOD_USER"
                        ui_ok "Vigencia de ${WH}$MOD_USER${CR} → ${CY}$NEW_EXP${CR} (${NEW_DAYS} días)."
                    else
                        ui_err "Valor inválido."
                    fi
                else
                    ui_err "La cuenta '$MOD_USER' no existe."
                fi
                sleep 2 ;;

            4)
                clear
                print_title 2>/dev/null || true
                ui_section "CAMBIAR CONTRASEÑA"
                _tabla_usuarios
                ui_prompt "Usuario (0 = cancelar)"; PASS_USER="$REPLY_UI"
                [[ "$PASS_USER" == "0" || -z "$PASS_USER" ]] && continue
                if id "$PASS_USER" &>/dev/null; then
                    read -s -p "$(echo -e "${UI_PAD}${DM}Nueva clave ${CY}»${CR} ")" NEW_PASS; echo ""
                    if [ -z "$NEW_PASS" ]; then
                        ui_err "Contraseña vacía, operación cancelada."
                    else
                        echo "$PASS_USER:$NEW_PASS" | chpasswd
                        sed -i "/^$PASS_USER:/d" "$DB_FILE" 2>/dev/null
                        echo "$PASS_USER:$NEW_PASS" >> "$DB_FILE"
                        ui_ok "Contraseña de ${WH}$PASS_USER${CR} actualizada."
                    fi
                else
                    ui_err "La cuenta '$PASS_USER' no existe."
                fi
                sleep 2 ;;

            0) break ;;
            *) ui_err "Opción inválida."; sleep 1 ;;
        esac
    done
}

# =========================================================
# MONITOR DE CONEXIONES ACTIVAS
# =========================================================
monitor_conexiones() {
    clear
    print_title 2>/dev/null || true
    ui_section "MONITOR DE CONEXIONES" "sesiones abiertas en este momento"
    ui_blank
    printf "${UI_PAD}${YL}%-16s %-14s %-10s %s${CR}\n" "USUARIO" "MÉTODO" "SESIONES" "LÍMITE"
    ui_rule

    local total=0 u ssh_c db_c limite marca filas=0

    while read -r u; do
        [ -z "$u" ] && continue
        ssh_c=$(ps -u "$u" -o comm= 2>/dev/null | grep -c "^sshd$")
        db_c=$(ps -u "$u" -o comm= 2>/dev/null | grep -c "^dropbear$")

        limite=$(getent passwd "$u" | cut -d: -f5)
        [[ ! "$limite" =~ ^[0-9]+$ ]] && limite="1"

        if [ "$ssh_c" -gt 0 ]; then
            marca="${GR}▪${CR}"; [ "$ssh_c" -ge "$limite" ] && marca="${RD}▪${CR}"
            printf "${UI_PAD}%b${WH}%-15s${CR} ${CY}%-14s${CR} ${GR}%-10s${CR} ${DM}%s${CR}\n" \
                "$marca" "${u:0:15}" "SSH" "$ssh_c" "$limite"
            total=$((total + ssh_c)); filas=$((filas + 1))
        fi
        if [ "$db_c" -gt 0 ]; then
            marca="${GR}▪${CR}"; [ "$db_c" -ge "$limite" ] && marca="${RD}▪${CR}"
            printf "${UI_PAD}%b${WH}%-15s${CR} ${CY}%-14s${CR} ${GR}%-10s${CR} ${DM}%s${CR}\n" \
                "$marca" "${u:0:15}" "Dropbear" "$db_c" "$limite"
            total=$((total + db_c)); filas=$((filas + 1))
        fi
    done < <(_listar_cuentas)

    # OpenVPN — se lee del status log que haya dejado el servidor
    local status
    status=$(_ovpn_status_file)
    if [ -n "$status" ]; then
        while read -r count user; do
            [ -z "$user" ] && continue
            printf "${UI_PAD}${GR}▪${CR}${WH}%-15s${CR} ${CY}%-14s${CR} ${GR}%-10s${CR} ${DM}%s${CR}\n" \
                "${user:0:15}" "OpenVPN" "$count" "—"
            total=$((total + count)); filas=$((filas + 1))
        done < <(awk -F',' '/^CLIENT_LIST/ {print $2}' "$status" | sort | uniq -c)
    fi

    [ "$filas" -eq 0 ] && echo -e "${UI_PAD}${DM}Ninguna sesión activa en este momento.${CR}"

    ui_rule
    echo -e "${UI_PAD}${WH}TOTAL DE CONEXIONES ACTIVAS:${CR}  ${CY}${BD}$total${CR}"
    ui_solid
    ui_pause
}
