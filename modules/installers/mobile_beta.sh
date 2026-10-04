#!/bin/bash
# =========================================================
# MOVIL SIN ROOT — BETA
# ---------------------------------------------------------
# Un celular Android SIN root presta su IP a los usuarios del
# servidor que elijas.
#
# Como funciona (y por que no hace falta root):
#   El celular, desde Termux, abre UNA conexion SSH saliente al
#   VPS con 'ssh -R <puerto>' sin destino. OpenSSH convierte eso
#   en un SOCKS5 que vive en el VPS (127.0.0.1:<puerto>) y cuya
#   salida a Internet es el celular. Como la conexion la abre el
#   celular hacia fuera, funciona detras del CGNAT del operador y
#   sin abrir puertos. En el VPS, redsocks mete por ese SOCKS el
#   trafico TCP de los usuarios asignados.
#
#   Usuario SSH ─▶ VPS (marca por UID) ─▶ redsocks ─▶ SOCKS ─┐
#                                                     ssh -R │
#                         Internet ◀── celular (Termux) ◀────┘
#
# Limites que no dependen del codigo:
#   · Solo TCP (web y apps). El UDP sale por el VPS.
#   · La velocidad maxima es la SUBIDA del celular.
#   · Cada MB del cliente gasta 2 MB del plan (bajada + subida).
#   · Android puede matar Termux: ver la GUIA de este menu.
#
# Que cambia respecto al nodo movil del gateway: no hace falta
# instalar el proyecto del nodo. El VPS genera la llave, la
# restringe a SU puerto (permitlisten) y da un solo bloque para
# pegar en Termux. Los celulares de aqui son nodos normales del
# gateway: el vigilante, los respaldos y el diagnostico los ven.
# =========================================================

_MB_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$_MB_DIR/../ui.sh"
declare -F _wgh_nodes_list >/dev/null 2>&1 || source "$_MB_DIR/wg_home.sh"

MB_KEYS="/var/lib/vpsservice/movil-beta"

# ---------------------------------------------------------
# Piezas puras (se prueban sin root)
# ---------------------------------------------------------

# Script que corre en el celular: reconecta solo, sin fin.
#   _mbeta_phone_script <host> <puerto_ssh> <usuario> <puerto_socks>
# ServerAlive 10s x 3: si la red cae, ssh lo nota en ~30 s y vuelve
# a intentarlo; en el VPS, ClientAlive libera el puerto en lo mismo.
_mbeta_phone_script() {
    local host="$1" port="$2" user="$3" sport="$4"
    cat <<EOF
#!/data/data/com.termux/files/usr/bin/bash
# Nodo movil (beta) de VPSService: presta la IP de este celular.
cd "\$HOME/.vpsnodo" || exit 1
if [ -f pid ] && kill -0 "\$(cat pid)" 2>/dev/null; then exit 0; fi
echo \$\$ > pid
termux-wake-lock 2>/dev/null
while true; do
  ssh -N -T -i key -p ${port} \\
    -o ExitOnForwardFailure=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \\
    -o ConnectTimeout=15 -o BatchMode=yes \\
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=known_hosts \\
    -R 127.0.0.1:${sport} ${user}@${host} >>log 2>&1
  echo "\$(date '+%F %T') desconectado, reintento en 5 s" >>log
  tail -n 200 log > log.tmp 2>/dev/null && mv log.tmp log
  sleep 5
done
EOF
}

# Linea de authorized_keys: solo puede abrir SU puerto, en local.
_mbeta_ak_line() {
    echo "restrict,port-forwarding,permitlisten=\"127.0.0.1:$1\" $2"
}

# Bloque para pegar en Termux. Llave y script viajan en base64:
# asi no hay comillas ni saltos de linea que se rompan al copiar.
#   _mbeta_paste_cmd <llave_b64> <script_b64>
_mbeta_paste_cmd() {
    echo "pkg install -y openssh && mkdir -p ~/.vpsnodo && cd ~/.vpsnodo && echo $1 | base64 -d > key && chmod 600 key && echo $2 | base64 -d > nodo.sh && chmod 700 nodo.sh && mkdir -p ~/.termux/boot && cp nodo.sh ~/.termux/boot/vpsnodo && (nohup ~/.vpsnodo/nodo.sh >/dev/null 2>&1 &) && echo NODO-LISTO"
}

# "1h 05m" a partir de segundos
_mbeta_dur() {
    local s="${1:-0}"
    if   [ "$s" -ge 86400 ]; then echo "$((s/86400))d $((s%86400/3600))h"
    elif [ "$s" -ge 3600 ];  then printf '%dh %02dm\n' $((s/3600)) $((s%3600/60))
    else                          echo "$((s/60))m $((s%60))s"; fi
}

