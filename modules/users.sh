#!/bin/bash
# Módulo de Usuarios — vpsservice Script FREE

# La paleta y los helpers de dibujo viven en modules/ui.sh
_USR_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$_USR_DIR/ui.sh"
source "$_USR_DIR/system.sh"

DB_FILE="/root/.vps_users"
PASSWD_FILE="/etc/passwd"
SHADOW_FILE="/etc/shadow"

# Procesos que representan una conexion de cliente. sshd-session es
# el nombre desde OpenSSH 9.8; sin el, en sistemas nuevos el panel
# mostraria a todo el mundo desconectado.
SESSION_RE='^(sshd|sshd-session)$'

# =========================================================
# LISTADO BASE DE CUENTAS DEL PANEL
# =========================================================
_listar_cuentas() {
    awk -F':' '($3 >= 1000 && $3 != 65534 && $1 != "nobody" && $1 != "ubuntu") {print $1}' "$PASSWD_FILE"
}

# =========================================================
# FOTO DE TODAS LAS CUENTAS EN UNA PASADA
# ---------------------------------------------------------
# Antes cada fila de la tabla lanzaba chage (x2), date, grep,
# getent y ps: unos 6 procesos por cuenta. Con 100 cuentas eran
# 600 procesos para pintar una pantalla, y el tablero principal
# repetia la cuenta en cada vuelta. Ahora es un solo awk que lee
# passwd, shadow, el registro de claves y la lista de procesos.
#
# Una linea por cuenta, en el orden de /etc/passwd (el mismo que
# usa _resolver_usuario, asi el numero de fila siempre coincide):
#   usuario|limite|dias|ssh|dropbear|clave|vence(AAAA-MM-DD|never)
#
# 'dias' son los dias que AUN puede entrar, contando hoy. PAM da la
# cuenta por vencida desde el mismo dia de su fecha de caducidad
# (hoy >= vence), asi que dias <= 0 es VENCIDA. El calculo anterior
# redondeaba hacia cero y ese dia la mostraba como "por vencer".
# =========================================================
_ps_sesiones() { ps -eo uid=,comm= 2>/dev/null; }

# _cuentas_parse <passwd> <shadow> <claves> <ps> <hoy_en_dias>
_cuentas_parse() {
    awk -F':' -v hoy="$5" -v fp="$1" -v fs="$2" -v fc="$3" -v fq="$4" '
    # Dias desde 1970 -> AAAA-MM-DD, sin depender de gawk ni de date.
    function civil(z,   era, doe, yoe, y, doy, mp, d, m) {
        z += 719468; era = int(z / 146097); doe = z - era * 146097
        yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
        y = yoe + era * 400; doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
        mp = int((5 * doy + 2) / 153); d = doy - int((153 * mp + 2) / 5) + 1
        m = (mp < 10) ? mp + 3 : mp - 9
        if (m <= 2) y++
        return sprintf("%04d-%02d-%02d", y, m, d)
    }
    FILENAME == fp {
        if ($3 >= 1000 && $3 != 65534 && $1 != "nobody" && $1 != "ubuntu") {
            n++; ord[n] = $1; lim[$1] = $5; quien[$3] = $1
        }
        next
    }
    FILENAME == fs { ex[$1] = $8; next }
    FILENAME == fc { p = index($0, ":"); if (p) clave[substr($0, 1, p - 1)] = substr($0, p + 1); next }
    FILENAME == fq {
        split($0, a, " ")
        if (!(a[1] in quien)) next
        if (a[2] == "sshd" || a[2] == "sshd-session") ssh[quien[a[1]]]++
        else if (a[2] == "dropbear") db[quien[a[1]]]++
        next
    }
    END {
        for (i = 1; i <= n; i++) {
            u = ord[i]; l = lim[u]; if (l !~ /^[0-9]+$/) l = 1
            e = ex[u]
            if (e == "" || e !~ /^[0-9]+$/) { d = "inf"; v = "never" } else { d = e - hoy; v = civil(e) }
            printf "%s|%s|%s|%d|%d|%s|%s\n", u, l, d, ssh[u] + 0, db[u] + 0, clave[u], v
        }
    }' "$1" "$2" "$3" "$4"
}

