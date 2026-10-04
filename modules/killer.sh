#!/bin/bash
# =========================================================
# MONITOR AUTO-KILLER (Protección Activa de Cuota)
# Se ejecuta por cron cada minuto, en silencio.
# ---------------------------------------------------------
# Antes, al pasarse del limite se mataban TODAS las sesiones
# del usuario. Con limite 1, una sesion fantasma (el movil
# perdio la senal y el servidor aun no se ha enterado) mas la
# reconexion legitima sumaban 2: se cortaban las dos, el
# cliente reconectaba, volvia a sumar 2... un bucle que dejaba
# al cliente sin servicio cada minuto.
#
# Ahora solo se cierran las sesiones que SOBRAN, y siempre las
# mas antiguas: la fantasma cae y la conexion nueva se queda.
#
# Tambien se contaba mal: se filtraban las conexiones desde
# 127.0.0.1, que son justo las de WebSocket y SSL (llegan a
# sshd a traves del proxy local), asi que a esos usuarios no
# se les aplicaba el limite. Ahora se cuenta un proceso de
# sesion por conexion, venga de donde venga.
# =========================================================

# Una sola ejecucion a la vez: si una vuelta tarda mas de un
# minuto, la siguiente no debe pisarla.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && command -v flock &>/dev/null; then
    exec 9>/run/vpsservice-killer.lock 2>/dev/null && { flock -n 9 || exit 0; }
fi

# Cuentas de cliente creadas por el panel
_killer_users() {
    awk -F':' '($3 >= 1000 && $3 != 65534 && $1 != "nobody" && $1 != "ubuntu") {print $1}' /etc/passwd
}

# Sesiones de un usuario: "segundos_vivo pid" por cada conexion.
# Cada conexion SSH deja exactamente un proceso del propio usuario
# (sshd, o sshd-session desde OpenSSH 9.8); el [priv] es de root y
# no cuenta. Dropbear igual.
_killer_sessions() {
    ps -u "$1" -o etimes=,pid=,comm= 2>/dev/null \
        | awk '$3=="sshd" || $3=="sshd-session" || $3=="dropbear" {print $1, $2}'
}

# Funcion pura: lee "segundos_vivo pid" y devuelve los pids que
# sobran para quedarse en <limite>. Conserva las MAS NUEVAS.
#   _killer_pick <limite>  < sesiones
_killer_pick() {
    local lim="$1"
    sort -n -k1,1 | awk -v l="$lim" 'NR > l {print $2}'
}

_killer_run() {
    local u lim pid
    while read -r u; do
        [ -z "$u" ] && continue
        lim=$(getent passwd "$u" | cut -d: -f5)
        # Sin un numero valido no se aplica limite: mejor no cortar
        # que cortar por un dato corrupto.
        [[ "$lim" =~ ^[0-9]+$ ]] && [ "$lim" -ge 1 ] || continue

        for pid in $(_killer_sessions "$u" | _killer_pick "$lim"); do
            kill "$pid" 2>/dev/null
            logger -t vpsservice-killer "Cuenta $u por encima de su limite ($lim): cerrada la sesion antigua $pid" 2>/dev/null
        done
    done < <(_killer_users)
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && _killer_run
