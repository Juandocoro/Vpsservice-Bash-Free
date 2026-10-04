#!/bin/bash
# =========================================================
# PIEZAS COMUNES DE LOS INSTALADORES
# ---------------------------------------------------------
# Antes cada instalador hacia esto a su manera, o no lo hacia:
#  · aceptaba cualquier puerto, aunque estuviera ocupado: el
#    servicio no arrancaba y el instalador decia "activo";
#  · no comprobaba que el servicio hubiera arrancado;
#  · pedia la IP con 'curl ifconfig.me' sin limite de tiempo,
#    y sin red el instalador se quedaba colgado;
#  · instalaba paquetes con preguntas de debconf ocultas tras
#    &>/dev/null: parecia colgado y no lo estaba.
# =========================================================

_COMMON_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$_COMMON_DIR/../ui.sh"
declare -F _public_ip >/dev/null 2>&1 || source "$_COMMON_DIR/../network.sh"

# Marca de "este protocolo lo instalo el panel": la usan el guardian
# y el tablero para no confundir un paquete instalado por dependencia
# (dropbear viene de serie con setup.sh) con un servicio del admin.
INST_MARKS="/var/lib/vpsservice/proto"
inst_mark()   { mkdir -p "$INST_MARKS" 2>/dev/null && touch "$INST_MARKS/$1"; }
inst_marked() { [ -f "$INST_MARKS/$1" ]; }

inst_header() {
    clear
    ui_header "FREE · INSTALADOR"
    ui_section "$1" "${2:-}"
}

inst_root() {
    [ "$EUID" -eq 0 ] && return 0
    ui_err "Ejecutar como root."; exit 1
}

# Instala paquetes sin preguntas. Si falla, refresca las listas (en
# un VPS recien creado suelen estar vacias) y lo intenta otra vez.
inst_apt() {
    DEBIAN_FRONTEND=noninteractive apt-get install -yq "$@" &>/dev/null && return 0
    DEBIAN_FRONTEND=noninteractive apt-get update -yq &>/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -yq "$@" &>/dev/null
}

# ¿Quien escucha en este puerto? Vacio si esta libre.
#   inst_port_owner <puerto> <tcp|udp>
inst_port_owner() {
    local flag="-tlnpH"; [ "$2" = "udp" ] && flag="-ulnpH"
    ss $flag "sport = :$1" 2>/dev/null | grep -o 'users:(("[^"]*"' | head -1 | cut -d'"' -f2
}

# Funcion pura: ¿es un puerto valido?
inst_port_valid() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

# Pide un puerto, lo valida y comprueba que este libre. Si lo ocupa
# el propio servicio (reinstalacion), se acepta.
#   inst_ask_port "<texto>" <defecto> <tcp|udp> [proceso_propio]
# Deja el puerto en INST_PORT. Devuelve 1 si se cancela (0).
inst_ask_port() {
    local txt="$1" def="$2" proto="$3" propio="${4:-}" p owner
    while true; do
        ui_prompt "${txt} (Enter = ${def} · 0 = cancelar)"
        p="${REPLY_UI:-$def}"
        [ "$p" = "0" ] && return 1
        inst_port_valid "$p" || { ui_err "Puerto no válido (1-65535)."; continue; }
        owner=$(inst_port_owner "$p" "$proto")
        if [ -n "$owner" ] && { [ -z "$propio" ] || [[ "$owner" != *"$propio"* ]]; }; then
            ui_err "El puerto ${p}/${proto} ya lo usa '${owner}'. Elige otro."
            continue
        fi
        INST_PORT="$p"; return 0
    done
}

# Espera a que el servicio quede activo y lo dice. Si no arranca,
# enseña las ultimas lineas de su log en vez de un "activo" falso.
#   inst_check_service <unidad> <nombre visible>
inst_check_service() {
    local unit="$1" name="$2" i
    for i in 1 2 3 4 5 6; do
        systemctl is-active --quiet "$unit" && { ui_ok "${name} activo."; return 0; }
        sleep 1
    done
    ui_err "${name} NO arrancó. Últimas líneas de su registro:"
    journalctl -u "$unit" -n 8 --no-pager 2>/dev/null | sed "s/^/${UI_PAD}  /"
    return 1
}

inst_ufw_allow() {
    command -v ufw &>/dev/null || return 0
    local r; for r in "$@"; do ufw allow "$r" &>/dev/null; done
}

# Arquitectura en el formato de los binarios publicados (amd64/arm64).
inst_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        *)             uname -m ;;
    esac
}
