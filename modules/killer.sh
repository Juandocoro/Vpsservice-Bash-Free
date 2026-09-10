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

    # FIX: Contar sesiones SSH reales usando 'ss' (más preciso que ps).
    # ps contaba procesos hijos de sshd incluyendo los del WebSocket proxy
    # que corren como root → conteo erróneo que mataba sesiones legítimas.
    CONEX=$(ss -tnp 2>/dev/null | grep -E "ESTABLISHED" | \
            grep -v "127\.0\.0\.1" | \
            awk '{print $NF}' | grep -o "pid=[0-9]*" | \
            sed 's/pid=//' | \
            xargs -I{} sh -c 'ps -p {} -o user= 2>/dev/null' | \
            grep -c "^${u}$")
    # FIX: no encadenar '|| echo 0'. grep -c ya imprime 0 y sale con codigo 1,
    # asi que el fallback anadia un segundo 0 -> CONEX="0\n0" -> fallaba la
    # validacion numerica de abajo y la rama con 'ss' nunca se usaba.

    # Fallback: si ss no da resultado, usar ps directamente
    if [ -z "$CONEX" ] || ! [[ "$CONEX" =~ ^[0-9]+$ ]]; then
        CONEX=$(ps -u "$u" -o comm= 2>/dev/null | grep -E "^(sshd|dropbear)$" | wc -l)
    fi

    # Si las conexiones superan el límite de la licencia del usuario...
    if [ "$CONEX" -gt "$LIMITE" ]; then
        # FIX: NO usar pkill -f "sshd" porque -f hace match sobre la ruta completa
        # del daemon padre (/usr/sbin/sshd) y puede matar el servicio SSH entero.
        # Se usa pkill sin -f para hacer match exacto solo en el nombre del proceso.
        pkill -u "$u" sshd 2>/dev/null
        pkill -u "$u" dropbear 2>/dev/null
        pkill -u "$u" stunnel 2>/dev/null
    fi

done
