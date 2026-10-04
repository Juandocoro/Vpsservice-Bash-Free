#!/bin/bash
# =========================================================
# GUARDIAN DE SERVICIOS — cron, cada minuto
# ---------------------------------------------------------
# Si un servicio que el admin instalo se cae (un fallo, un OOM,
# una actualizacion del sistema que lo paro), los clientes que
# entraban por el se quedan sin conexion hasta que alguien abre
# el panel y se da cuenta. Este guardian lo levanta solo en un
# minuto como mucho, y deja constancia en el log.
#
# Solo toca lo que esta HABILITADO: un protocolo que el admin no
# instalo o apago a proposito no se arranca nunca.
# =========================================================

_GDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
GUARD_LOG="/var/log/vpsservice-guardian.log"

_guard_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$GUARD_LOG" 2>/dev/null
    logger -t vpsservice-guardian "$1" 2>/dev/null
}

# _guard_unit <unidad> : la reinicia si deberia estar viva y no lo esta.
_guard_unit() {
    local u="$1"
    systemctl is-active --quiet "$u" 2>/dev/null && return 0
    case "$(systemctl is-active "$u" 2>/dev/null)" in activating|reloading) return 0 ;; esac
    _svc_installed "$u" || return 0
    # reset-failed: si systemd agoto sus reintentos, sin esto ignoraria
    # el restart y el servicio se quedaria caido para siempre.
    systemctl reset-failed "$u" &>/dev/null
    if systemctl restart "$u" &>/dev/null && systemctl is-active --quiet "$u"; then
        _guard_log "${u} estaba caido: reiniciado"
    else
        _guard_log "${u} esta caido y NO arranca. Revisa: journalctl -u ${u} -n 30"
    fi
}

_guard_run() {
    source "$_GDIR/network.sh"

    # 1. SSH: sin el, ningun tunel funciona. En sistemas con activacion
    #    por socket el servicio puede estar parado y ser lo normal.
    if ! systemctl is-active --quiet ssh 2>/dev/null && ! systemctl is-active --quiet sshd 2>/dev/null \
       && ! systemctl is-active --quiet ssh.socket 2>/dev/null; then
        if sshd -t &>/dev/null; then
            systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
            _guard_log "SSH estaba caido: reiniciado"
        else
            _guard_log "SSH caido y su configuracion es INVALIDA: $(sshd -t 2>&1 | head -1)"
        fi
    fi

    # 2. Protocolos del panel
    local e
    for e in "${VPS_SERVICES[@]}"; do _guard_unit "${e%%|*}"; done

    # 3. Gateway residencial: interfaces de nodo, redsocks y el vigilante
    local u
    for u in $(systemctl list-units --all --plain --no-legend 'wg-quick@wg-home*' 'redsocks-node*' 2>/dev/null | awk '{print $1}'); do
        _guard_unit "$u"
    done
    _guard_unit homevpn-watchdog.service

    # 4. Salida residencial: si estaba encendida y sus reglas han
    #    desaparecido (un reinicio de red, alguien vacio iptables...),
    #    se vuelven a poner. Sin esto los usuarios saldrian por la IP
    #    del VPS sin que nadie lo notara.
    if [ -f /etc/wireguard/homevpn-routing.on ]; then
        bash "$_GDIR/installers/wg_home.sh" --check-restore 2>/dev/null
    fi
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && _guard_run
