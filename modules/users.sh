#!/bin/bash
# Módulo de Usuarios — vpsservice Script FREE

# === PALETA (heredada del entorno si se llama desde main.sh) ===
CR="\033[0m"
CY="\033[1;36m"
GR="\033[1;32m"
RD="\033[0;31m"
YL="\033[0;33m"
WH="\033[1;37m"
DM="\033[2;37m"
SEP="${YL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CR}"

DB_FILE="/root/.vps_users"

crear_usuario() {
    clear
    echo -e "$SEP"
    echo -e "${WH}               CREAR USUARIO${CR}"
    echo -e "$SEP"

    read -p "$(echo -e ${DM})NOMBRE: $(echo -e ${CR})" USERNAME
    if [ -z "$USERNAME" ]; then echo -e "  ${RD}[-]${CR} Nombre vacío."; sleep 1; return; fi
    if id "$USERNAME" &>/dev/null; then echo -e "  ${RD}[-]${CR} El usuario ya existe."; sleep 1; return; fi

    read -s -p "$(echo -e ${DM})CONTRASEÑA: $(echo -e ${CR})" PASSWORD
    echo ""
    if [ -z "$PASSWORD" ]; then echo -e "  ${RD}[-]${CR} Contraseña vacía."; sleep 1; return; fi

    read -p "$(echo -e ${DM})TIEMPO (Días): $(echo -e ${CR})" DAYS
    if [[ ! "$DAYS" =~ ^[0-9]+$ ]]; then echo -e "  ${RD}[-]${CR} Formato numérico requerido."; sleep 1; return; fi

    read -p "$(echo -e ${DM})LÍMITE CONEXIONES: $(echo -e ${CR})" LIMIT
    if [[ ! "$LIMIT" =~ ^[0-9]+$ ]]; then echo -e "  ${RD}[-]${CR} Formato numérico requerido."; sleep 1; return; fi

    EXP_DATE=$(date -d "+$DAYS days" +%Y-%m-%d 2>/dev/null)
    SERVER_IP=$(curl -4 -s ifconfig.me 2>/dev/null || echo "N/A")

    # ================================================================
    # FIX SSH — 4 capas para garantizar auth sin depender de
    # PasswordAuthentication (Ubuntu Cloud lo deshabilita por defecto)
    # ================================================================
    SSHD_CONF="/etc/ssh/sshd_config"

    # Helper: aplica una directiva en el archivo objetivo
    _ssh_set() {
        local file="$1" key="$2" val="$3"
        if grep -qE "^#?\s*${key}" "$file" 2>/dev/null; then
            sed -i -E "s|^#?\s*${key}.*|${key} ${val}|g" "$file"
        else
            echo "${key} ${val}" >> "$file"
        fi
    }

    # CAPA 1 — Parchar sshd_config principal
    _ssh_set "$SSHD_CONF" "UsePAM"                      "yes"
    _ssh_set "$SSHD_CONF" "KbdInteractiveAuthentication" "yes"  # SSH moderno (Ubuntu 22+)
    _ssh_set "$SSHD_CONF" "ChallengeResponseAuthentication" "yes"  # SSH antiguo (Ubuntu 20)
    _ssh_set "$SSHD_CONF" "PasswordAuthentication"      "yes"
    _ssh_set "$SSHD_CONF" "PermitEmptyPasswords"        "no"

    # CAPA 2 — Neutralizar overrides en sshd_config.d/ (Ubuntu Cloud los pone aquí)
    # Cualquier archivo con PasswordAuthentication no o KbdInteractive no queda corregido
    if [ -d /etc/ssh/sshd_config.d ]; then
        for f in /etc/ssh/sshd_config.d/*.conf; do
            [ -f "$f" ] || continue
            sed -i -E 's|^#?\s*PasswordAuthentication.*|PasswordAuthentication yes|g' "$f"
            sed -i -E 's|^#?\s*KbdInteractiveAuthentication.*|KbdInteractiveAuthentication yes|g' "$f"
            sed -i -E 's|^#?\s*ChallengeResponseAuthentication.*|ChallengeResponseAuthentication yes|g' "$f"
        done
    fi

    # CAPA 3 — Si sshd tiene AllowUsers, agregar el usuario nuevo a la lista
    if grep -qE "^AllowUsers" "$SSHD_CONF" 2>/dev/null; then
        if ! grep -qE "^AllowUsers.*\b${USERNAME}\b" "$SSHD_CONF"; then
            sed -i -E "s|^(AllowUsers.*)$|\1 ${USERNAME}|" "$SSHD_CONF"
        fi
    fi

    # CAPA EXTRA - Garantizar configuración de contraseñas creando drop-in
    if [ -d /etc/ssh/sshd_config.d ]; then
        echo -e "PasswordAuthentication yes\nKbdInteractiveAuthentication yes\nChallengeResponseAuthentication yes" > /etc/ssh/sshd_config.d/99-vpsservice.conf
    fi

    # Reiniciar sshd (restart garantiza que apliquen los cambios, no corta sesiones activas)
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null

    # Crear usuario sistema
    useradd -m -s /bin/bash -e "$EXP_DATE" -c "$LIMIT" "$USERNAME"
    echo "$USERNAME:$PASSWORD" | chpasswd

    # CAPA 4 — Desbloqueo forzado de la cuenta (passwd -u quita el prefijo ! del hash)
    passwd -u "$USERNAME" 2>/dev/null
    usermod -U "$USERNAME" 2>/dev/null

    # Log plano seguro
    touch "$DB_FILE"
    chmod 600 "$DB_FILE"
    sed -i "/^$USERNAME:/d" "$DB_FILE" 2>/dev/null
    echo "$USERNAME:$PASSWORD" >> "$DB_FILE"

    echo ""
    echo -e "$SEP"
    echo -e "  ${GR}[+]${CR} ${WH}Usuario activado!${CR}"
    echo -e "$SEP"
    echo -e "  ${DM}Servidor :${CR}  ${GR}$SERVER_IP${CR}"
    echo -e "  ${DM}Nombre   :${CR}  ${WH}$USERNAME${CR}"
    echo -e "  ${DM}Password :${CR}  ${WH}$PASSWORD${CR}"
    echo -e "  ${DM}Vence    :${CR}  ${WH}$EXP_DATE${CR} ${DM}($DAYS días)${CR}"
    echo -e "  ${DM}Límite   :${CR}  ${WH}$LIMIT${CR} ${DM}dispositivo(s)${CR}"
    echo -e "$SEP"
    read -p "$(echo -e ${DM})Presiona Enter para volver...$(echo -e ${CR})"
}

# =========================================================
# TABLA DE USUARIOS — reutilizable por todas las acciones
# =========================================================
_tabla_usuarios() {
    local NOW_SEC
    NOW_SEC=$(date +%s)

    # Cabecera de tabla
    echo -e ""
    printf "  ${YL}%-3s  %-16s  %-12s  %-12s  %-8s  %-10s  %s${CR}\n" \
        "#" "USUARIO" "CONTRASEÑA" "VENCE" "DÍAS" "CONEX" "ESTADO"
    echo -e "  ${YL}$(printf '─%.0s' {1..75})${CR}"

    local idx=0
    awk -F':' '($3 >= 1000 && $3 != 65534 && $1 != "nobody" && $1 != "ubuntu") {print $1}' /etc/passwd | \
    while read u; do
        idx=$((idx + 1))

        # Contraseña del log plano
        PASS=$(grep "^$u:" "$DB_FILE" 2>/dev/null | cut -d: -f2)
        [ -z "$PASS" ] && PASS="?(sin log)"

        # Fecha de expiración desde chage
        EXP_RAW=$(chage -l "$u" 2>/dev/null | grep "Account expires" | cut -d: -f2 | xargs)

        # Calcular días restantes
        if [[ "$EXP_RAW" == "never" || -z "$EXP_RAW" ]]; then
            DIAS_REST="∞"
            ESTADO="${GR}ACTIVO${CR}"
        else
            EXP_SEC=$(date -d "$EXP_RAW" +%s 2>/dev/null)
            if [ -z "$EXP_SEC" ]; then
                DIAS_REST="?"
                ESTADO="${DM}UNKNOWN${CR}"
            else
                DIFF=$(( (EXP_SEC - NOW_SEC) / 86400 ))
                if [ "$DIFF" -lt 0 ]; then
                    DIAS_REST="0"
                    ESTADO="${RD}VENCIDO${CR}"
                elif [ "$DIFF" -le 3 ]; then
                    DIAS_REST="${DIFF}d"
                    ESTADO="${YL}POR VENCER${CR}"
                else
                    DIAS_REST="${DIFF}d"
                    ESTADO="${GR}ACTIVO${CR}"
                fi
            fi
        fi

        # Conexiones activas / límite
        LIMITE=$(getent passwd "$u" | cut -d: -f5)
        [[ ! "$LIMITE" =~ ^[0-9]+$ ]] && LIMITE="1"
        CONEX=$(ps -u "$u" -o comm= 2>/dev/null | grep -E "^(sshd|dropbear)$" | wc -l)

        # Imprimir fila con índice de color alterno
        if [ $(( idx % 2 )) -eq 0 ]; then
            NCOLOR="${CY}"
        else
            NCOLOR="${WH}"
        fi

        printf "  ${NCOLOR}%-3s${CR}  ${WH}%-16s${CR}  ${DM}%-12s${CR}  ${DM}%-12s${CR}  ${CY}%-8s${CR}  ${DM}%s/%s${CR}       " \
            "$idx" "$u" "$PASS" "${EXP_RAW:-N/A}" "$DIAS_REST" "$CONEX" "$LIMITE"
        echo -e "$ESTADO"
    done
    echo -e "  ${YL}$(printf '─%.0s' {1..75})${CR}"
    echo ""
}

administrar_usuarios() {
    while true; do
        clear
        print_title 2>/dev/null || true
        echo -e "$SEP"
        echo -e "${WH}           ADMINISTRAR USUARIOS${CR}"
        echo -e "$SEP"
        echo -e "  ${CY}1)${CR}  ${WH}Listar usuarios${CR}"
        echo -e "  ${CY}2)${CR}  ${WH}Eliminar usuario${CR}"
        echo -e "  ${CY}3)${CR}  ${WH}Modificar expiración${CR}"
        echo -e "  ${CY}4)${CR}  ${WH}Cambiar contraseña${CR}"
        echo -e "  ${CY}0)${CR}  ${WH}Volver${CR}"
        echo -e "$SEP"
        read -p "$(echo -e ${DM})Elige [0-4]: $(echo -e ${CR})" sub_opt

        case $sub_opt in
            1)
                clear
                print_title 2>/dev/null || true
                echo -e "$SEP"
                echo -e "${WH}           LISTA DE USUARIOS${CR}"
                echo -e "$SEP"
                _tabla_usuarios
                read -p "$(echo -e ${DM})Enter para continuar...$(echo -e ${CR})" ;;

            2)
                clear
                print_title 2>/dev/null || true
                echo -e "$SEP"
                echo -e "${WH}           ELIMINAR USUARIO${CR}"
                echo -e "$SEP"
                _tabla_usuarios
                read -p "$(echo -e ${DM})Nombre del usuario a ELIMINAR (0=cancelar): $(echo -e ${CR})" DEL_USER
                [[ "$DEL_USER" == "0" || -z "$DEL_USER" ]] && continue
                if id "$DEL_USER" &>/dev/null; then
                    read -p "$(echo -e ${RD})¿Confirmar eliminación de '$DEL_USER'? (s/n): $(echo -e ${CR})" CONF
                    if [[ "$CONF" == "s" || "$CONF" == "S" ]]; then
                        # Cerrar sesiones activas antes de borrar
                        pkill -u "$DEL_USER" 2>/dev/null
                        userdel -r "$DEL_USER" 2>/dev/null
                        sed -i "/^$DEL_USER:/d" "$DB_FILE" 2>/dev/null
                        echo -e "  ${GR}[+]${CR} Usuario ${WH}$DEL_USER${CR} eliminado correctamente."
                    else
                        echo -e "  ${DM}[·]${CR} Operación cancelada."
                    fi
                else
                    echo -e "  ${RD}[-]${CR} Usuario '$DEL_USER' no existe."
                fi
                sleep 1 ;;

            3)
                clear
                print_title 2>/dev/null || true
                echo -e "$SEP"
                echo -e "${WH}           MODIFICAR EXPIRACIÓN${CR}"
                echo -e "$SEP"
                _tabla_usuarios
                read -p "$(echo -e ${DM})Usuario a modificar (0=cancelar): $(echo -e ${CR})" MOD_USER
                [[ "$MOD_USER" == "0" || -z "$MOD_USER" ]] && continue
                if id "$MOD_USER" &>/dev/null; then
                    read -p "$(echo -e ${DM})Nuevos días desde hoy: $(echo -e ${CR})" NEW_DAYS
                    if [[ "$NEW_DAYS" =~ ^[0-9]+$ ]]; then
                        NEW_EXP=$(date -d "+$NEW_DAYS days" +%Y-%m-%d)
                        usermod -e "$NEW_EXP" "$MOD_USER"
                        echo -e "  ${GR}[+]${CR} Vencimiento de ${WH}$MOD_USER${CR} → ${CY}$NEW_EXP${CR} (${NEW_DAYS} días)."
                    else
                        echo -e "  ${RD}[-]${CR} Valor inválido."
                    fi
                else
                    echo -e "  ${RD}[-]${CR} Usuario '$MOD_USER' no existe."
                fi
                sleep 1 ;;

            4)
                clear
                print_title 2>/dev/null || true
                echo -e "$SEP"
                echo -e "${WH}           CAMBIAR CONTRASEÑA${CR}"
                echo -e "$SEP"
                _tabla_usuarios
                read -p "$(echo -e ${DM})Usuario (0=cancelar): $(echo -e ${CR})" PASS_USER
                [[ "$PASS_USER" == "0" || -z "$PASS_USER" ]] && continue
                if id "$PASS_USER" &>/dev/null; then
                    read -s -p "$(echo -e ${DM})Nueva clave: $(echo -e ${CR})" NEW_PASS; echo ""
                    if [ -z "$NEW_PASS" ]; then
                        echo -e "  ${RD}[-]${CR} Contraseña vacía, operación cancelada."
                    else
                        echo "$PASS_USER:$NEW_PASS" | chpasswd
                        sed -i "/^$PASS_USER:/d" "$DB_FILE" 2>/dev/null
                        echo "$PASS_USER:$NEW_PASS" >> "$DB_FILE"
                        echo -e "  ${GR}[+]${CR} Contraseña de ${WH}$PASS_USER${CR} actualizada."
                    fi
                else
                    echo -e "  ${RD}[-]${CR} Usuario '$PASS_USER' no existe."
                fi
                sleep 1 ;;

            0) break ;;
            *) echo -e "  ${RD}[-]${CR} Opción inválida."; sleep 1 ;;
        esac
    done
}

# =========================================================
# MONITOR DE CONEXIONES ACTIVAS
# =========================================================
monitor_conexiones() {
    clear
    print_title 2>/dev/null || true
    echo -e "$SEP"
    echo -e "${WH}           MONITOR DE CONEXIONES${CR}"
    echo -e "$SEP"
    printf "  ${YL}%-15s  %-15s  %-15s${CR}\n" "USUARIO" "MÉTODO" "CONEXIONES"
    echo -e "  ${YL}$(printf '─%.0s' {1..50})${CR}"

    local total_conexiones=0

    # Contar SSH y Dropbear
    for u in $(awk -F':' '($3 >= 1000 && $3 != 65534 && $1 != "nobody" && $1 != "ubuntu") {print $1}' /etc/passwd); do
        ssh_count=$(ps -u "$u" -o comm= 2>/dev/null | grep -c "^sshd$")
        dropbear_count=$(ps -u "$u" -o comm= 2>/dev/null | grep -c "^dropbear$")
        
        if [ "$ssh_count" -gt 0 ]; then
            printf "  ${WH}%-15s${CR}  ${CY}%-15s${CR}  ${GR}%-15s${CR}\n" "$u" "SSH" "$ssh_count"
            total_conexiones=$((total_conexiones + ssh_count))
        fi
        if [ "$dropbear_count" -gt 0 ]; then
            printf "  ${WH}%-15s${CR}  ${CY}%-15s${CR}  ${GR}%-15s${CR}\n" "$u" "Dropbear" "$dropbear_count"
            total_conexiones=$((total_conexiones + dropbear_count))
        fi
    done

    # Contar OpenVPN
    if [ -f /var/log/openvpn/openvpn-status.log ]; then
        while read count user; do
            printf "  ${WH}%-15s${CR}  ${GR}%-15s${CR}  ${GR}%-15s${CR}\n" "$user" "OpenVPN" "$count"
            total_conexiones=$((total_conexiones + count))
        done < <(awk -F',' '/^CLIENT_LIST/ {print $2}' /var/log/openvpn/openvpn-status.log | sort | uniq -c)
    elif [ -f /etc/openvpn/openvpn-status.log ]; then
        while read count user; do
            printf "  ${WH}%-15s${CR}  ${GR}%-15s${CR}  ${GR}%-15s${CR}\n" "$user" "OpenVPN" "$count"
            total_conexiones=$((total_conexiones + count))
        done < <(awk -F',' '/^CLIENT_LIST/ {print $2}' /etc/openvpn/openvpn-status.log | sort | uniq -c)
    fi

    echo -e "  ${YL}$(printf '─%.0s' {1..50})${CR}"
    echo -e "  ${WH}Total de conexiones activas:${CR} ${CY}$total_conexiones${CR}"
    echo ""
    read -p "$(echo -e ${DM})Presiona Enter para volver...$(echo -e ${CR})"
}
