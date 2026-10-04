#!/bin/bash
# Módulo de Optimización de VPS — vpsservice Script FREE

# =========================================================
# LIMPIEZA SEGURA
# ---------------------------------------------------------
# Lo que NO se hace en automatico, y por que:
#  - swapoff -a: en un VPS de 1 GB con swap ocupada obliga al kernel
#    a meter todo en RAM de golpe; si no cabe, el OOM-killer mata
#    procesos, y los primeros suelen ser los sshd y proxies de los
#    clientes. Una "optimizacion" que corta conexiones.
#  - drop_caches cada hora: vacia la cache de disco y el servidor
#    va mas lento justo despues. Linux ya libera esa memoria solo
#    cuando un programa la pide.
# =========================================================

# Vaciar la swap solo si cabe holgada en la RAM libre.
_swap_flush_safe() {
    local swap_used avail
    swap_used=$(free -m | awk '/Swap:/ {print $3}')
    avail=$(free -m | awk '/Mem:/ {print $7}')
    [ "${swap_used:-0}" -gt 0 ] || return 0
    if [ "${avail:-0}" -gt $(( swap_used * 2 + 100 )) ]; then
        swapoff -a && swapon -a
        return 0
    fi
    return 1
}

_clean_disk() {
    apt-get clean -y >/dev/null 2>&1
    apt-get autoremove -y >/dev/null 2>&1
    find /var/log -type f -name "*.gz" -delete >/dev/null 2>&1
    find /var/log -type f -name "*.[0-9]" -delete >/dev/null 2>&1
    # 3 dias / 200 MB: suficiente para diagnosticar una caida de ayer.
    journalctl --vacuum-time=3d --vacuum-size=200M >/dev/null 2>&1
}

# Si el script se ejecuta directamente (ej: por cron)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # En automatico solo se limpia disco: nada que pueda cortar sesiones.
    [ "$1" == "--cron" ] && _clean_disk
    exit 0
fi

# =========================================================
# Si llegamos aquí, fue importado (source) desde main.sh
# =========================================================
_OPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$_OPT_DIR/ui.sh"

do_optimize() {
    ui_info "Liberando caché de RAM (una sola vez)..."
    sync; echo 1 > /proc/sys/vm/drop_caches

    ui_info "Revisando la memoria SWAP..."
    if _swap_flush_safe; then
        ui_ok "SWAP revisada."
    else
        ui_warn "La SWAP no cabe en la RAM libre: se deja como está para no cortar sesiones."
    fi

    ui_info "Limpiando caché de APT, paquetes huérfanos y logs antiguos..."
    _clean_disk

    ui_ok "¡Servidor optimizado con éxito!"
}

optimize_menu() {
    while true; do
        clear
        print_title 2>/dev/null || true
        ui_section "OPTIMIZACIÓN DEL SERVIDOR" "RAM · swap · caché · logs"
        ui_blank

        # Estado del cron de optimización automática
        local ESTADO_AUTO CRON_LINE H
        if crontab -l 2>/dev/null | grep -q "optimize.sh --cron"; then
            CRON_LINE=$(crontab -l 2>/dev/null | grep "optimize.sh --cron")
            H=$(echo "$CRON_LINE" | awk '{print $2}')
            if [[ "$H" == "*/"* ]]; then
                H=${H#*/}
                ESTADO_AUTO="${GR}[ CADA ${H}h ]${CR}"
            elif [[ "$H" == "*" ]]; then
                ESTADO_AUTO="${GR}[ CADA 1h ]${CR}"
            else
                ESTADO_AUTO="${GR}[ DIARIA ]${CR}"
            fi
        else
            ESTADO_AUTO="$(ui_tag_str off)"
        fi

        # Vista rápida de los recursos que se van a liberar
        local RAM_U RAM_T RAM_PCT
        RAM_U=$(free -m | awk '/Mem:/ {print $3}')
        RAM_T=$(free -m | awk '/Mem:/ {print $2}')
        RAM_PCT=0
        [ "${RAM_T:-0}" -gt 0 ] && RAM_PCT=$(( RAM_U * 100 / RAM_T ))
        printf "${UI_PAD}%b ${DM}RAM en uso${CR} %b ${WH}%sMi/%sMi${CR} ${DM}(%s%%)${CR}\n" \
            "$(ui_dot "$RAM_PCT")" "$(ui_bar "$RAM_PCT")" "$RAM_U" "$RAM_T" "$RAM_PCT"
        ui_rule
        ui_blank

        ui_opt "1" "OPTIMIZAR AHORA"      "RAM · disco"
        ui_opt "2" "LIMPIEZA AUTOMÁTICA"  "solo disco"  "$ESTADO_AUTO"
        ui_blank
        ui_opt "0" "VOLVER"
        ui_solid
        ui_prompt "Elige una opción [0-2]"

        case "$REPLY_UI" in
            1)
                clear
                print_title 2>/dev/null || true
                ui_section "OPTIMIZACIÓN MANUAL"
                ui_blank
                RAM_ANTES=$(free -m | awk '/Mem:/ {print $3}')
                do_optimize
                RAM_DESPUES=$(free -m | awk '/Mem:/ {print $3}')
                AHORRO=$(( RAM_ANTES - RAM_DESPUES ))
                [ "$AHORRO" -lt 0 ] && AHORRO=0
                ui_blank
                ui_solid
                echo -e "${UI_PAD}${WH}RAM LIBERADA:${CR}  ${CY}${BD}${AHORRO} MB${CR}"
                ui_solid
                ui_pause
                ;;
            2)
                # Programar y desactivar eran dos opciones; ahora es una:
                # se elige la frecuencia, y 0 la apaga.
                ui_blank
                ui_prompt "¿Cada cuántas horas limpiar el disco? [1-24, 0 = apagar] (Enter = 24)"
                horas="${REPLY_UI:-24}"
                if [[ "$horas" =~ ^[0-9]+$ ]] && [ "$horas" -le 24 ]; then
                    crontab -l 2>/dev/null | grep -v "optimize.sh --cron" | crontab - 2>/dev/null
                    if [ "$horas" -eq 0 ]; then
                        ui_ok "Limpieza automática desactivada."
                    else
                        local min="0 */$horas"; [ "$horas" -eq 1 ] && min="0 *"
                        [ "$horas" -eq 24 ] && min="30 4"
                        (crontab -l 2>/dev/null; echo "$min * * * bash $DIR/modules/optimize.sh --cron") | crontab -
                        ui_ok "Limpieza automática cada ${WH}$horas${CR} hora(s)."
                    fi
                else
                    ui_err "Cantidad de horas no válida."
                fi
                sleep 2
                ;;
            0|"") break ;;
            *) ui_err "Opción inválida."; sleep 1 ;;
        esac
    done
}
