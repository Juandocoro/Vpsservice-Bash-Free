#!/bin/bash
# =========================================================
# PRUEBAS DEL PANEL
# ---------------------------------------------------------
#   bash tests/run.sh
#
# No hacen falta permisos ni red: se prueba la logica pura y
# se hacen comprobaciones estaticas sobre el codigo.
#
# Lo que NO cubren, y conviene tener presente: nada que
# dependa de root, de iptables reales, de una interfaz
# WireGuard viva o de un VPS de verdad. Eso solo se puede
# comprobar sobre la maquina, y estas pruebas pasando no
# significan que el gateway de Internet.
# =========================================================
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT=$(pwd)

G="\033[1;32m"; R="\033[1;31m"; Y="\033[1;33m"; D="\033[2;37m"; C="\033[0m"
OK=0; FAIL=0; FAILED=()

ok()   { OK=$((OK+1)); printf "  ${G}✓${C} %s\n" "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED+=("$1"); printf "  ${R}✗${C} %s\n" "$1"; [ -n "${2:-}" ] && printf "      ${D}%s${C}\n" "$2"; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "esperaba '$3', obtuve '$2'"; }
group(){ printf "\n${Y}── %s ──${C}\n" "$1"; }

# =========================================================
group "Sintaxis"
# =========================================================
while read -r f; do
    if err=$(bash -n "$f" 2>&1); then ok "$(basename "$f")"; else bad "$(basename "$f")" "$err"; fi
done < <(find . -name '*.sh' -not -path './.git/*' | sort)

# =========================================================
group "Funciones invocadas pero no definidas"
# ---------------------------------------------------------
# Esta comprobacion habria cazado sola varios fallos reales:
# un refactor que dejo llamadas a funciones ya borradas, y un
# ui_confirm que solo existia en el otro repositorio.
# =========================================================
_defined() { grep -hoE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$@" 2>/dev/null | tr -d '()'; }
ALL_SH=$(find . -name '*.sh' -not -path './.git/*' -not -path './tests/*')
# shellcheck disable=SC2086
DEF=$(_defined $ALL_SH | sort -u)
# Se descartan las coincidencias que forman parte de una ruta
# (/etc/wireguard/wghome_droplet_private.key no es una llamada).
USED=$(grep -rhoP '(?<![\w/])(_wgh?[a-z0-9_]+|wghome_[a-z0-9_]+|_mbeta_[a-z0-9_]+|mobile_beta_[a-z0-9_]+|ui_[a-z0-9_]+)(?![\w./])' $ALL_SH | sort -u)
MISSING=""
while read -r fn; do
    [ -z "$fn" ] && continue
    grep -qx "$fn" <<<"$DEF" || MISSING="$MISSING $fn"
done <<<"$USED"
if [ -z "$MISSING" ]; then ok "todas las funciones internas existen"
else bad "hay funciones sin definir" "$MISSING"; fi

# Una funcion definida dos veces no da error: gana la ULTIMA en
# silencio, y un menu viejo puede tapar al nuevo sin que se note.
# shellcheck disable=SC2086
DUP=$(for f in main.sh modules/*.sh modules/installers/wg_home.sh modules/installers/mobile_beta.sh; do
        grep -oE '^(function )?[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$f"; done | sed 's/function //' | sort | uniq -d)
if [ -z "$DUP" ]; then ok "ninguna funcion definida dos veces"
else bad "funciones definidas dos veces" "$DUP"; fi

# =========================================================
group "Direcciones fijas en el codigo"
# ---------------------------------------------------------
# Una IP publica escrita a mano como valor de reserva hizo que
# el panel anunciara la direccion de otra maquina y que los
# nodos abrieran el tunel contra un servidor ajeno.
# =========================================================
HARD=$(grep -rnoE '\b(([0-9]{1,3}\.){3}[0-9]{1,3})\b' $ALL_SH \
       | grep -vE '(^|[^0-9])(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.|0\.0\.0\.0|255\.)' \
       | grep -vE '\b(8\.8\.8\.8|8\.8\.4\.4|1\.1\.1\.1|1\.0\.0\.1|9\.9\.9\.9)\b' || true)
if [ -z "$HARD" ]; then ok "ninguna IP publica escrita a mano"
else bad "hay IPs publicas fijas" "$(echo "$HARD" | head -3)"; fi

# =========================================================
# Cargar el modulo para probar su logica
# =========================================================
source modules/ui.sh
source modules/installers/wg_home.sh
_wgh_log() { :; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
WGH_NODES_CONF="$TMP/nodes.conf"
WGH_USERS_CONF="$TMP/users.conf"
WGH_PEER_KEY="$TMP/legacy.key"

K1="AbCdEfGhIjKlMnOpQrStUvWxYz0123456789+/AbCd="
K2="xTvysc/veWy/vYMYdBZvMDp4z9UqN0phtY4CYVv+Wzg="

# =========================================================
group "Parametros derivados de cada nodo"
# =========================================================
is "nodo 1 conserva la interfaz de siempre" "$(_wgn_iface 1)" "wg-home"
is "nodo 1 conserva el puerto"              "$(_wgn_port 1)"  "51820"
is "nodo 1 conserva la tabla"               "$(_wgn_table 1)" "200"
is "nodo 1 conserva la marca"               "$(_wgn_mark 1)"  "0x77"
is "nodo 1 conserva la red"                 "$(_wgn_subnet 1)" "10.77.77.0/24"
is "nodo 2 usa otra interfaz"               "$(_wgn_iface 2)" "wg-home2"
is "nodo 2 usa otro puerto"                 "$(_wgn_port 2)"  "51821"
is "nodo 2 usa otra red"                    "$(_wgn_subnet 2)" "10.77.78.0/24"
is "la IP del VPS sale de la red del nodo"  "$(_wgn_vpsip 2)"  "10.77.78.1"
is "la IP del nodo sale de su red"          "$(_wgn_nodeip 2)" "10.77.78.2"

# Sin unicidad, dos nodos se pisarian sin que nada lo avisara.
for f in _wgn_iface _wgn_port _wgn_table _wgn_mark _wgn_vpsip; do
    vals=$(for i in $(seq 1 16); do $f "$i"; done)
    t=$(wc -l <<<"$vals"); u=$(sort -u <<<"$vals" | wc -l)
    is "$f no colisiona entre 16 nodos" "$u" "$t"
done

# =========================================================
group "Registro de nodos"
# =========================================================
echo "$K1" > "$WGH_PEER_KEY"
_wgh_nodes_migrate
is "el peer unico anterior se migra" "$(_wgh_nodes_count)" "1"
is "y queda como nodo 1"             "$(_wgh_node_idx_of nodo-1)" "1"

idx=$(_wgh_nodes_add movil "$K2")
is "el alta asigna el indice libre"  "$idx" "2"
is "ahora hay dos nodos"             "$(_wgh_nodes_count)" "2"
is "la clave se guarda intacta"      "$(_wgh_node_key_of movil)" "$K2"
_wgh_nodes_has_key "$K2" && ok "detecta una clave ya registrada" || bad "no detecta clave duplicada"
_wgh_node_exists movil && ok "encuentra un nodo por nombre" || bad "no encuentra el nodo"
_wgh_node_exists fantasma && bad "acepta un nodo inexistente" || ok "rechaza un nodo inexistente"

# =========================================================
group "Salida por usuario"
# =========================================================
_wgh_user_assign usuario1 nodo-1
_wgh_user_assign usuario2 movil
is "usuario1 sale por su nodo" "$(_wgh_user_node usuario1)" "nodo-1"
is "usuario2 sale por otro"    "$(_wgh_user_node usuario2)" "movil"
_wgh_user_assign usuario2 ""
is "quitar la asignacion lo devuelve al VPS" "$(_wgh_user_node usuario2)" ""
is "reasignar no duplica la linea" "$(grep -c '^usuario1|' "$WGH_USERS_CONF")" "1"

# Formato antiguo: una linea suelta, sin nodo, valia para la unica salida.
echo "viejo" >> "$WGH_USERS_CONF"
is "una linea del formato antiguo cae en el nodo 1" "$(_wgh_user_node viejo)" "nodo-1"

# =========================================================
group "Baja de un nodo"
# =========================================================
_wgh_node_down() { :; }   # no tocar el sistema al probar
_wgh_user_assign usuario3 movil
_wgh_nodes_del movil
is "el nodo desaparece del registro" "$(_wgh_nodes_count)" "1"
is "sus usuarios vuelven a la IP del VPS" "$(_wgh_user_node usuario3)" ""
is "el indice liberado se reutiliza" "$(_wgh_nodes_next_idx)" "2"

# =========================================================
group "Salud de los nodos: histeresis"
# ---------------------------------------------------------
# Sin histeresis, un microcorte de dos segundos rebotaria a los
# clientes de un nodo a otro sin parar: se nota mas que la caida.
# =========================================================
step() { _wgh_health_step "$1" "$2" "$3"; echo "$HS_ESTADO $HS_RACHA"; }
is "un fallo suelto no tumba el nodo"      "$(step up 0 0)"    "up 1"
is "dos fallos tampoco"                    "$(step up 1 0)"    "up 2"
is "al tercero se da por caido"            "$(step up 2 0)"    "down 0"
is "una medida buena limpia la racha"      "$(step up 2 1)"    "up 0"
is "caido, un acierto no basta"            "$(step down 0 1)"  "down 1"
is "al segundo acierto vuelve"             "$(step down 1 1)"  "up 0"
is "caido, un fallo lo mantiene caido"     "$(step down 3 0)"  "down 0"

# Un ciclo completo: cae y se recupera sin quedarse atascado.
e=up; r=0
for m in 0 0 0 0 1 1 1; do
    _wgh_health_step "$e" "$r" "$m"; e="$HS_ESTADO"; r="$HS_RACHA"
done
is "tras caer y volver, termina arriba" "$e" "up"

group "Tolerancia al silencio segun el keepalive"
# Se deduce del keepalive que el kernel dice que tiene pactado cada
# peer: un nodo de 5s se detecta rapido y uno de 25s no da falsos
# positivos, sin configurar nada a mano.
is "keepalive 5s  -> 15s de margen" "$(_wgh_silence_for 5)"  "15"
is "keepalive 25s -> 55s de margen" "$(_wgh_silence_for 25)" "55"
is "keepalive 0 se trata como 25"   "$(_wgh_silence_for 0)"  "55"
is "nunca baja de 12s"              "$(_wgh_silence_for 1)"  "12"

group "Nodo de respaldo"
# El respaldo va en el 5o campo: el 4o es el tipo, y pisarlo
# convertiria un nodo socks en uno wg sin avisar.
: > "$WGH_NODES_CONF"
_wgh_nodes_add pc   "$K1" wg    >/dev/null
_wgh_nodes_add movil "$K2" socks >/dev/null
_wgh_node_set_backup movil pc
is "el respaldo se guarda"          "$(_wgh_node_backup_of movil)" "pc"
is "y el tipo NO se pisa"           "$(_wgh_node_type movil)"      "socks"
is "el otro nodo conserva su tipo"  "$(_wgh_node_type pc)"         "wg"
is "sin respaldo definido, vacio"   "$(_wgh_node_backup_of pc)"    ""

# Al borrar un nodo, quien lo tuviera de respaldo no puede quedarse
# apuntando a una tabla que ya no existe.
_wgh_node_down() { :; }
_wgh_nodes_del pc
is "el respaldo huerfano se limpia" "$(_wgh_node_backup_of movil)" ""

# =========================================================
group "El vigilante arranca de verdad"
# ---------------------------------------------------------
# El servicio llamaba a 'wg_home.sh --watchdog' y el script no
# leia el argumento: cargaba funciones y terminaba. El panel
# decia [ON] y no se vigilaba nada.
# =========================================================
grep -qE -- '--watchdog\)\s+wghome_watchdog_loop' modules/installers/wg_home.sh \
    && ok "--watchdog lanza el bucle del vigilante" || bad "--watchdog no lanza el vigilante"
grep -qE -- '--restore\)\s+wghome_restore' modules/installers/wg_home.sh \
    && ok "--restore rehace la salida tras un reinicio" || bad "falta --restore"
bash modules/installers/wg_home.sh --nada >/dev/null 2>&1; rc=$?
is "un argumento desconocido no se ignora en silencio" "$rc" "2"
grep -q 'wg_home.sh --watchdog' modules/installers/wg_home.sh \
    && ok "la unidad de systemd usa ese argumento" || bad "la unidad no llama a --watchdog"

# =========================================================
group "Registro con respaldo (5 campos)"
# ---------------------------------------------------------
# Al fijar un respaldo todas las lineas pasan a tener 5 campos.
# Un 'read nombre clave idx tipo' metia "socks|" en el tipo y un
# movil se trataba como WireGuard en todas partes.
# =========================================================
: > "$WGH_NODES_CONF"
_wgh_nodes_add pc    "$K1" wg    >/dev/null
_wgh_nodes_add movil "$K2" socks >/dev/null
_wgh_node_set_backup pc movil
is "el tipo se lee por indice (wg)"     "$(_wgh_idx_type 1)" "wg"
is "el tipo se lee por indice (socks)"  "$(_wgh_idx_type 2)" "socks"
tipos=$(while IFS='|' read -r n k i t _; do echo "$t"; done < <(_wgh_nodes_list) | paste -sd, -)
is "leer el registro no arrastra el 5o campo al tipo" "$tipos" "wg,socks"
if grep -nE "IFS='\|' read -r [a-z ]+; do" modules/installers/wg_home.sh | grep -vE ' (_|bk); do' >/dev/null; then
    bad "queda algun 'read' del registro sin variable de cola"
else
    ok "todas las lecturas del registro toleran campos de mas"
fi

group "Desvio al respaldo"
is "respaldo PC: regla de la marca del caido a la tabla del respaldo" \
   "$(_wgh_backup_cmd 2 1 wg)" "ip rule add fwmark 0x772 table 200 priority 1402"
is "respaldo movil: REDIRECT de la marca del caido a su redsocks" \
   "$(_wgh_backup_cmd 1 2 socks)" \
   "iptables -t nat -A OUTPUT -p tcp -m mark --mark 0x77 -m comment --comment HOMEVPN_SOCKS_BK -j REDIRECT --to-ports 12302"

# Reconciliar: se registran las llamadas en vez de tocar el sistema.
LLAMADAS=""
_wgh_node_path_on()  { LLAMADAS="$LLAMADAS on$1"; }
_wgh_node_path_off() { LLAMADAS="$LLAMADAS off$1"; }
_wgh_backup_on()     { LLAMADAS="$LLAMADAS bkon$1"; }
_wgh_backup_off()    { LLAMADAS="$LLAMADAS bkoff$1"; }
WGH_ROUTING_FLAG="$TMP/routing.on"; touch "$WGH_ROUTING_FLAG"
declare -A EST=([pc]=down [movil]=up)
_wgh_reconcile EST
is "nodo caido con respaldo vivo: se cierra y se desvia" "$LLAMADAS" " off1 bkon1 on2 bkoff2"
LLAMADAS=""; EST[movil]=down
_wgh_reconcile EST
is "si el respaldo tambien cae: a la IP del VPS" "$LLAMADAS" " off1 bkoff1 off2 bkoff2"
LLAMADAS=""; EST=([pc]=up [movil]=up)
_wgh_reconcile EST
is "al recuperarse vuelve a su nodo y se quita el desvio" "$LLAMADAS" " on1 bkoff1 on2 bkoff2"
rm -f "$WGH_ROUTING_FLAG"; LLAMADAS=""
_wgh_reconcile EST
is "con la salida apagada no se toca nada" "$LLAMADAS" ""

group "Keepalive 'off' del VPS"
# El VPS tiene PersistentKeepalive = 0 y el kernel lo escribe 'off'.
# Antes eso daba 12s de margen con nodos que hablan cada 25s.
is "'off' se trata como 25s -> 55s de margen" "$(_wgh_silence_for off)" "55"
_wgh_measure_calc 500 off 1030 500 1000
is "30s de silencio con keepalive 'off': sigue vivo" "$MED_OK" "1"
_wgh_measure_calc 500 off 1030 500 1000 20
is "si contesta a la sonda, a los 20s se da por caido" "$MED_OK" "0"
_wgh_measure_calc 501 off 1030 500 1000 20
is "bytes nuevos: vivo, y se apunta la hora" "$MED_OK $MED_TS" "1 1030"

# =========================================================
group "Fuga por IPv6"
# ---------------------------------------------------------
# Todo el desvio es IPv4. Si el VPS tiene IPv6, sshd conectaba
# primero por IPv6 y ese trafico salia con la IP del VPS.
# =========================================================
V6=$(_wgh_v6_rules "1001 1002" "22 443")
grep -q -- '-d ::1/128 -j RETURN' <<<"$V6" && ok "el loopback IPv6 no se toca" || bad "falta excluir ::1"
grep -q -- '-p tcp --sport 22 -j RETURN' <<<"$V6" && grep -q -- '--sport 443 -j RETURN' <<<"$V6" \
    && ok "las respuestas de la sesion SSH del cliente siguen por IPv6" || bad "se cortaria el tunel de un cliente IPv6"
is "se rechaza el TCP IPv6 de cada usuario enrutado" \
   "$(grep -c -- '-p tcp -m owner --uid-owner 100[12] -j REJECT --reject-with tcp-reset' <<<"$V6")" "2"
first_reject=$(grep -n REJECT <<<"$V6" | head -1 | cut -d: -f1)
last_return=$(grep -n RETURN <<<"$V6" | tail -1 | cut -d: -f1)
[ "$last_return" -lt "$first_reject" ] && ok "las excepciones van antes que los rechazos" || bad "un rechazo tapa una excepcion"
grep -q '_wgh_v6_apply "\$v6uids"' modules/installers/wg_home.sh && ok "se aplica junto al resto de reglas" || bad "el bloqueo IPv6 no se aplica"
grep -q '_wgh_v6_off' modules/installers/wg_home.sh && ok "y se retira al apagar la salida" || bad "el bloqueo IPv6 no se retira"
grep -q 'curl -6' modules/installers/wg_home.sh && ok "el diagnostico prueba tambien IPv6" || bad "el diagnostico solo mira IPv4"

# =========================================================
group "Movil sin root (beta)"
# =========================================================
source modules/installers/mobile_beta.sh
SCRIPT=$(_mbeta_phone_script vps.ejemplo 2222 snode3 11083)
grep -q -- '-R 127.0.0.1:11083 snode3@vps.ejemplo' <<<"$SCRIPT" && ok "publica su SOCKS en el puerto que le toca" || bad "puerto o usuario equivocados"
grep -q -- '-p 2222' <<<"$SCRIPT" && ok "usa el puerto SSH del VPS" || bad "no usa el puerto SSH"
grep -q 'ServerAliveInterval=10' <<<"$SCRIPT" && ok "detecta una red caida en ~30 s" || bad "deteccion lenta"
grep -q 'ExitOnForwardFailure=yes' <<<"$SCRIPT" && ok "si el puerto esta ocupado, reintenta en vez de quedarse colgado" || bad "falta ExitOnForwardFailure"
grep -q '^while true' <<<"$SCRIPT" && ok "se reconecta solo, sin fin" || bad "no reconecta"
grep -q 'termux-wake-lock' <<<"$SCRIPT" && ok "pide wake lock para que Android no lo duerma" || bad "sin wake lock"
bash -n <(echo "$SCRIPT") && ok "el script del celular es bash valido" || bad "el script del celular no compila"
is "la llave solo puede abrir SU puerto" "$(_mbeta_ak_line 11083 'ssh-ed25519 AAAA x')" \
   'restrict,port-forwarding,permitlisten="127.0.0.1:11083" ssh-ed25519 AAAA x'
CMD=$(_mbeta_paste_cmd "S0VZ" "$(echo "$SCRIPT" | base64 -w0)")
[ "$(wc -l <<<"$CMD")" = "1" ] && ok "el bloque de Termux es una sola linea" || bad "el bloque de Termux se parte"
echo "$SCRIPT" | base64 -w0 | base64 -d | cmp -s - <(echo "$SCRIPT") && ok "el script llega intacto en base64" || bad "base64 corrompe el script"
is "duracion legible" "$(_mbeta_dur 3725)" "1h 02m"

# =========================================================
group "Selector de salida (alta de cuentas)"
# =========================================================
_socks_reverse_up() { return 1; }; _wgh_node_is_up() { return 1; }
_wgh_pick_exit "" <<<"" >/dev/null 2>&1;  is "Enter = IP del VPS"      "$PICK_NODE" ""
_wgh_pick_exit "" <<<"2" >/dev/null 2>&1; is "por numero elige el nodo" "$PICK_NODE" "movil"
_wgh_pick_exit "" <<<"pc" >/dev/null 2>&1; is "tambien por nombre"     "$PICK_NODE" "pc"
_wgh_pick_exit "" <<<$'9\n1' >/dev/null 2>&1; is "un numero fuera de rango se vuelve a pedir" "$PICK_NODE" "pc"
_wgh_pick_exit "" <<<"c" >/dev/null 2>&1 && bad "cancelar no cancela" || ok "c cancela"

# =========================================================
group "Auto-killer: solo cierra lo que sobra"
# ---------------------------------------------------------
# Antes, al pasarse del limite, se cerraban TODAS las sesiones:
# una sesion fantasma + la reconexion = cliente cortado en bucle.
# =========================================================
source modules/killer.sh
SES=$'500 111\n5 222\n90 333'
is "limite 1: se cierran las dos mas antiguas"  "$(_killer_pick 1 <<<"$SES" | sort | paste -sd, -)" "111,333"
is "limite 2: solo la mas antigua"              "$(_killer_pick 2 <<<"$SES")" "111"
is "dentro del limite no se cierra nada"        "$(_killer_pick 3 <<<"$SES")" ""
grep -q 'grep -v "127' modules/killer.sh && bad "vuelve a ignorar las conexiones locales (WS/SSL)" \
    || ok "cuenta tambien las conexiones de WebSocket y SSL"

# =========================================================
group "Servicios caidos"
# =========================================================
source modules/network.sh
SHOW=$'Id=stunnel4.service\nActiveState=active\nUnitFileState=generated\n\nId=websocket_proxy.service\nActiveState=failed\nUnitFileState=enabled\n\nId=squid.service\nActiveState=inactive\nUnitFileState=disabled\n\nId=v2ray.service\nActiveState=inactive\nUnitFileState=\n'
is "detecta el habilitado y parado, ignora el resto" "$(_parse_services_down <<<"$SHOW")" "WebSocket"

group "Lo que podia dejar a los clientes sin servicio"
grep -vE '^\s*#' modules/network.sh | grep -q 'ufw reset' && bad "sync_firewall vuelve a hacer 'ufw reset'" \
    || ok "el cortafuegos ya no borra reglas ajenas"
sed -n '/--cron/,/exit 0/p' modules/optimize.sh | grep -qE 'swapoff|drop_caches' \
    && bad "la limpieza automatica vacia swap o cache" || ok "la limpieza automatica no toca swap ni cache"
sed -n '/^ssh_restart()/,/^}/p' modules/system.sh | grep -q 'sshd -t' \
    && ok "sshd no se reinicia sin validar su configuracion" || bad "ssh_restart no valida con sshd -t"
grep -q 'ListenAddress 127.0.0.1:22' modules/system.sh \
    && ok "al cambiar el puerto SSH, el 22 local sigue para SSL y WebSocket" || bad "cambiar el puerto SSH deja fuera a SSL/WS"
_socks_sshd_conf | grep -q 'ClientAliveInterval' \
    && ok "un movil sin cobertura se desconecta y libera su puerto" || bad "falta ClientAlive en los nodos movil"

# =========================================================
group "Renovar suma, no resta"
# =========================================================
source modules/users.sh 2>/dev/null
is "cuenta vigente: los dias se suman a su fecha" "$(_fecha_renovada 2026-10-10 30 2026-10-04)" "2026-11-09"
is "cuenta vencida: los dias cuentan desde hoy"   "$(_fecha_renovada 2026-09-01 30 2026-10-04)" "2026-11-03"
is "sin caducidad: desde hoy"                     "$(_fecha_renovada never 30 2026-10-04)"      "2026-11-03"
is "vence hoy: se suma a hoy"                     "$(_fecha_renovada 2026-10-04 1 2026-10-04)"  "2026-10-05"

group "Nombres de cuenta"
for n in cliente1 juan_p a-b; do _usuario_valido "$n" && ok "acepta '$n'" || bad "rechaza '$n'"; done
for n in Cliente 1abc ab "con espacio" 'x;rm'; do _usuario_valido "$n" && bad "acepta '$n'" || ok "rechaza '$n'"; done

# =========================================================
group "Resolucion de cuentas"
# =========================================================
source modules/users.sh 2>/dev/null
_listar_cuentas() { printf '%s\n' cliente1 cliente2; }
# El resolutor pregunta al sistema si la cuenta existe; aqui no
# existen, asi que se simula igual que se simula la lista.
id() { case "${2:-$1}" in cliente1|cliente2|root) return 0 ;; *) return 1 ;; esac; }
_resolver_usuario 1 >/dev/null 2>&1 && is "acepta el numero de fila" "$USUARIO_RESUELTO" "cliente1" \
    || bad "no acepta el numero de fila"
_resolver_usuario cliente2 >/dev/null 2>&1 && is "acepta el nombre" "$USUARIO_RESUELTO" "cliente2" \
    || bad "no acepta el nombre"
_resolver_usuario 9 >/dev/null 2>&1 && bad "acepta una fila inexistente" || ok "rechaza una fila inexistente"
# root existe en el sistema pero no es cuenta de cliente: aceptarlo
# habria dejado que ELIMINAR CUENTA ejecutara 'userdel -r root'.
_resolver_usuario root >/dev/null 2>&1 && bad "ACEPTA root" || ok "rechaza root"

# =========================================================
printf "\n%b\n" "$(ui_line "$Y" "━")"
if [ "$FAIL" -eq 0 ]; then
    printf " ${G}%d pruebas correctas${C}\n" "$OK"
else
    printf " ${G}%d correctas${C}  ${R}%d fallidas${C}\n" "$OK" "$FAIL"
    printf "${D}   %s${C}\n" "${FAILED[@]}"
fi
echo ""
echo -e "${D} Recuerda: no se prueba nada que dependa de root, de${C}"
echo -e "${D} iptables reales, de WireGuard vivo ni de un VPS. Que${C}"
echo -e "${D} esto pase no garantiza que el gateway de Internet.${C}"
exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"
