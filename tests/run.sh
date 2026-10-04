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
group "Foto de cuentas en una pasada"
# ---------------------------------------------------------
# Sustituye a ~6 procesos por cuenta en cada redibujado.
# =========================================================
HOY=$(( $(date +%s) / 86400 ))
printf '%s\n' "root:x:0:0:root:/root:/bin/bash" \
    "ana:x:1001:1001:2:/home/ana:/bin/bash" \
    "beto:x:1002:1002:x:/home/beto:/bin/bash" \
    "caro:x:1003:1003:1:/home/caro:/bin/bash" \
    "dani:x:1004:1004:3:/home/dani:/bin/bash" \
    "ubuntu:x:1000:1000::/home/ubuntu:/bin/bash" > "$TMP/passwd"
printf '%s\n' "ana:h:1:0:99999:7::$((HOY + 10)):" "beto:h:1:0:99999:7:::" \
    "caro:h:1:0:99999:7::${HOY}:" "dani:h:1:0:99999:7::$((HOY + 1)):" > "$TMP/shadow"
printf '%s\n' "ana:clave:con:dos" "caro:c4ro" > "$TMP/claves"
printf '%s\n' " 1001 sshd" " 1001 sshd-session" " 1001 dropbear" "    0 sshd" " 1003 bash" > "$TMP/ps"
FOTO=$(_cuentas_parse "$TMP/passwd" "$TMP/shadow" "$TMP/claves" "$TMP/ps" "$HOY")
is "solo cuentas de cliente, en el orden de passwd" "$(cut -d'|' -f1 <<<"$FOTO" | paste -sd, -)" "ana,beto,caro,dani"
is "ana: limite, dias, sesiones ssh y dropbear" "$(sed -n 1p <<<"$FOTO" | cut -d'|' -f1-5)" "ana|2|10|2|1"
is "una clave con ':' llega entera" "$(sed -n 1p <<<"$FOTO" | cut -d'|' -f6)" "clave:con:dos"
is "un limite no numerico se muestra como 1" "$(sed -n 2p <<<"$FOTO" | cut -d'|' -f2)" "1"
is "sin caducidad: inf / never" "$(sed -n 2p <<<"$FOTO" | cut -d'|' -f3,7)" "inf|never"
is "vence hoy = ya vencida (como la ve PAM)" "$(sed -n 3p <<<"$FOTO" | cut -d'|' -f3)" "0"
is "fecha legible sin gawk ni date" "$(sed -n 1p <<<"$FOTO" | cut -d'|' -f7)" "$(date -u -d "@$(( (HOY + 10) * 86400 ))" +%Y-%m-%d)"
is "estado: vencida"     "$(_estado_cuenta 0 | cut -d'|' -f1)"   "VENCIDO"
is "estado: ultimo dia"  "$(_estado_cuenta 1 | cut -d'|' -f1)"   "POR VENCER"
is "estado: sin fecha"   "$(_estado_cuenta inf | cut -d'|' -f1)" "ACTIVO"
_SNAP="$FOTO"; _SNAP_T="$SECONDS"
contar_cuentas
is "el tablero cuenta activas/por vencer/vencidas/vencen hoy" \
   "$USR_ACTIVAS/$USR_PORVENCER/$USR_VENCIDAS/$USR_VENCEN_HOY" "2/1/1/1"
_SNAP_T="$SECONDS"; contar_online
is "y las sesiones abiertas" "$ON_SSH/$ON_DROPBEAR" "2/1"