_cuentas_snapshot() {
    local shadow="$SHADOW_FILE" db="$DB_FILE" ps_f
    [ -r "$shadow" ] || shadow=/dev/null
    [ -r "$db" ] || db=/dev/null
    ps_f=$(mktemp)
    _ps_sesiones > "$ps_f"
    # Si shadow y claves son ambos /dev/null, awk no puede distinguirlos
    # por nombre, pero tampoco tienen lineas: no importa.
    _cuentas_parse "$PASSWD_FILE" "$shadow" "$db" "$ps_f" $(( $(date +%s) / 86400 ))
    rm -f "$ps_f"
}

# La foto se reutiliza dentro del mismo segundo: el tablero pide
# cuentas y sesiones por separado y no hace falta leerlo dos veces.
_snap_load() {
    if [ "${_SNAP_T:-x}" != "$SECONDS" ]; then
        _SNAP=$(_cuentas_snapshot); _SNAP_T="$SECONDS"
    fi
}
_snap_reset() { _SNAP_T="x"; }

# La linea de una cuenta en la foto
_snap_de() { _snap_load; grep "^$1|" <<<"$_SNAP" | head -1; }

# =========================================================
# RESOLVER UNA CUENTA
# =========================================================
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
    local l
    l=$(_snap_de "$1")
    [ -n "$l" ] && { echo "${l##*|}"; return; }
    echo "never"
}

# Dias que aun puede entrar (contando hoy). Entero, o "inf" si no expira.
_dias_restantes() {
    local l
    l=$(_snap_de "$1")
    [ -z "$l" ] && { echo "?"; return; }
    cut -d'|' -f3 <<<"$l"
}

# Nueva fecha al renovar. Funcion pura, para poder probarla.
#   _fecha_renovada <vence_actual AAAA-MM-DD|never> <dias> <hoy AAAA-MM-DD>
# Si la cuenta aun no ha vencido, los dias se SUMAN a lo que le queda:
# antes se contaban desde hoy y el cliente perdia los dias ya pagados.
_fecha_renovada() {
    local actual="$1" dias="$2" hoy="$3" base="$3"
    if [ "$actual" != "never" ] && [ -n "$actual" ] && [[ "$actual" > "$hoy" ]]; then
        base="$actual"
    fi
    date -d "$base + $dias days" +%Y-%m-%d
}

# Estado de una cuenta a partir de sus dias -> "ETIQUETA|color"
_estado_cuenta() {
    case "$1" in
        inf) echo "ACTIVO|$GR" ;;
        \?)  echo "DESCONOCIDO|$DM" ;;
        *)   if   [ "$1" -le 0 ]; then echo "VENCIDO|$RD"
             elif [ "$1" -le 3 ]; then echo "POR VENCER|$YL"
             else                      echo "ACTIVO|$GR"; fi ;;
    esac
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
    local u l d
    _snap_load
    while IFS='|' read -r u l d _; do
        [ -z "$u" ] && continue
        USR_TOTAL=$(( USR_TOTAL + 1 ))
        if   [ "$d" = "inf" ]; then USR_ACTIVAS=$(( USR_ACTIVAS + 1 ))
        elif [ "$d" -le 0 ];   then USR_VENCIDAS=$(( USR_VENCIDAS + 1 ))
        elif [ "$d" -le 3 ];   then USR_PORVENCER=$(( USR_PORVENCER + 1 ))
             [ "$d" -eq 1 ] && USR_VENCEN_HOY=$(( USR_VENCEN_HOY + 1 ))
        else                        USR_ACTIVAS=$(( USR_ACTIVAS + 1 ))
        fi
    done <<<"$_SNAP"
}

contar_online() {
    ON_SSH=0; ON_DROPBEAR=0; ON_OVPN=0
    local u l d s b
    _snap_load
    while IFS='|' read -r u l d s b _; do
        [ -z "$u" ] && continue
        ON_SSH=$(( ON_SSH + s )); ON_DROPBEAR=$(( ON_DROPBEAR + b ))
    done <<<"$_SNAP"

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

_salida_de() {
    declare -F _wgh_user_node >/dev/null 2>&1 && _wgh_user_node "$1"
}

# =========================================================
# FICHA PARA EL CLIENTE — todo lo que hay que mandarle
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
    while true; do
        _crear_una || return
        ui_blank
        ui_confirm "¿Crear otra cuenta?" "n" || return
    done
}

