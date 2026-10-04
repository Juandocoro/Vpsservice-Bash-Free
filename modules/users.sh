#!/bin/bash
# Módulo de Usuarios — vpsservice Script FREE

# La paleta y los helpers de dibujo viven en modules/ui.sh
_USR_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$_USR_DIR/ui.sh"
source "$_USR_DIR/system.sh"

DB_FILE="/root/.vps_users"

# Procesos que representan una conexion de cliente. sshd-session es
# el nombre desde OpenSSH 9.8; sin el, en sistemas nuevos el panel
# mostraria a todo el mundo desconectado.
SESSION_RE='^(sshd|sshd-session)$'

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

# Fecha de caducidad en formato AAAA-MM-DD, o "never".
_vence_iso() {
    local raw
    # LANG=C fija el formato en ingles, independiente del locale del servidor
    raw=$(LANG=C chage -l "$1" 2>/dev/null | grep "Account expires" | cut -d: -f2 | xargs)
    if [[ "$raw" == "never" || -z "$raw" ]]; then echo "never"; return; fi
    date -d "$raw" +%Y-%m-%d 2>/dev/null || echo "never"
}

# Dias restantes de una cuenta. Devuelve un entero, o "inf" si no expira.
_dias_restantes() {
    local u="$1" exp_raw exp_sec
    exp_raw=$(LANG=C chage -l "$u" 2>/dev/null | grep "Account expires" | cut -d: -f2 | xargs)
    if [[ "$exp_raw" == "never" || -z "$exp_raw" ]]; then echo "inf"; return; fi
    exp_sec=$(date -d "$exp_raw" +%s 2>/dev/null)
    [ -z "$exp_sec" ] && { echo "?"; return; }
    echo $(( (exp_sec - $(date +%s)) / 86400 ))
}

# Nueva fecha al renovar. Funcion pura, para poder probarla.
#   _fecha_renovada <vence_actual AAAA-MM-DD|never> <dias> <hoy AAAA-MM-DD>
# Si la cuenta aun no ha vencido, los dias se SUMAN a lo que le queda:
# antes se contaban desde hoy y el cliente perdia los dias ya pagados.
_fecha_renovada() {
    local actual="$1" dias="$2" hoy="$3" base="$3"
    if [ "$actual" != "never" ] && [ -n "$actual" ] && [[ ! "$actual" < "$hoy" ]]; then
        base="$actual"
    fi
    date -d "$base + $dias days" +%Y-%m-%d
}

# Nombre valido para useradd y comodo de dictar: minusculas, numeros,
# guion y guion bajo; empieza por letra; 3 a 32 caracteres.
_usuario_valido() {
    [[ "$1" =~ ^[a-z][a-z0-9_-]{2,31}$ ]]
}

_generar_clave() {
    local c
    c=$(tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 8)
    [ -z "$c" ] && c="vps$(date +%s | tail -c 6)"
    echo "$c"
}

# =========================================================
# CONTADORES PARA EL TABLERO (los consume modules/network.sh)
# =========================================================
contar_cuentas() {
    USR_ACTIVAS=0; USR_PORVENCER=0; USR_VENCIDAS=0; USR_TOTAL=0; USR_VENCEN_HOY=0
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
             [ "$d" -le 0 ] && USR_VENCEN_HOY=$(( USR_VENCEN_HOY + 1 ))
        else                       USR_ACTIVAS=$(( USR_ACTIVAS + 1 ))
        fi
    done < <(_listar_cuentas)
}

