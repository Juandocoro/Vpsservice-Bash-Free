#!/bin/bash
# Módulo de Optimización de VPS — vpsservice Script FREE

# Si el script se ejecuta directamente (ej: por cron)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Ejecución en segundo plano (silenciosa)
    if [ "$1" == "--cron" ]; then
        sync; echo 3 > /proc/sys/vm/drop_caches
        if [ "$(swapon --show 2>/dev/null | wc -l)" -gt 0 ]; then
            swapoff -a && swapon -a
        fi
        apt-get clean -y >/dev/null 2>&1
        apt-get autoremove -y >/dev/null 2>&1
        find /var/log -type f -name "*.gz" -delete >/dev/null 2>&1
        find /var/log -type f -name "*.[0-9]" -delete >/dev/null 2>&1
        journalctl --vacuum-time=1d >/dev/null 2>&1
        exit 0
    fi
    exit 0
fi

# =========================================================
# Si llegamos aquí, fue importado (source) desde main.sh
# =========================================================
_OPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$_OPT_DIR/ui.sh"

do_optimize() {
    ui_info "Limpiando caché de RAM (PageCache, Dentries, Inodes)..."
    sync; echo 3 > /proc/sys/vm/drop_caches

    ui_info "Vaciando memoria SWAP (puede demorar unos segundos)..."
    if [ "$(swapon --show 2>/dev/null | wc -l)" -gt 0 ]; then
        swapoff -a && swapon -a
    fi

    ui_info "Limpiando caché de APT y paquetes huérfanos..."
    apt-get clean -y >/dev/null 2>&1
    apt-get autoremove -y >/dev/null 2>&1

    ui_info "Limpiando logs antiguos para liberar disco..."
    find /var/log -type f -name "*.gz" -delete >/dev/null 2>&1
    find /var/log -type f -name "*.[0-9]" -delete >/dev/null 2>&1
    journalctl --vacuum-time=1d >/dev/null 2>&1

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
                ESTADO_AUTO="$(ui_tag_str on)"
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

        ui_opt "1" "OPTIMIZAR AHORA"    "manual"
        ui_opt "2" "PROGRAMAR LIMPIEZA" "automática"  "$ESTADO_AUTO"
        ui_opt "3" "DESACTIVAR AUTO"    "quitar cron"
        ui_blank
        ui_opt "0" "VOLVER"
        ui_solid
        ui_prompt "Elige una opción [0-3]"

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
                ui_blank
                ui_prompt "¿Cada cuántas horas optimizar? [1-24]"
                horas="$REPLY_UI"
                if [[ "$horas" =~ ^[0-9]+$ ]] && [ "$horas" -ge 1 ] && [ "$horas" -le 24 ]; then
                    crontab -l 2>/dev/null | grep -v "optimize.sh --cron" | crontab - 2>/dev/null
                    if [ "$horas" -eq 1 ]; then
                        (crontab -l 2>/dev/null; echo "0 * * * * bash $DIR/modules/optimize.sh --cron") | crontab -
                    else
                        (crontab -l 2>/dev/null; echo "0 */$horas * * * bash $DIR/modules/optimize.sh --cron") | crontab -
                    fi
                    ui_ok "Optimización automática cada ${WH}$horas${CR} hora(s)."
                else
                    ui_err "Cantidad de horas no válida."
                fi
                sleep 2
                ;;
            3)
                crontab -l 2>/dev/null | grep -v "optimize.sh --cron" | crontab - 2>/dev/null
                ui_blank
                ui_ok "Optimización automática desactivada."
                sleep 2
                ;;
            0) break ;;
            *) ui_err "Opción inválida."; sleep 1 ;;
        esac
    done
}