# ---------------------------------------------------------
# Estado
# ---------------------------------------------------------
_mbeta_key_of() { echo "${MB_KEYS}/$1.key"; }

# Segundos que lleva conectado el celular (vacio si no lo esta)
_mbeta_uptime() {
    local idx="$1"
    _socks_reverse_up "$idx" || return 0
    ps -u "$(_wgn_socksuser "$idx")" -o etimes=,comm= 2>/dev/null \
        | awk '$2 ~ /^sshd/ {print $1; exit}'
}

# Lista "nombre|indice" de los nodos movil
_mbeta_nodes() {
    _wgh_nodes_list 2>/dev/null | awk -F'|' '$4=="socks" {print $1 "|" $3}'
}

# Elige un celular. Deja nombre e indice en MB_NAME / MB_IDX.
_mbeta_pick() {
    local -a ns=()
    local line i=0 n x
    while IFS= read -r line; do ns+=("$line"); done < <(_mbeta_nodes)
    if [ ${#ns[@]} -eq 0 ]; then ui_warn "Todavía no hay ningún celular."; sleep 2; return 1; fi
    if [ ${#ns[@]} -eq 1 ]; then MB_NAME="${ns[0]%%|*}"; MB_IDX="${ns[0]##*|}"; return 0; fi
    for x in "${ns[@]}"; do i=$((i+1)); echo -e "${UI_PAD}${CY}[$i]${CR} ${WH}${x%%|*}${CR}"; done
    ui_prompt "¿Qué celular? [1-${i}] (Enter = volver)"
    n="$REPLY_UI"
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$i" ] || return 1
    MB_NAME="${ns[$((n-1))]%%|*}"; MB_IDX="${ns[$((n-1))]##*|}"
}

# ---------------------------------------------------------
# Pantallas
# ---------------------------------------------------------

# Muestra (y guarda en /root) el bloque para el celular.
_mbeta_show_phone() {
    local name="$1" idx="$2" key host port user sport kb64 sb64 cmd file
    key=$(_mbeta_key_of "$name")
    clear
    print_title 2>/dev/null || true
    ui_section "CONFIGURAR EL CELULAR: ${name}" "beta"
    ui_blank
    if [ ! -f "$key" ]; then
        ui_warn "Este celular se registró con el nodo completo (su propia llave)."
        echo -e "${UI_PAD}${DM}Configúralo desde la app del nodo, o elimínalo y añádelo de nuevo aquí.${CR}"
        ui_pause; return
    fi
    host=$(_wgh_get_droplet_ip)
    if [ -z "$host" ]; then
        ui_err "No se pudo averiguar la IP pública del VPS."
        echo -e "${UI_PAD}${DM}Fíjala en GATEWAY RESIDENCIAL > AVANZADO > DIRECCIÓN PÚBLICA.${CR}"
        ui_pause; return
    fi
    port=$(_socks_ssh_port); user=$(_wgn_socksuser "$idx"); sport=$(_wgn_socksport "$idx")
    kb64=$(base64 -w0 < "$key")
    sb64=$(_mbeta_phone_script "$host" "$port" "$user" "$sport" | base64 -w0)
    cmd=$(_mbeta_paste_cmd "$kb64" "$sb64")
    file="/root/movil-${name}.txt"
    printf '%s\n' "$cmd" > "$file"; chmod 600 "$file"

    echo -e "${UI_PAD}${WH}1.${CR} Instala ${WH}Termux${CR} desde ${WH}F-Droid${CR} ${DM}(la de Play Store está desactualizada).${CR}"
    echo -e "${UI_PAD}${WH}2.${CR} Abre Termux, pega TODO este bloque y pulsa Enter:"
    ui_rule
    echo "$cmd"
    ui_rule
    echo -e "${UI_PAD}${DM}También está guardado en ${WH}${file}${DM} (cópialo por SFTP si no cabe).${CR}"
    echo -e "${UI_PAD}${WH}3.${CR} Cuando diga ${GR}NODO-LISTO${CR}, revisa aquí que salga ${GR}conectado${CR}."
    echo -e "${UI_PAD}${WH}4.${CR} Sigue la ${WH}GUÍA ANDROID${CR} de este menú para que el sistema no lo duerma."
    ui_blank
    echo -e "${UI_PAD}${DM}La llave solo sirve para abrir el puerto ${sport} de este VPS en local:${CR}"
    echo -e "${UI_PAD}${DM}no da acceso a una consola ni a nada más.${CR}"
    ui_pause
}

# Pregunta que usuarios saldran por este celular (varios a la vez).
_mbeta_assign() {
    local name="$1" u i=0 x sel cur
    local -a us=()
    while IFS= read -r u; do [ -n "$u" ] && us+=("$u"); done < <(_wgh_get_client_users | cut -d: -f1)
    if [ ${#us[@]} -eq 0 ]; then ui_warn "Aún no hay cuentas de cliente. Créalas y asígnalas después."; return; fi
    ui_blank
    echo -e "${UI_PAD}${WH}¿Qué usuarios saldrán con la IP de ${name}?${CR}"
    for u in "${us[@]}"; do
        i=$((i+1)); cur=$(_wgh_user_node "$u")
        printf "${UI_PAD}${CY}[%2d]${CR} ${WH}%-16s${CR} ${DM}%s${CR}\n" "$i" "$u" "${cur:+ahora: $cur}"
    done
    ui_prompt "Números separados por comas, 't' = todos (Enter = ninguno)"
    sel="$REPLY_UI"
    [ -z "$sel" ] && return
    [ "$sel" = "t" ] || [ "$sel" = "T" ] && sel=$(seq -s, 1 "$i")
    for x in ${sel//,/ }; do
        [[ "$x" =~ ^[0-9]+$ ]] && [ "$x" -ge 1 ] && [ "$x" -le "$i" ] || continue
        _wgh_user_assign "${us[$((x-1))]}" "$name"
        ui_ok "${us[$((x-1))]} saldrá por ${name}."
    done
    ui_info "Aplicando..."
    if [ -f "$WGH_ROUTING_FLAG" ] || _wgh_routing_is_active; then
        _wgh_apply_user_routing >/dev/null 2>&1
    else
        _wgh_routing_enable
    fi
}

mobile_beta_add() {
    clear
    print_title 2>/dev/null || true
    ui_section "AÑADIR CELULAR SIN ROOT" "beta"
    ui_blank
    ui_info "Preparando el VPS (redsocks)..."
    if ! _socks_install_deps; then
        ui_err "No se pudo instalar redsocks. Revisa la conexión del VPS."; ui_pause; return
    fi

    local name idx user sport key
    while true; do
        ui_prompt "Nombre corto del celular (ej: movil1) (Enter = cancelar)"
        name=$(echo "$REPLY_UI" | tr -cd 'A-Za-z0-9_-' | cut -c1-13)
        [ -z "$REPLY_UI" ] && return
        [ -z "$name" ] && { ui_err "Usa letras, números, - o _."; continue; }
        _wgh_node_exists "$name" && { ui_err "Ya existe un nodo con ese nombre."; continue; }
        break
    done

    idx=$(_wgh_nodes_add "$name" "pendiente" "socks")
    [ -z "$idx" ] && { ui_err "No quedan huecos (máximo 16 nodos)."; ui_pause; return; }
    user=$(_wgn_socksuser "$idx"); sport=$(_wgn_socksport "$idx")

    # Llave generada en el VPS: el celular no tiene que generar ni
    # devolver nada, solo pegar un bloque.
    mkdir -p "$MB_KEYS" && chmod 700 "$MB_KEYS"
    key=$(_mbeta_key_of "$name")
    rm -f "$key" "$key.pub"
    if ! ssh-keygen -q -t ed25519 -N "" -C "movil-beta@${name}" -f "$key" &>/dev/null; then
        ui_err "No se pudo generar la llave."; _wgh_nodes_del "$name"; ui_pause; return
    fi
    chmod 600 "$key"

    _socks_user_ensure "$idx" ""
    local home ak pub tmp
    home=$(getent passwd "$user" | cut -d: -f6); ak="$home/.ssh/authorized_keys"
    pub=$(cat "$key.pub")
    _mbeta_ak_line "$sport" "$pub" > "$ak"
    chown "$user":"$user" "$ak"; chmod 600 "$ak"

    tmp=$(mktemp)
    _wgh_nodes_list | awk -F'|' -v n="$name" -v k="$pub" 'BEGIN{OFS="|"} $1==n{$2=k} {print}' > "$tmp"
    mv "$tmp" "$WGH_NODES_CONF"; chmod 600 "$WGH_NODES_CONF"
    _socks_up "$idx" >/dev/null 2>&1
    _wgh_log "Movil beta '${name}' (indice ${idx}) registrado"

    ui_ok "Celular '${name}' registrado (usuario ${user}, puerto ${sport})."
    _mbeta_assign "$name"
    ui_pause
    _mbeta_show_phone "$name" "$idx"
}

mobile_beta_test() {
    _mbeta_pick || return
    local name="$MB_NAME" idx="$MB_IDX" up ip vps probe r4 r6 sp
    clear
    print_title 2>/dev/null || true
    ui_section "PROBAR CELULAR: ${name}" "beta"
    ui_blank
    vps=$(_wgh_get_droplet_ip)
    up=$(_mbeta_uptime "$idx")
    if [ -z "$up" ]; then
        ui_err "El celular no está conectado."
        echo -e "${UI_PAD}${DM}En Termux: ${WH}~/.vpsnodo/nodo.sh${DM}  ·  log: ${WH}tail ~/.vpsnodo/log${CR}"
        ui_pause; return
    fi
    ui_ok "Conectado desde hace $(_mbeta_dur "$up")."
    _socks_redsocks_up "$idx" && ui_ok "redsocks activo." || ui_err "redsocks caído: $(_socks_redunit "$idx")"

    ui_info "Saliendo por el celular..."
    ip=$(_socks_probe_ip "$idx")
    if [ -z "$ip" ]; then ui_err "Conectado pero sin salida: ¿el celular tiene datos?"
    elif [ "$ip" = "$vps" ]; then ui_err "Da la IP del VPS (${ip}): algo está mal."
    else ui_ok "IP del celular: ${WH}${ip}${CR}"; fi

    probe=$(_wgh_node_users "$name" | head -1)
    if [ -z "$probe" ]; then
        ui_warn "Ningún usuario asignado: asígnalos para que usen esta IP."
    elif ! _wgh_routing_is_active; then
        ui_warn "La salida residencial está apagada: los usuarios aún salen por el VPS."
    else
        ui_info "Saliendo como '${probe}' (lo mismo que verá el cliente)..."
        r4=$(runuser -u "$probe" -- curl -4 -s --max-time 15 https://api.ipify.org 2>/dev/null)
        if [ -n "$r4" ] && [ "$r4" != "$vps" ]; then ui_ok "IPv4: ${r4}"
        else ui_err "IPv4: ${r4:-sin respuesta} — no sale por el celular. Revisa el DIAGNÓSTICO del gateway."; fi
        if _wgh_has_ipv6; then
            r6=$(runuser -u "$probe" -- curl -6 -s --max-time 8 https://api64.ipify.org 2>/dev/null)
            [ -z "$r6" ] && ui_ok "IPv6 bloqueado: no se escapa por el VPS." \
                         || ui_err "IPv6 sale por el VPS (${r6}). Apaga y enciende la salida residencial."
        fi
    fi

    ui_blank
    if ui_confirm "¿Medir la velocidad? (gasta unos 10 MB del plan del celular)" "n"; then
        sp=$(curl -s -o /dev/null --max-time 20 -w '%{speed_download}' \
             --socks5-hostname "127.0.0.1:$(_wgn_socksport "$idx")" \
             "https://speed.cloudflare.com/__down?bytes=5000000" 2>/dev/null)
        sp=${sp%%.*}
        if [ "${sp:-0}" -gt 0 ] 2>/dev/null; then
            ui_ok "Velocidad hacia tus clientes: ${WH}$(( sp * 8 / 1000000 )).$(( sp * 8 % 1000000 / 100000 )) Mbps${CR}"
            echo -e "${UI_PAD}${DM}Es el límite real: se reparte entre todos los usuarios de este celular.${CR}"
        else
            ui_err "No se pudo medir."
        fi
    fi
    ui_pause
}

mobile_beta_guide() {
    clear
    print_title 2>/dev/null || true
    ui_section "GUÍA ANDROID" "que el sistema no duerma al celular"
    ui_blank
    echo -e "${UI_PAD}${YL}Imprescindible${CR}"
    echo -e "${UI_PAD}${WH}·${CR} Termux de ${WH}F-Droid${CR} y ${WH}Termux:Boot${CR} (también de F-Droid)."
    echo -e "${UI_PAD}  ${DM}Abre Termux:Boot una vez: así el nodo arranca al encender.${CR}"
    echo -e "${UI_PAD}${WH}·${CR} Ajustes > Apps > Termux > Batería: ${WH}Sin restricciones${CR}."
    echo -e "${UI_PAD}${WH}·${CR} Deja la notificación de Termux con el ${WH}wake lock${CR} activo."
    ui_blank
    echo -e "${UI_PAD}${YL}Android 12 o superior${CR} ${DM}(sin esto Android mata el nodo al rato)${CR}"
    echo -e "${UI_PAD}${DM}Opciones de desarrollador > ${WH}Desactivar restricciones de procesos secundarios${CR}"
    echo -e "${UI_PAD}${DM}Si no aparece, desde un PC con adb (no hace falta root):${CR}"
    echo -e "${UI_PAD}${WH}adb shell settings put global settings_enable_monitor_phantom_procs false${CR}"
    ui_blank
    echo -e "${UI_PAD}${YL}Para que rinda${CR}"
    echo -e "${UI_PAD}${WH}·${CR} Mejor enchufado y con buena cobertura: la velocidad es la de ${WH}subida${CR}."
    echo -e "${UI_PAD}${WH}·${CR} Plan con datos de sobra: cada MB del cliente gasta 2 MB del celular."
    echo -e "${UI_PAD}${WH}·${CR} Pocos usuarios por celular (1 a 5) y uso ligero."
    ui_blank
    echo -e "${UI_PAD}${YL}Comandos útiles en Termux${CR}"
    echo -e "${UI_PAD}${WH}~/.vpsnodo/nodo.sh${CR}        ${DM}arrancar a mano${CR}"
    echo -e "${UI_PAD}${WH}tail ~/.vpsnodo/log${CR}       ${DM}ver por qué se desconecta${CR}"
    echo -e "${UI_PAD}${WH}pkill -f vpsnodo${CR}          ${DM}pararlo${CR}"
    ui_solid
    ui_pause
}

mobile_beta_remove() {
    _mbeta_pick || return
    local name="$MB_NAME"
    ui_confirm "¿Eliminar '${name}'? Sus usuarios volverán a la IP del VPS" "n" || return
    _wgh_nodes_del "$name"
    rm -f "$(_mbeta_key_of "$name")" "$(_mbeta_key_of "$name").pub" "/root/movil-${name}.txt"
    { [ -f "$WGH_ROUTING_FLAG" ] || _wgh_routing_is_active; } && _wgh_apply_user_routing >/dev/null 2>&1
    ui_ok "Celular eliminado."
    sleep 2
}

mobile_beta_menu() {
    while true; do
        clear
        print_title 2>/dev/null || true
        ui_section "MÓVIL SIN ROOT  ·  BETA" "un celular Android presta su IP a tus usuarios"
        ui_blank

        local line name idx up nu n=0
        printf "${UI_PAD}${DM}%-14s %-22s %s${CR}\n" "CELULAR" "ESTADO" "USUARIOS"
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            n=$((n+1)); name="${line%%|*}"; idx="${line##*|}"
            up=$(_mbeta_uptime "$idx")
            nu=$(_wgh_node_users "$name" | wc -l)
            if [ -n "$up" ]; then
                printf "${UI_PAD}${WH}%-14s${CR} ${GR}%-22s${CR} ${CY}%s${CR}\n" "$name" "conectado $(_mbeta_dur "$up")" "$nu"
            else
                printf "${UI_PAD}${WH}%-14s${CR} ${RD}%-22s${CR} ${CY}%s${CR}\n" "$name" "desconectado" "$nu"
            fi
        done < <(_mbeta_nodes)
        [ "$n" -eq 0 ] && echo -e "${UI_PAD}${DM}Ningún celular todavía. Empieza por la opción 1.${CR}"
        ui_rule
        echo -e "${UI_PAD}${DM}Solo TCP (web y apps). Velocidad = subida del celular. Si se${CR}"
        echo -e "${UI_PAD}${DM}desconecta, sus usuarios pasan solos a la IP del VPS.${CR}"
        ui_blank

        ui_opt "1" "AÑADIR CELULAR"     "asistente"
        ui_opt "2" "COMANDO TERMUX"     "volver a verlo"
        ui_opt "3" "ASIGNAR USUARIOS"   "quién usa su IP"
        ui_opt "4" "PROBAR"             "IP y velocidad"
        ui_opt "5" "GUÍA ANDROID"       "que no se duerma"
        ui_opt_danger "6" "ELIMINAR CELULAR" "usuarios -> IP VPS"
        ui_blank
        ui_opt "0" "VOLVER"
        ui_solid
        ui_prompt "Elige una opción [0-6]"

        case "$REPLY_UI" in
            1) mobile_beta_add ;;
            2) _mbeta_pick && _mbeta_show_phone "$MB_NAME" "$MB_IDX" ;;
            3) _mbeta_pick && { _mbeta_assign "$MB_NAME"; ui_pause; } ;;
            4) mobile_beta_test ;;
            5) mobile_beta_guide ;;
            6) mobile_beta_remove ;;
            0|"") break ;;
            *) ui_err "Opción no válida."; sleep 1 ;;
        esac
    done
}