contar_online() {
    ON_SSH=0; ON_DROPBEAR=0; ON_OVPN=0
    local u
    while read -r u; do
        [ -z "$u" ] && continue
        ON_SSH=$(( ON_SSH + $(ps -u "$u" -o comm= 2>/dev/null | grep -cE "$SESSION_RE") ))
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

# ¿Hay gateway residencial con nodos? (el modulo puede no estar cargado)
_hay_nodos() {
    # Se mira el fichero antes de llamar al modulo: contar nodos crea
    # /etc/wireguard, y en un VPS sin gateway eso sobra.
    [ -s "${WGH_NODES_CONF:-/etc/wireguard/homevpn-nodes.conf}" ] || return 1
    declare -F _wgh_nodes_count >/dev/null 2>&1 && [ "$(_wgh_nodes_count 2>/dev/null)" -gt 0 ] 2>/dev/null
}

# =========================================================
# FICHA DE LA CUENTA — todo lo que hay que mandarle al cliente
# ---------------------------------------------------------
# Antes, tras crear una cuenta, habia que ir aparte a
# CONFIGURACION > DATOS DE CONEXION para saber que puertos y
# payload darle. Ahora sale todo junto, listo para copiar.
# =========================================================
_ficha_cuenta() {
    local u="$1" pass="$2" vence="$3" lim="$4" salida="$5" ip
    declare -F refresh_ports >/dev/null 2>&1 && refresh_ports
    ip=$(_public_ip 2>/dev/null); [ -z "$ip" ] && ip="N/A"

    ui_blank
    echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Servidor" "$ip" 30 "$GR")"
    echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Usuario " "$u" 30)"
    echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Password" "$pass" 30)"
    echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Vence   " "$vence" 30 "$YL")"
    echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Límite  " "$lim dispositivo(s)" 30 "$CY")"
    echo -e "${UI_PAD}${GR}▪${CR} $(ui_cell "Salida  " "${salida:-IP del VPS}" 30 "$CY")"
    ui_rule
    [ -n "${PORT_SSH:-}" ]       && echo -e "${UI_PAD}$(ui_cell "SSH      " "$PORT_SSH" 20 "$CY")"
    [ -n "${PORT_SSL:-}" ]       && echo -e "${UI_PAD}$(ui_cell "SSL/TLS  " "$PORT_SSL" 20 "$CY")"
    [ -n "${PORT_WS:-}" ]        && echo -e "${UI_PAD}$(ui_cell "WebSocket" "$PORT_WS" 20 "$CY")"
    [ -n "${PORT_DROPBEAR:-}" ]  && echo -e "${UI_PAD}$(ui_cell "Dropbear " "$PORT_DROPBEAR" 20 "$CY")"
    [ -n "${PORT_UDPCUSTOM:-}" ] && echo -e "${UI_PAD}$(ui_cell "UDP      " "$PORT_UDPCUSTOM" 20 "$CY")"
    [ -n "${PORT_BADVPN:-}" ]    && echo -e "${UI_PAD}$(ui_cell "BadVPN   " "127.0.0.1:$PORT_BADVPN" 20 "$CY")"
    if [ -n "${PORT_WS:-}" ]; then
        ui_blank
        echo -e "${UI_PAD}${DM}Payload WebSocket:${CR} ${WH}GET / HTTP/1.1[crlf]Host: ${ip}[crlf]Upgrade: websocket[crlf][crlf]${CR}"
    fi
}

# =========================================================
# CREAR CUENTA
# =========================================================
crear_usuario() {
    clear
    print_title 2>/dev/null || true
    ui_section "CREAR CUENTA NUEVA" "SSH · SSL · Dropbear"
    ui_blank

    # Cada dato se vuelve a pedir si esta mal, en vez de abortar todo
    # el alta por una errata en el ultimo campo.
    local USERNAME PASSWORD DAYS LIMIT
    while true; do
        ui_prompt "Nombre de usuario (Enter = cancelar)"; USERNAME="$REPLY_UI"
        [ -z "$USERNAME" ] && return
        if ! _usuario_valido "$USERNAME"; then
            ui_err "Usa minúsculas, números, - o _, empezando por letra (3-32)."; continue
        fi
        if id "$USERNAME" &>/dev/null; then ui_err "Ese usuario ya existe."; continue; fi
        break
    done

    # Visible a proposito: hay que dictarsela al cliente y el panel ya la
    # muestra despues en la tabla de cuentas.
    while true; do
        ui_prompt "Contraseña (Enter = generar una)"; PASSWORD="$REPLY_UI"
        if [ -z "$PASSWORD" ]; then
            PASSWORD=$(_generar_clave); ui_info "Contraseña generada: ${WH}${PASSWORD}${CR}"; break
        fi
        # ':' rompe el formato usuario:clave de chpasswd y del registro.
        [[ "$PASSWORD" == *:* ]] && { ui_err "La contraseña no puede llevar ':'."; continue; }
        break
    done

    while true; do
        ui_prompt "Duración en días (Enter = 30)"; DAYS="${REPLY_UI:-30}"
        [[ "$DAYS" =~ ^[0-9]+$ ]] && [ "$DAYS" -ge 1 ] && [ "$DAYS" -le 3650 ] && break
        ui_err "Escribe un número de días entre 1 y 3650."
    done

    while true; do
        ui_prompt "Dispositivos simultáneos (Enter = 1)"; LIMIT="${REPLY_UI:-1}"
        [[ "$LIMIT" =~ ^[0-9]+$ ]] && [ "$LIMIT" -ge 1 ] && [ "$LIMIT" -le 100 ] && break
        ui_err "Escribe un número entre 1 y 100."
    done

    # ¿Por donde sale a Internet? Se pregunta siempre: si hay nodos
    # residenciales se elige uno, y si no se informa de que saldra por
    # la IP del VPS.
    local SALIDA=""
    ui_blank
    echo -e "${UI_PAD}${YL}── SALIDA A INTERNET ──${CR}"
    if _hay_nodos; then
        _wgh_pick_exit "" || PICK_NODE=""
        SALIDA="$PICK_NODE"
    else
        echo -e "${UI_PAD}${DM}Saldrá por la IP del VPS. Para darle una IP residencial,${CR}"
        echo -e "${UI_PAD}${DM}registra un nodo en CONFIGURACIÓN > GATEWAY RESIDENCIAL.${CR}"
    fi

    local EXP_DATE
    EXP_DATE=$(date -d "+$DAYS days" +%Y-%m-%d 2>/dev/null)

    ui_blank
    ui_info "Creando la cuenta..."

    # La configuracion SSH para tunneling vive en modules/system.sh, que es
    # la unica fuente de verdad. Solo recarga sshd si de verdad cambia algo.
    ssh_apply_tunnel_config "$USERNAME"

    if ! useradd -m -s /bin/bash -e "$EXP_DATE" -c "$LIMIT" "$USERNAME" 2>/dev/null; then
        ui_err "useradd falló: la cuenta no se ha creado."
        ui_pause; return
    fi
    echo "$USERNAME:$PASSWORD" | chpasswd

    # Desbloqueo forzado de la cuenta (passwd -u quita el prefijo ! del hash)
    passwd -u "$USERNAME" &>/dev/null
    usermod -U "$USERNAME" &>/dev/null

    # Log plano seguro
    touch "$DB_FILE"
    chmod 600 "$DB_FILE"
    sed -i "/^$USERNAME:/d" "$DB_FILE" 2>/dev/null
    echo "$USERNAME:$PASSWORD" >> "$DB_FILE"

    # La salida, al final: las reglas van por UID y el UID no existe
    # hasta que se crea la cuenta.
    [ -n "$SALIDA" ] && _wgh_set_user_exit "$USERNAME" "$SALIDA"
    sleep 1

    clear
    print_title 2>/dev/null || true
    ui_section "CUENTA ACTIVADA" "$USERNAME"
    _ficha_cuenta "$USERNAME" "$PASSWORD" "$EXP_DATE ($DAYS días)" "$LIMIT" "$SALIDA"
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

        EXP_RAW=$(_vence_iso "$u")

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
        CONEX=$(ps -u "$u" -o comm= 2>/dev/null | grep -cE '^(sshd|sshd-session|dropbear)$')

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

# Muestra la tabla y pide una cuenta. Deja el nombre en
# $USUARIO_RESUELTO; devuelve 1 si se cancela o no existe.
_elegir_cuenta() {
    _tabla_usuarios
    ui_prompt "${1:-Número o nombre de la cuenta} (Enter = cancelar)"
    [ -z "$REPLY_UI" ] && return 1
    _resolver_usuario "$REPLY_UI" || { sleep 2; return 1; }
}

# =========================================================
# ACCIONES SOBRE UNA CUENTA
# Cuelgan directas del menu de cuentas: una pantalla menos
# por cada operacion.
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
    _elegir_cuenta "Número o nombre a ELIMINAR" || return
    local u="$USUARIO_RESUELTO"

    if ui_confirm "¿Confirmar la eliminación de '$u'?" "n"; then
        pkill -u "$u" 2>/dev/null
        userdel -r "$u" 2>/dev/null
        sed -i "/^$u:/d" "$DB_FILE" 2>/dev/null
        # Su salida residencial: se borra la asignacion y su regla de
        # marcado. Si no, la proxima cuenta que heredara su UID saldria
        # por ese nodo sin que nadie lo hubiera pedido.
        if declare -F _wgh_user_assign >/dev/null 2>&1 && [ -n "$(_wgh_user_node "$u")" ]; then
            _wgh_user_assign "$u" ""
            { [ -f "$WGH_ROUTING_FLAG" ] || _wgh_routing_is_active; } && _wgh_apply_user_routing >/dev/null 2>&1
        fi
        ui_ok "Cuenta ${WH}$u${CR} eliminada correctamente."
    else
        ui_info "Operación cancelada."
    fi
    sleep 2
}

renovar_vigencia() {
    clear
    print_title 2>/dev/null || true
    ui_section "RENOVAR VIGENCIA" "los días se suman a lo que le queda"
    _elegir_cuenta || return
    local u="$USUARIO_RESUELTO" actual hoy dias nueva err

    actual=$(_vence_iso "$u"); hoy=$(date +%Y-%m-%d)
    if [ "$actual" = "never" ]; then
        echo -e "${UI_PAD}${DM}${u} no tiene fecha de caducidad.${CR}"
    elif [[ "$actual" < "$hoy" ]]; then
        echo -e "${UI_PAD}${DM}${u} venció el ${RD}${actual}${DM}: los días cuentan desde hoy.${CR}"
    else
        echo -e "${UI_PAD}${DM}${u} vence el ${YL}${actual}${DM}: los días se añaden a esa fecha.${CR}"
    fi
    while true; do
        ui_prompt "Días a añadir (Enter = 30, c = cancelar)"
        [ "$REPLY_UI" = "c" ] && return
        dias="${REPLY_UI:-30}"
        [[ "$dias" =~ ^[0-9]+$ ]] && [ "$dias" -ge 1 ] && [ "$dias" -le 3650 ] && break
        ui_err "Escribe un número entre 1 y 3650."
    done

    nueva=$(_fecha_renovada "$actual" "$dias" "$hoy")
    # Antes se daba por hecho el exito: si usermod fallaba, el panel
    # anunciaba la renovacion igual y la cuenta seguia vencida.
    if err=$(usermod -e "$nueva" "$u" 2>&1); then
        ui_ok "Vigencia de ${WH}$u${CR} → ${CY}$nueva${CR} (+${dias} días)."
        # Una cuenta vencida pudo quedar con sesiones muertas a medias;
        # las cerramos para que la siguiente conexion entre limpia.
        [[ "$actual" != "never" && "$actual" < "$hoy" ]] && {
            pkill -u "$u" sshd 2>/dev/null; pkill -u "$u" sshd-session 2>/dev/null; pkill -u "$u" dropbear 2>/dev/null; }
    else
        ui_err "No se pudo renovar: ${err:-usermod devolvio error}"
    fi
    sleep 2
}

cambiar_password() {
    clear
    print_title 2>/dev/null || true
    ui_section "CAMBIAR CONTRASEÑA"
    _elegir_cuenta || return
    local u="$USUARIO_RESUELTO"

    # Visible a proposito: el panel ya muestra todas las claves en la tabla,
    # y ocultarla aqui solo dificultaba dictarsela al cliente.
    ui_prompt "Nueva contraseña (Enter = generar una)"
    local pass="$REPLY_UI"
    [ -z "$pass" ] && pass=$(_generar_clave)
    [[ "$pass" == *:* ]] && { ui_err "La contraseña no puede llevar ':'."; sleep 2; return; }

    echo "$u:$pass" | chpasswd
    sed -i "/^$u:/d" "$DB_FILE" 2>/dev/null
    echo "$u:$pass" >> "$DB_FILE"
    ui_ok "Contraseña de ${WH}$u${CR} → ${WH}$pass${CR}"
    ui_pause
}

cambiar_limite() {
    clear
    print_title 2>/dev/null || true
    ui_section "LÍMITE DE CONEXIONES" "cuántos dispositivos simultáneos"
    _elegir_cuenta || return
    local u="$USUARIO_RESUELTO"

    ui_prompt "Nuevo límite de dispositivos"
    local lim="$REPLY_UI"
    if [[ ! "$lim" =~ ^[0-9]+$ ]] || [ "$lim" -lt 1 ]; then ui_err "Valor inválido."; sleep 2; return; fi

    # El limite se guarda en el campo GECOS, que es de donde lo lee killer.sh
    usermod -c "$lim" "$u"
    ui_ok "Límite de ${WH}$u${CR} → ${CY}$lim${CR} dispositivo(s)."
    sleep 2
}

# Por donde sale una cuenta que ya existe.
cambiar_salida() {
    clear
    print_title 2>/dev/null || true
    ui_section "SALIDA A INTERNET" "por dónde navega cada cuenta"
    if ! _hay_nodos; then
        ui_blank
        ui_warn "No hay nodos residenciales: todas las cuentas salen por la IP del VPS."
        echo -e "${UI_PAD}${DM}Registra uno en CONFIGURACIÓN > GATEWAY RESIDENCIAL > NODOS.${CR}"
        ui_pause; return
    fi
    _elegir_cuenta || return
    local u="$USUARIO_RESUELTO"
    ui_blank
    echo -e "${UI_PAD}${WH}Salida para ${u}${CR}"
    _wgh_pick_exit "$(_wgh_user_node "$u")" || return
    _wgh_set_user_exit "$u" "$PICK_NODE"
    ui_pause
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
        ssh_c=$(ps -u "$u" -o comm= 2>/dev/null | grep -cE "$SESSION_RE")
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
