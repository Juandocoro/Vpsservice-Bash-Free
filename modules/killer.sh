#!/bin/bash
# =========================================================
# MONITOR AUTO-KILLER (Protección Activa de Cuota)
# Diseñado para ejecutarse silenciosamente en segundo plano
# =========================================================

# Extrae usuarios válidos creados por el administrador
awk -F':' '($3 >= 1000 && $3 != 65534 && $1 != "nobody" && $1 != "ubuntu") {print $1}' /etc/passwd | while read u; do

    # Obtiene su límite oficial desde el núcleo GECOS
    LIMITE=$(getent passwd "$u" | cut -d: -f5)

    # Si no tiene un número lícito, lo omitimos para no causar errores
    if [[ ! "$LIMITE" =~ ^[0-9]+$ ]]; then continue; fi

    # Escanea las conexiones reales
    CONEX=$(ps -u "$u" -o comm= 2>/dev/null | grep -E "^(sshd|dropbear)$" | wc -l)

    # Si las conexiones superan el límite de la licencia del usuario...
    if [ "$CONEX" -gt "$LIMITE" ]; then
        # Manda una señal de terminación de procesos (SIGTERM / SIGKILL)
        # a cualquier hilo nativo o túnel del infractor, obligándolo a reconectarse.
        pkill -u "$u" -f "sshd" 2>/dev/null
        pkill -u "$u" -f "dropbear" 2>/dev/null
        pkill -u "$u" -f "stunnel" 2>/dev/null
    fi

done