# =========================================================
group "Cada opcion de menu tiene su accion"
# ---------------------------------------------------------
# Una opcion que se pinta pero no esta en el 'case' cae en
# "opcion no valida": el admin la ve y no hace nada.
# =========================================================
SIN_ACCION=""
for f in main.sh modules/*.sh modules/installers/wg_home.sh modules/installers/mobile_beta.sh; do
    SIN_ACCION="$SIN_ACCION$(awk -v F="$f" '
        /^(function )?[a-zA-Z_]+\(\) *\{/ { if (fn != "") check(); fn = $0; delete op; delete cs; next }
        /ui_opt(_danger)? "/ { match($0, /ui_opt(_danger)? "[^"]*"/); k = substr($0, RSTART, RLENGTH); sub(/.*"(.*)"/, "", k)
                               k = substr($0, RSTART, RLENGTH); gsub(/^ui_opt(_danger)? "|"$/, "", k); op[k] = 1 }
        /^[ \t]*[^ \t()#]+\)/ { c = $0; sub(/^[ \t]*/, "", c); sub(/\).*/, "", c); n = split(c, alts, "|")
                               for (i = 1; i <= n; i++) { a = alts[i]; gsub(/"/, "", a)
                                 if (a ~ /^\[/) { cs[toupper(substr(a, 2, 1))] = 1; cs[tolower(substr(a, 2, 1))] = 1 } else cs[a] = 1 } }
        function check(   k) { for (k in op) if (!(k in cs)) printf " %s:%s[%s]", F, fn, k }
        END { if (fn != "") check() }' "$f")"
done
SIN_ACCION=$(sed 's/function //g; s/() *{//g' <<<"$SIN_ACCION")
[ -z "$SIN_ACCION" ] && ok "todas las opciones visibles hacen algo" || bad "opciones sin accion" "$SIN_ACCION"

# =========================================================
group "Instaladores: lo que podia tumbar el servicio"
# =========================================================
INST=modules/installers
grep -lE 'daybreakersx|Kurosaki|noobconner21' $INST/*.sh >/dev/null && bad "se descargan binarios de terceros" \
    || ok "ningun binario de repositorios de terceros"
grep -lE 'install[^#]*iptables-persistent|netfilter-persistent save|> */etc/iptables/rules' $INST/*.sh modules/*.sh >/dev/null \
    && bad "se usa iptables-persistent (choca con UFW)" || ok "sin iptables-persistent: no puede llevarse UFW por delante"
grep -q 'http_access allow all' $INST/squid_installer.sh && bad "Squid es un proxy abierto" || ok "Squid solo da paso hacia este VPS"
grep -v '^\s*#' $INST/shadowsocks_installer.sh | grep -q 'vpsservice2024' && bad "Shadowsocks con clave fija" || ok "Shadowsocks sin clave por defecto conocida"
grep -v '^\s*#' $INST/slowdns_installer.sh | grep -q 'riza/slowdns' && bad "SlowDNS apunta a un repo que no existe" || ok "SlowDNS ya no usa un repositorio inexistente"
grep -q 'bamsoftware.com/git/dnstt' $INST/slowdns_installer.sh && ok "SlowDNS se compila desde dnstt (lo que usan las apps)" || bad "SlowDNS sin dnstt"
grep -q 'ExecStart=$BIN server' $INST/udp_installer.sh && ok "UDP Custom arranca con 'server'" || bad "UDP Custom sin el subcomando server"
grep -q 'status-version 2' $INST/openvpn_installer.sh && ok "OpenVPN escribe el estado que lee el monitor" || bad "monitor de OpenVPN a cero"
grep -qF 'if [ -s "$EASYRSA_DIR/pki/ca.crt" ]' $INST/openvpn_installer.sh && ok "reinstalar OpenVPN conserva la PKI" || bad "reinstalar OpenVPN borra la PKI"
grep -q 'get_current_clients_json)' $INST/v2ray_installer.sh && ok "reinstalar V2Ray conserva los clientes" || bad "reinstalar V2Ray borra los clientes"
for f in $INST/*_installer.sh; do
    grep -qE 'curl -4 -s ifconfig\.me( |$|\))' "$f" && { bad "IP sin limite de tiempo en $(basename "$f")"; continue; }
done
ok "ningun instalador pide la IP sin limite de tiempo"

group "Puertos que UDP Custom no puede quedarse"
source $INST/udp_installer.sh
FAKE="$TMP/etc"; mkdir -p "$FAKE/wireguard" "$FAKE/openvpn" "$FAKE/shadowsocks-libev" "$FAKE/systemd/system"
echo "ListenPort = 51900" > "$FAKE/wireguard/wg0.conf"
printf 'port 1194\nproto udp\n' > "$FAKE/openvpn/server.conf"
echo '"server_port": 8388,' > "$FAKE/shadowsocks-libev/config.json"
touch "$FAKE/systemd/system/slowdns.service"
echo "ListenPort = 51821" > "$FAKE/wireguard/wg-home2.conf"
EXTRA="$TMP/extra.conf"; echo "7000:7010" > "$EXTRA"
PROT=$(_udpc_protected "$FAKE" | sort -u | paste -sd, -)
for p in 51820:51835 51900 1194 8388 5300 51821 7000:7010; do
    [[ ",$PROT," == *",$p,"* ]] && ok "protege $p" || bad "no protege $p" "$PROT"
done
printf 'port 1194\nproto tcp\n' > "$FAKE/openvpn/server.conf"
[[ ",$(_udpc_protected "$FAKE" | paste -sd, -)," == *",1194,"* ]] && bad "protege OpenVPN TCP (no hace falta)" || ok "OpenVPN por TCP no ocupa UDP"
RR=$(_udpc_rules 1 1194 5300)
is "primero el loopback" "$(sed -n 1p <<<"$RR")" "-A UDPC_PROTECT -i lo -j ACCEPT"
is "con SlowDNS, el 53 se le entrega" "$(sed -n 2p <<<"$RR")" "-A UDPC_PROTECT -p udp --dport 53 -j REDIRECT --to-ports 5300"
grep -q 'dport 53 ' <<<"$(_udpc_rules 0 1194)" && bad "sin SlowDNS se aparta el 53" || ok "sin SlowDNS el 53 queda para UDP Custom"

group "Piezas comunes de los instaladores"
source $INST/_common.sh
for p in 1 80 65535; do inst_port_valid "$p" && ok "puerto $p valido" || bad "rechaza el puerto $p"; done
for p in 0 65536 abc "8 0" -1; do inst_port_valid "$p" && bad "acepta '$p'" || ok "rechaza '$p'"; done

group "wg-home.conf del nodo 1"
WGH_PRIV_KEY="$TMP/priv.key"; echo "cHJpdmFkYXByaXZhZGFwcml2YWRhcHJpdmFkYTEyMzQ=" > "$WGH_PRIV_KEY"
: > "$WGH_NODES_CONF"; _wgh_nodes_add casa "$K1" wg >/dev/null
CONF1=$(_wgh_render_conf "$(cat "$WGH_PRIV_KEY")" "")
grep -q 'AllowedIPs *= 0.0.0.0/0' <<<"$CONF1" && ok "el nodo 1 recibe 0.0.0.0/0 (el retorno de Internet entra)" || bad "nodo 1 sin 0.0.0.0/0"
grep -q '/32' <<<"$CONF1" && bad "vuelve el /32 que descartaba el retorno" || ok "sin el /32 del modelo antiguo"
grep -q 'Table *= off' <<<"$CONF1" && ok "Table = off (no toca la tabla main)" || bad "falta Table = off"
grep -q 'n_port=$(_wgn_port "$n_idx")' modules/installers/wg_home.sh && ok "DATOS PARA EL NODO da el puerto de cada nodo" \
    || bad "DATOS PARA EL NODO da a todos el puerto del nodo 1"

group "Entrada de texto"
printf 'ab\\c1\n' | { ui_prompt x >/dev/null; is "una contraseña con barra invertida llega entera" "$REPLY_UI" 'ab\c1'; }

# =========================================================
group "Registro del formato v1 (IP en vez de indice)"
# ---------------------------------------------------------
# Con 'pc|clave|10.77.77.2|si' el panel tomaba la IP como indice:
# interfaz 'wg-home10.77.77.2', marca '0x7710.77.77.2'...
# =========================================================
WGH_RECONFIG="$TMP/reconfig"; rm -f "$WGH_RECONFIG"
printf '%s\n' "pc|$K1|10.77.77.2|si" "movil|$K2|10.77.77.3|no" > "$WGH_NODES_CONF"
_wgh_nodes_migrate
is "el 10.77.77.2 pasa a ser el nodo 1 (mismo sitio, no hay que tocarlo)" "$(_wgh_node_idx_of pc)" "1"
is "y queda como WireGuard"                     "$(_wgh_idx_type 1)" "wg"
is "el resto recibe un indice libre"            "$(_wgh_node_idx_of movil)" "2"
is "y se anota para reconfigurarlo"             "$(cat "$WGH_RECONFIG")" "movil"
is "la clave se conserva"                       "$(_wgh_node_key_of pc)" "$K1"
[ -f "$WGH_NODES_CONF.v1.bak" ] && ok "se guarda copia del registro antiguo" || bad "sin copia del registro antiguo"
is "la interfaz vuelve a ser wg-home"           "$(_wgn_iface "$(_wgh_node_idx_of pc)")" "wg-home"
printf '%s\n' "viejo" > "$WGH_USERS_CONF"
is "las asignaciones antiguas vuelven a salir por ese nodo" "$(_wgh_user_node viejo)" "pc"
cp "$WGH_NODES_CONF" "$TMP/antes"; _wgh_nodes_migrate
cmp -s "$WGH_NODES_CONF" "$TMP/antes" && ok "migrar dos veces no cambia nada" || bad "la migracion no es idempotente"
grep -q '_wgn_table_re' modules/installers/wg_home.sh && is "la tabla 200 se reconoce por su nombre" "$(_wgn_table_re 1)" "(200|homevpn)" \
    || bad "falta reconocer 'lookup homevpn'"

# =========================================================
group "Sonda de punta a punta: tunel vivo no es Internet"
# ---------------------------------------------------------
# Si en casa se cae el Internet pero el PC sigue conectado al VPS,
# los keepalives siguen llegando: el vigilante lo daba por sano y
# los usuarios se quedaban sin Internet indefinidamente.
# =========================================================
is "exito reciente: el nodo da Internet"        "$(_wgh_probe_verdict 1000 996 7)" "1"
is "sin exito en 7 s: el nodo NO da Internet"   "$(_wgh_probe_verdict 1000 990 7)" "0"
is "nunca contesto: no se juzga por la sonda"   "$(_wgh_probe_verdict 1000 "" 7)"  "?"
# Caso real: contador de bytes moviendose (keepalives) y sonda fallando.
_wgh_measure_calc 501 off 1000 500 990
is "el contador solo diria 'vivo'"              "$MED_OK" "1"
V=$(_wgh_probe_verdict 1000 980 7); [ "$V" != "?" ] && MED_OK="$V"
is "pero manda la sonda: caido"                 "$MED_OK" "0"
e=up; r=0
for t in 1 2 3; do _wgh_health_step "$e" "$r" 0; e="$HS_ESTADO"; r="$HS_RACHA"; done
is "a las 3 medidas malas se aparta el nodo"    "$e" "down"
grep -q '_wgh_probe_launch "$idx"' modules/installers/wg_home.sh && ok "el vigilante lanza la sonda" || bad "el vigilante no usa la sonda"
grep -q 'ping -c1 -W2 -I "$(_wgn_iface "$idx")" 1.1.1.1' modules/installers/wg_home.sh \
    && ok "la sonda sale por la interfaz del nodo (prueba aunque este apartado)" || bad "la sonda no sale por el nodo"

# =========================================================
group "La reparacion nunca corta un tunel vivo"
# ---------------------------------------------------------
# Con un registro sin nodo 1, la reparacion reescribia wg-home.conf
# sin peer y lo aplicaba en caliente: el tunel que funcionaba se caia.
# =========================================================
WGH_CONF="$TMP/wg-home.conf"
printf '[Interface]\nPrivateKey = x\n\n[Peer]\nPublicKey = %s\nAllowedIPs = 0.0.0.0/0\n' "$K1" > "$WGH_CONF"
cp "$WGH_CONF" "$TMP/wg-antes"
printf '%s\n' "movil|$K2|2|socks" > "$WGH_NODES_CONF"          # sin nodo 1
_wgh_is_up() { return 1; }
_wgh_repair_conf_if_needed
cmp -s "$WGH_CONF" "$TMP/wg-antes" && ok "sin nodo 1 en el registro, el peer existente se conserva" \
    || bad "la reparacion borro el peer de un tunel en uso"
printf '%s\n' "pc|$K1|1|wg" > "$WGH_NODES_CONF"
_wgh_repair_conf_if_needed
grep -q 'AllowedIPs *= 0.0.0.0/0' "$WGH_CONF" && grep -q "$K1" "$WGH_CONF" \
    && ok "con el nodo 1 registrado se escribe su peer correcto" || bad "no se escribe el peer del nodo 1"

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
