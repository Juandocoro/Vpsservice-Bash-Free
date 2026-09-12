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
USED=$(grep -rhoP '(?<![\w/])(_wgh?[a-z0-9_]+|wghome_[a-z0-9_]+|ui_[a-z0-9_]+)(?![\w./])' $ALL_SH | sort -u)
MISSING=""
while read -r fn; do
    [ -z "$fn" ] && continue
    grep -qx "$fn" <<<"$DEF" || MISSING="$MISSING $fn"
done <<<"$USED"
if [ -z "$MISSING" ]; then ok "todas las funciones internas existen"
else bad "hay funciones sin definir" "$MISSING"; fi

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