_crear_una() {
    clear
    print_title 2>/dev/null || true
    ui_section "CREAR CUENTA NUEVA" "SSH · SSL · Dropbear"
    ui_blank

    # Cada dato se vuelve a pedir si esta mal, en vez de abortar todo
    # el alta por una errata en el ultimo campo.
    local USERNAME PASSWORD DAYS LIMIT
    while true; do
        ui_prompt "Nombre de usuario (Enter = cancelar)"; USERNAME="$REPLY_UI"
        [ -z "$USERNAME" ] && return 1
        if ! _usuario_valido "$USERNAME"; then
            ui_err "Usa minúsculas, números, - o _, empezando por letra (3-32)."; continue
        fi
        if id "$USERNAME" &>/dev/null; then ui_err "Ese usuario ya existe."; continue; fi
        break
    done

    # Visible a proposito: hay que dictarsela al cliente.
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

    # ¿Por donde sale a Internet? Se pregunta siempre.
    local SALIDA=""
    ui_blank
    echo -e "${UI_PAD}${YL}── SALIDA A INTERNET ──${CR}"
    if _hay_nodos; then
        _wgh_pick_exit "" || PICK_NODE=""
        SALIDA="$PICK_NODE"
    else
        echo -e "${UI_PAD}${DM}Saldrá por la IP del VPS. Para darle una IP residencial,${CR}"
        echo -e "${UI_PAD}${DM}registra un nodo en IP RESIDENCIAL.${CR}"
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
        ui_pause; return 1
    fi
    echo "$USERNAME:$PASSWORD" | chpasswd

    # Desbloqueo forzado de la cuenta (passwd -u quita el prefijo ! del hash)
    passwd -u "$USERNAME" &>/dev/null
    usermod -U "$USERNAME" &>/dev/null

    _guardar_clave "$USERNAME" "$PASSWORD"

    # La salida, al final: las reglas van por UID y el UID no existe
    # hasta que se crea la cuenta.
    [ -n "$SALIDA" ] && _wgh_set_user_exit "$USERNAME" "$SALIDA"
    _snap_reset
    sleep 1

    clear
    print_title 2>/dev/null || true
    ui_section "CUENTA ACTIVADA" "$USERNAME"
    _ficha_cuenta "$USERNAME" "$PASSWORD" "$EXP_DATE ($DAYS días)" "$LIMIT" "$SALIDA"
    ui_solid
    return 0
}

_guardar_clave() {
    touch "$DB_FILE"; chmod 600 "$DB_FILE"
    sed -i "/^$1:/d" "$DB_FILE" 2>/dev/null
    echo "$1:$2" >> "$DB_FILE"
}

# =========================================================
# TABLA DE CUENTAS
# =========================================================
_tabla_usuarios() {
    ui_blank
    printf "${UI_PAD}${YL}%-3s %-14s %-12s %-11s %-6s %-7s %s${CR}\n" \
        "#" "USUARIO" "CLAVE" "VENCE" "DÍAS" "CONEX" "ESTADO"
    ui_rule

    local idx=0 u lim d s b pass vence est col dias
    _snap_reset; _snap_load
    while IFS='|' read -r u lim d s b pass vence; do
        [ -z "$u" ] && continue
        idx=$((idx + 1))
        IFS='|' read -r est col <<<"$(_estado_cuenta "$d")"
        case "$d" in inf) dias="-" ;; *) [ "$d" -le 0 ] && dias="0" || dias="${d}d" ;; esac
        [ "$vence" = "never" ] && vence="nunca"
        printf "${UI_PAD}%b▪${CR}${CY}%-2s${CR} ${WH}%-14s${CR} ${DM}%-12s${CR} ${DM}%-11s${CR} ${CY}%-6s${CR} ${WH}%-7s${CR}%b%s${CR}\n" \
            "$col" "$idx" "${u:0:14}" "${pass:--}" "$vence" "$dias" "$((s + b))/$lim" "$col" "$est"
    done <<<"$_SNAP"

    [ "$idx" -eq 0 ] && echo -e "${UI_PAD}${DM}No hay cuentas creadas todavía.${CR}"
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

