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

# === PALETA (heredada del entorno) ===
# CR, CY, GR, RD, YL, WH, DM, SEP, DIR ...

do_optimize() {
    echo -e "  ${YL}[*]${CR} Limpiando caché de memoria RAM (PageCache, Dentries, Inodes)..."
    sync; echo 3 > /proc/sys/vm/drop_caches
    
    echo -e "  ${YL}[*]${CR} Vaciando memoria SWAP (puede demorar unos segundos)..."
    if [ "$(swapon --show 2>/dev/null | wc -l)" -gt 0 ]; then
        swapoff -a && swapon -a
    fi
    
    echo -e "  ${YL}[*]${CR} Limpiando caché de APT y paquetes huérfanos..."
    apt-get clean -y >/dev/null 2>&1
    apt-get autoremove -y >/dev/null 2>&1
    
    echo -e "  ${YL}[*]${CR} Limpiando logs antiguos para liberar disco..."
    find /var/log -type f -name "*.gz" -delete >/dev/null 2>&1
    find /var/log -type f -name "*.[0-9]" -delete >/dev/null 2>&1
    journalctl --vacuum-time=1d >/dev/null 2>&1
    
    echo -e "  ${GR}[+]${CR} ¡Servidor Optimizado con Éxito!"
}

optimize_menu() {
    while true; do
        clear
        print_title 2>/dev/null || true
        echo -e "$SEP"
        echo -e "${WH}             OPTIMIZACIÓN DEL VPS${CR}"
        echo -e "$SEP"
        
        # Verificar estado del cron
        if crontab -l 2>/dev/null | grep -q "optimize.sh --cron"; then
            CRON_LINE=$(crontab -l 2>/dev/null | grep "optimize.sh --cron")
            # Extraer la configuración de hora
            H=$(echo "$CRON_LINE" | awk '{print $2}')
            if [[ "$H" == "*/"* ]]; then
                H=${H#*/}
                ESTADO_AUTO="${GR}[ ACTIVA : Cada ${H}h ]${CR}"
            elif [[ "$H" == "*" ]]; then
                ESTADO_AUTO="${GR}[ ACTIVA : Cada 1h ]${CR}"
            else
                ESTADO_AUTO="${GR}[ ACTIVA ]${CR}"
            fi
        else
            ESTADO_AUTO="${RD}[ OFF ]${CR}"
        fi

        echo -e "  ${CY}1)${CR}  ${WH}Optimizar ahora (Manual)${CR}"
        echo -e "  ${CY}2)${CR}  ${WH}Configurar Optimización Automática${CR}  $ESTADO_AUTO"
        echo -e "  ${CY}3)${CR}  ${WH}Desactivar Optimización Automática${CR}"
        echo -e "  ${CY}0)${CR}  ${WH}Volver${CR}"
        echo -e "$SEP"
        read -p "$(echo -e ${DM})Elige [0-3]: $(echo -e ${CR})" op

        case $op in
            1)
                clear
                print_title 2>/dev/null || true
                echo -e "$SEP"
                echo -e "${WH}             OPTIMIZACIÓN MANUAL${CR}"
                echo -e "$SEP"
                RAM_ANTES=$(free -m | awk '/Mem:/ {print $3}')
                do_optimize
                RAM_DESPUES=$(free -m | awk '/Mem:/ {print $3}')
                AHORRO=$(( RAM_ANTES - RAM_DESPUES ))
                [ "$AHORRO" -lt 0 ] && AHORRO=0
                echo -e "$SEP"
                echo -e "  ${WH}RAM Liberada:${CR} ${CY}${AHORRO} MB${CR}"
                echo ""
                read -p "$(echo -e ${DM})Presiona Enter para continuar...$(echo -e ${CR})"
                ;;
            2)
                echo ""
                read -p "$(echo -e ${YL})¿Cada cuántas horas deseas optimizar automáticamente? [1-24]: $(echo -e ${CR})" horas
                if [[ "$horas" =~ ^[0-9]+$ ]] && [ "$horas" -ge 1 ] && [ "$horas" -le 24 ]; then
                    # Eliminar tarea previa
                    crontab -l 2>/dev/null | grep -v "optimize.sh --cron" | crontab - 2>/dev/null
                    # Añadir nueva tarea
                    if [ "$horas" -eq 1 ]; then
                        (crontab -l 2>/dev/null; echo "0 * * * * bash $DIR/modules/optimize.sh --cron") | crontab -
                    else
                        (crontab -l 2>/dev/null; echo "0 */$horas * * * bash $DIR/modules/optimize.sh --cron") | crontab -
                    fi
                    echo -e "  ${GR}[+]${CR} Optimización automática configurada cada ${WH}$horas${CR} hora(s)."
                else
                    echo -e "  ${RD}[-]${CR} Cantidad de horas no válida."
                fi
                sleep 2
                ;;
            3)
                crontab -l 2>/dev/null | grep -v "optimize.sh --cron" | crontab - 2>/dev/null
                echo ""
                echo -e "  ${GR}[+]${CR} Optimización automática desactivada."
                sleep 2
                ;;
            0) break ;;
            *) echo -e "  ${RD}[-]${CR} Opción inválida."; sleep 1 ;;
        esac
    done
}
