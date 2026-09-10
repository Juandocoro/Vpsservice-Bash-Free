#!/bin/bash
# Módulo de Usuarios — vpsservice Script FREE

# La paleta y los helpers de dibujo viven en modules/ui.sh
_USR_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$_USR_DIR/ui.sh"
source "$_USR_DIR/system.sh"

DB_FILE="/root/.vps_users"

# =========================================================
# LISTADO BASE DE CUENTAS DEL PANEL
# =========================================================
_listar_cuentas() {
    awk -F':' '($3 >= 1000 && $3 != 65534 && $1 != "nobody" && $1 != "ubuntu") {print $1}' /etc/passwd
}

# La tabla numera las cuentas, asi que lo natural es escribir el numero.
# Acepta ambas cosas: un numero se traduce a la cuenta de esa fila; si no,
# se toma como nombre. Devuelve el nombre en $USUARIO_RESUELTO, o vacio.
_resolver_usuario() {
    local entrada="$1"
    USUARIO_RESUELTO=""
    [ -z "$entrada" ] && return 1
    if [[ "$entrada" =~ ^[0-9]+$ ]]; then
        USUARIO_RESUELTO=$(_listar_cuentas | sed -n "${entrada}p")
        if [ -z "$USUARIO_RESUELTO" ]; then
            ui_err "No hay ninguna cuenta en la fila $entrada."
            return 1
        fi
        return 0
    fi
    if id "$entrada" &>/dev/null && _listar_cuentas | grep -qx "$entrada"; then
        USUARIO_RESUELTO="$entrada"
        return 0
    fi
    ui_err "La cuenta '$entrada' no existe."
    return 1
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

    # Visible a proposito: hay que dictarsela al cliente y el panel ya la
    # muestra despues en la tabla de cuentas.
    ui_prompt "CONTRASEÑA"; PASSWORD="$REPLY_UI"
    if [ -z "$PASSWORD" ]; then ui_err "Contraseña vacía."; sleep 1; return; fi

    ui_prompt "DURACIÓN (días)"; DAYS="$REPLY_UI"
    if [[ ! "$DAYS" =~ ^[0-9]+$ ]]; then ui_err "Formato numérico requerido."; sleep 1; return; fi

    ui_prompt "LÍMITE DE CONEXIONES"; LIMIT="$REPLY_UI"
    if [[ ! "$LIMIT" =~ ^[0-9]+$ ]]; then ui_err "Formato numérico requerido."; sleep 1; return; fi

    EXP_DATE=$(date -d "+$DAYS days" +%Y-%m-%d 2>/dev/null)
    SERVER_IP=$(_public_ip 2>/dev/null || curl -4 -s ifconfig.me 2>/dev/null || echo "N/A")

    ui_blank
    ui_info "Configurando SSH y creando la cuenta..."

    # La configuracion SSH para tunneling vive en modules/system.sh, que es
    # la unica fuente de verdad. Antes este bloque estaba duplicado aqui y en
    # otros tres archivos.
    ssh_apply_tunnel_config "$USERNAME"

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

# =========================================================
# ACCIONES SOBRE UNA CUENTA
# Antes vivian dentro de un submenu 'Administrar usuarios' que
# obligaba a bajar dos niveles. Ahora cuelgan directas del menu
# de cuentas: una pantalla menos por cada operacion.
# =========================================================

listar_usuarios() {
    clear
    print_title 2>/dev/null || true
    ui_section "LISTA DE CUENTAS"
    _tabla_usuarios
    ui_pause
}

eliminar_usuario() {
    clear
    print_title 2>/dev/null || true
    ui_section "ELIMINAR CUENTA"
    _tabla_usuarios
    ui_prompt "Número o nombre a ELIMINAR (Enter = cancelar)"
    [ -z "$REPLY_UI" ] && return
    _resolver_usuario "$REPLY_UI" || { sleep 2; return; }
    local u="$USUARIO_RESUELTO"

    ui_prompt "¿Confirmar la eliminación de '$u'? (s/n)"
    if [[ "$REPLY_UI" == "s" || "$REPLY_UI" == "S" ]]; then
        pkill -u "$u" 2>/dev/null
        userdel -r "$u" 2>/dev/null
        sed -i "/^$u:/d" "$DB_FILE" 2>/dev/null
        ui_ok "Cuenta ${WH}$u${CR} eliminada correctamente."
    else
        ui_info "Operación cancelada."
    fi
    sleep 2
}

renovar_vigencia() {
    clear
    print_title 2>/dev/null || true
    ui_section "RENOVAR VIGENCIA"
    _tabla_usuarios
    ui_prompt "Número o nombre de la cuenta (Enter = cancelar)"
    [ -z "$REPLY_UI" ] && return
    _resolver_usuario "$REPLY_UI" || { sleep 2; return; }
    local u="$USUARIO_RESUELTO"

    ui_prompt "Nuevos días desde hoy"
    local dias="$REPLY_UI"
    if [[ ! "$dias" =~ ^[0-9]+$ ]]; then ui_err "Valor inválido."; sleep 2; return; fi

    local nueva err
    nueva=$(date -d "+$dias days" +%Y-%m-%d)
    # Antes se daba por hecho el exito: si usermod fallaba, el panel
    # anunciaba la renovacion igual y la cuenta seguia vencida.
    if err=$(usermod -e "$nueva" "$u" 2>&1); then
        ui_ok "Vigencia de ${WH}$u${CR} → ${CY}$nueva${CR} (${dias} días)."
        # Una cuenta vencida pudo quedar con sesiones muertas a medias;
        # las cerramos para que la siguiente conexion entre limpia.
        pkill -u "$u" sshd 2>/dev/null; pkill -u "$u" dropbear 2>/dev/null
    else
        ui_err "No se pudo renovar: ${err:-usermod devolvio error}"
    fi
    sleep 2
}

cambiar_password() {
    clear
    print_title 2>/dev/null || true
    ui_section "CAMBIAR CONTRASEÑA"
    _tabla_usuarios
    ui_prompt "Número o nombre de la cuenta (Enter = cancelar)"
    [ -z "$REPLY_UI" ] && return
    _resolver_usuario "$REPLY_UI" || { sleep 2; return; }
    local u="$USUARIO_RESUELTO"

    # Visible a proposito: el panel ya muestra todas las claves en la tabla,
    # y ocultarla aqui solo dificultaba dictarsela al cliente.
    ui_prompt "Nueva contraseña"
    local pass="$REPLY_UI"
    if [ -z "$pass" ]; then ui_err "Contraseña vacía, operación cancelada."; sleep 2; return; fi

    echo "$u:$pass" | chpasswd
    sed -i "/^$u:/d" "$DB_FILE" 2>/dev/null
    echo "$u:$pass" >> "$DB_FILE"
    ui_ok "Contraseña de ${WH}$u${CR} → ${WH}$pass${CR}"
    sleep 3
}

cambiar_limite() {
    clear
    print_title 2>/dev/null || true
    ui_section "LÍMITE DE CONEXIONES" "cuántos dispositivos simultáneos"
    _tabla_usuarios
    ui_prompt "Número o nombre de la cuenta (Enter = cancelar)"
    [ -z "$REPLY_UI" ] && return
    _resolver_usuario "$REPLY_UI" || { sleep 2; return; }
    local u="$USUARIO_RESUELTO"

    ui_prompt "Nuevo límite de dispositivos"
    local lim="$REPLY_UI"
    if [[ ! "$lim" =~ ^[0-9]+$ ]] || [ "$lim" -lt 1 ]; then ui_err "Valor inválido."; sleep 2; return; fi

    # El limite se guarda en el campo GECOS, que es de donde lo lee killer.sh
    usermod -c "$lim" "$u"
    ui_ok "Límite de ${WH}$u${CR} → ${CY}$lim${CR} dispositivo(s)."
    sleep 2
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