# Las acciones se pueden llamar con la cuenta ya elegida (desde su
# ficha) o sin ella (atajos del menu principal), y entonces la piden.
_cuenta_arg() {
    if [ -n "${1:-}" ]; then USUARIO_RESUELTO="$1"; return 0; fi
    _elegir_cuenta "${2:-}"
}

# =========================================================
# CUENTAS — lista y ficha de cada cuenta
# ---------------------------------------------------------
# Antes cada accion (renovar, clave, limite, salida, borrar) era
# una entrada de menu que volvia a pintar la tabla y a pedir la
# cuenta. Atender a un cliente eran tres busquedas. Ahora se elige
# la cuenta una vez y se hace todo desde su ficha.
# =========================================================
cuentas_menu() {
    while true; do
        clear
        print_title 2>/dev/null || true
        ui_section "CUENTAS" "elige una para ver y editar su ficha"
        _tabla_usuarios
        echo -e "${UI_PAD}${DM}Número o nombre = abrir su ficha${CR}"
        ui_opt "N" "NUEVA CUENTA"    "crear"
        ui_opt "L" "LIMPIAR VENCIDAS" "borrar caducadas"
        ui_opt "0" "VOLVER"
        ui_solid
        ui_prompt "Cuenta o acción"
        case "$REPLY_UI" in
            ""|0) return ;;
            [Nn]) crear_usuario ;;
            [Ll]) limpiar_vencidas ;;
            *)    _resolver_usuario "$REPLY_UI" && cuenta_ficha "$USUARIO_RESUELTO" || sleep 2 ;;
        esac
    done
}

cuenta_ficha() {
    local u="$1" l lim d s b pass vence est col sal
    while true; do
        id "$u" &>/dev/null || return
        _snap_reset
        l=$(_snap_de "$u")
        IFS='|' read -r _ lim d s b pass vence <<<"$l"
        IFS='|' read -r est col <<<"$(_estado_cuenta "$d")"
        sal=$(_salida_de "$u")

        clear
        print_title 2>/dev/null || true
        ui_section "CUENTA: $u"
        ui_blank
        echo -e "${UI_PAD}$(ui_cell "Estado    " "" 12)${col}${est}${CR}"
        echo -e "${UI_PAD}$(ui_cell "Clave     " "${pass:-—}" 34)"
        if [ "$vence" = "never" ]; then
            echo -e "${UI_PAD}$(ui_cell "Vence     " "nunca" 34 "$YL")"
        else
            echo -e "${UI_PAD}$(ui_cell "Vence     " "$vence ($([ "$d" -le 0 ] && echo vencida || echo "quedan ${d} días"))" 34 "$YL")"
        fi
        echo -e "${UI_PAD}$(ui_cell "Conectados" "$((s + b)) de $lim" 34 "$CY")"
        echo -e "${UI_PAD}$(ui_cell "Salida    " "${sal:-IP del VPS}" 34 "$CY")"
        ui_rule
        ui_blank
        ui_opt "1" "RENOVAR"              "sumar días"
        ui_opt "2" "CAMBIAR CONTRASEÑA"   ""
        ui_opt "3" "LÍMITE DE DISPOSITIVOS" "ahora: $lim"
        ui_opt "4" "SALIDA A INTERNET"    "VPS o nodo"
        ui_opt "5" "DATOS PARA EL CLIENTE" "ficha completa"
        ui_opt "6" "DESCONECTAR"          "cerrar sesiones"
        ui_opt_danger "7" "ELIMINAR CUENTA" "definitivo"
        ui_opt "0" "VOLVER"
        ui_solid
        ui_prompt "Elige una opción [0-7]"
        case "$REPLY_UI" in
            1) renovar_vigencia "$u" ;;
            2) cambiar_password "$u" ;;
            3) cambiar_limite "$u" ;;
            4) cambiar_salida "$u" ;;
            5) clear; print_title 2>/dev/null || true; ui_section "DATOS PARA EL CLIENTE" "$u"
               _ficha_cuenta "$u" "${pass:-—}" "$vence" "$lim" "$sal"; ui_solid; ui_pause ;;
            6) desconectar_cuenta "$u" ;;
            7) eliminar_usuario "$u" && return ;;
            0|"") return ;;
            *) ui_err "Opción no válida."; sleep 1 ;;
        esac
    done
}

