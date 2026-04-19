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
    SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || echo "N/A")

    # Crear usuario sistema
    useradd -m -s /bin/bash -e "$EXP_DATE" -c "$LIMIT" "$USERNAME"
    echo "$USERNAME:$PASSWORD" | chpasswd

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

administrar_usuarios() {
    while true; do
        clear
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
                echo ""
                echo -e "  ${YL}--- USUARIOS ACTIVOS (UID >= 1000) ---${CR}"
                echo ""
                awk -F':' '($3 >= 1000 && $3 != 65534 && $1 != "nobody" && $1 != "ubuntu") {print $1}' /etc/passwd | while read u; do
                    EXP=$(chage -l "$u" | grep "Account expires" | cut -d: -f2 | xargs)
                    LIMITE=$(getent passwd "$u" | cut -d: -f5)
                    [ -z "$LIMITE" ] && LIMITE="1"
                    CONEX=$(ps -u "$u" -o comm= 2>/dev/null | grep -E "^(sshd|dropbear)$" | wc -l)
                    PASS=$(grep "^$u:" "$DB_FILE" 2>/dev/null | cut -d: -f2)
                    [ -z "$PASS" ] && PASS="? (no_log)"
                    echo -e "  ${GR}●${CR} ${WH}$u${CR}  ${DM}pass: $PASS  vence: $EXP  conex: $CONEX/$LIMITE${CR}"
                done
                echo ""
                read -p "$(echo -e ${DM})Enter para continuar...$(echo -e ${CR})" ;;
            2)
                read -p "$(echo -e ${DM})Usuario a ELIMINAR: $(echo -e ${CR})" DEL_USER
                if id "$DEL_USER" &>/dev/null; then
                    userdel -r "$DEL_USER" 2>/dev/null
                    sed -i "/^$DEL_USER:/d" "$DB_FILE" 2>/dev/null
                    echo -e "  ${GR}[+]${CR} Eliminado correctamente."
                else
                    echo -e "  ${RD}[-]${CR} Usuario no existe."
                fi
                read -p "$(echo -e ${DM})Enter...$(echo -e ${CR})" ;;
            3)
                read -p "$(echo -e ${DM})Usuario a modificar: $(echo -e ${CR})" MOD_USER
                if id "$MOD_USER" &>/dev/null; then
                    read -p "$(echo -e ${DM})Nuevos días (desde hoy): $(echo -e ${CR})" NEW_DAYS
                    if [[ "$NEW_DAYS" =~ ^[0-9]+$ ]]; then
                        NEW_EXP=$(date -d "+$NEW_DAYS days" +%Y-%m-%d)
                        usermod -e "$NEW_EXP" "$MOD_USER"
                        echo -e "  ${GR}[+]${CR} Vencimiento actualizado a ${WH}$NEW_EXP${CR}."
                    else
                        echo -e "  ${RD}[-]${CR} Valor inválido."
                    fi
                else
                    echo -e "  ${RD}[-]${CR} Usuario no existe."
                fi
                read -p "$(echo -e ${DM})Enter...$(echo -e ${CR})" ;;
            4)
                read -p "$(echo -e ${DM})Usuario: $(echo -e ${CR})" PASS_USER
                if id "$PASS_USER" &>/dev/null; then
                    read -s -p "$(echo -e ${DM})Nueva clave: $(echo -e ${CR})" NEW_PASS; echo ""
                    echo "$PASS_USER:$NEW_PASS" | chpasswd
                    sed -i "/^$PASS_USER:/d" "$DB_FILE" 2>/dev/null
                    echo "$PASS_USER:$NEW_PASS" >> "$DB_FILE"
                    echo -e "  ${GR}[+]${CR} Contraseña actualizada."
                else
                    echo -e "  ${RD}[-]${CR} Usuario no existe."
                fi
                read -p "$(echo -e ${DM})Enter...$(echo -e ${CR})" ;;
            0) break ;;
            *) echo -e "  ${RD}[-]${CR} Opción inválida."; sleep 1 ;;
        esac
    done
}