# =========================================================
# ACCIONES SOBRE UNA CUENTA
# =========================================================

listar_usuarios() {
    clear
    print_title 2>/dev/null || true
    ui_section "LISTA DE CUENTAS"
    _tabla_usuarios
    ui_pause
}

eliminar_usuario() {
    if [ -z "${1:-}" ]; then
        clear; print_title 2>/dev/null || true; ui_section "ELIMINAR CUENTA"
    fi
    _cuenta_arg "${1:-}" "Número o nombre a ELIMINAR" || return 1
    local u="$USUARIO_RESUELTO"

    if ui_confirm "¿Eliminar la cuenta '$u' para siempre?" "n"; then
        _borrar_cuenta "$u"
        ui_ok "Cuenta ${WH}$u${CR} eliminada."
        sleep 2; return 0
    fi
    ui_info "Operación cancelada."; sleep 1
    return 1
}

_borrar_cuenta() {
    local u="$1"
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
    _snap_reset
}

# Borra de una vez las cuentas vencidas hace mas de N dias.
limpiar_vencidas() {
    clear
    print_title 2>/dev/null || true
    ui_section "LIMPIAR CUENTAS VENCIDAS"
    ui_blank
    local margen u d n=0
    ui_prompt "Borrar las vencidas hace al menos cuántos días (Enter = 7)"
    margen="${REPLY_UI:-7}"
    [[ "$margen" =~ ^[0-9]+$ ]] || { ui_err "Número no válido."; sleep 2; return; }

    local -a lista=()
    _snap_reset; _snap_load
    while IFS='|' read -r u _ d _; do
        [ -z "$u" ] || [ "$d" = "inf" ] && continue
        [ "$d" -le $(( -margen )) ] && lista+=("$u")
    done <<<"$_SNAP"

    if [ ${#lista[@]} -eq 0 ]; then
        ui_ok "No hay cuentas vencidas hace ${margen} días o más."; ui_pause; return
    fi
    echo -e "${UI_PAD}${WH}Se borrarán:${CR} ${lista[*]}"
    ui_blank
    ui_confirm "¿Borrar ${#lista[@]} cuenta(s)?" "n" || return
    for u in "${lista[@]}"; do _borrar_cuenta "$u"; n=$((n+1)); done
    ui_ok "${n} cuenta(s) eliminada(s)."
    ui_pause
}

renovar_vigencia() {
    if [ -z "${1:-}" ]; then
        clear; print_title 2>/dev/null || true
        ui_section "RENOVAR VIGENCIA" "los días se suman a lo que le queda"
    fi
    _cuenta_arg "${1:-}" || return
    local u="$USUARIO_RESUELTO" actual hoy dias nueva err

    ui_blank
    actual=$(_vence_iso "$u"); hoy=$(date +%Y-%m-%d)
    if [ "$actual" = "never" ]; then
        echo -e "${UI_PAD}${DM}${u} no tiene fecha de caducidad.${CR}"
    elif [[ ! "$actual" > "$hoy" ]]; then
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
    if err=$(usermod -e "$nueva" "$u" 2>&1); then
        ui_ok "Vigencia de ${WH}$u${CR} → ${CY}$nueva${CR} (+${dias} días)."
        # Una cuenta vencida pudo quedar con sesiones muertas a medias;
        # las cerramos para que la siguiente conexion entre limpia.
        if [ "$actual" != "never" ] && [[ ! "$actual" > "$hoy" ]]; then
            pkill -u "$u" sshd 2>/dev/null; pkill -u "$u" sshd-session 2>/dev/null; pkill -u "$u" dropbear 2>/dev/null
        fi
    else
        ui_err "No se pudo renovar: ${err:-usermod devolvio error}"
    fi
    _snap_reset
    sleep 2
}

cambiar_password() {
    if [ -z "${1:-}" ]; then
        clear; print_title 2>/dev/null || true; ui_section "CAMBIAR CONTRASEÑA"
    fi
    _cuenta_arg "${1:-}" || return
    local u="$USUARIO_RESUELTO"

    ui_blank
    ui_prompt "Nueva contraseña para $u (Enter = generar una)"
    local pass="$REPLY_UI"
    [ -z "$pass" ] && pass=$(_generar_clave)
    [[ "$pass" == *:* ]] && { ui_err "La contraseña no puede llevar ':'."; sleep 2; return; }

    echo "$u:$pass" | chpasswd
    _guardar_clave "$u" "$pass"
    ui_ok "Contraseña de ${WH}$u${CR} → ${WH}$pass${CR}"
    _snap_reset
    ui_pause
}

cambiar_limite() {
    if [ -z "${1:-}" ]; then
        clear; print_title 2>/dev/null || true
        ui_section "LÍMITE DE CONEXIONES" "cuántos dispositivos simultáneos"
    fi
    _cuenta_arg "${1:-}" || return
    local u="$USUARIO_RESUELTO"

    ui_blank
    ui_prompt "Nuevo límite de dispositivos para $u"
    local lim="$REPLY_UI"
    if [[ ! "$lim" =~ ^[0-9]+$ ]] || [ "$lim" -lt 1 ]; then ui_err "Valor inválido."; sleep 2; return; fi

    # El limite se guarda en el campo GECOS, que es de donde lo lee killer.sh
    usermod -c "$lim" "$u"
    ui_ok "Límite de ${WH}$u${CR} → ${CY}$lim${CR} dispositivo(s)."
    _snap_reset
    sleep 2
}

# Por donde sale una cuenta que ya existe.
cambiar_salida() {
    if [ -z "${1:-}" ]; then
        clear; print_title 2>/dev/null || true
        ui_section "SALIDA A INTERNET" "por dónde navega cada cuenta"
    fi
    if ! _hay_nodos; then
        ui_blank
        ui_warn "No hay nodos residenciales: todas las cuentas salen por la IP del VPS."
        echo -e "${UI_PAD}${DM}Registra uno en IP RESIDENCIAL.${CR}"
        ui_pause; return
    fi
    _cuenta_arg "${1:-}" || return
    local u="$USUARIO_RESUELTO"
    ui_blank
    echo -e "${UI_PAD}${WH}Salida para ${u}${CR}"
    _wgh_pick_exit "$(_wgh_user_node "$u")" || return
    _wgh_set_user_exit "$u" "$PICK_NODE"
    ui_pause
}

# Cierra las sesiones abiertas (p. ej. un dispositivo que no es suyo).
desconectar_cuenta() {
    local u="$1"
    ui_confirm "¿Cerrar todas las sesiones de $u? Podrá volver a entrar" "s" || return
    pkill -u "$u" sshd 2>/dev/null; pkill -u "$u" sshd-session 2>/dev/null; pkill -u "$u" dropbear 2>/dev/null
    ui_ok "Sesiones de $u cerradas."
    _snap_reset
    sleep 1
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

    local total=0 filas=0 u lim d s b marca
    _snap_reset; _snap_load
    while IFS='|' read -r u lim d s b _; do
        [ -z "$u" ] && continue
        if [ "$s" -gt 0 ]; then
            marca="${GR}▪${CR}"; [ "$((s + b))" -ge "$lim" ] && marca="${RD}▪${CR}"
            printf "${UI_PAD}%b${WH}%-15s${CR} ${CY}%-14s${CR} ${GR}%-10s${CR} ${DM}%s${CR}\n" "$marca" "${u:0:15}" "SSH" "$s" "$lim"
            total=$((total + s)); filas=$((filas + 1))
        fi
        if [ "$b" -gt 0 ]; then
            marca="${GR}▪${CR}"; [ "$((s + b))" -ge "$lim" ] && marca="${RD}▪${CR}"
            printf "${UI_PAD}%b${WH}%-15s${CR} ${CY}%-14s${CR} ${GR}%-10s${CR} ${DM}%s${CR}\n" "$marca" "${u:0:15}" "Dropbear" "$b" "$lim"
            total=$((total + b)); filas=$((filas + 1))
        fi
    done <<<"$_SNAP"

    # OpenVPN — se lee del status log que haya dejado el servidor
    local status count user
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
