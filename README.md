# 🆓 vpsservice Script FREE

Suite de administración VPS — Sin licencia, sin verificaciones externas.

---

## ⚡ Instalación — Un Solo Comando

### ✅ Con curl (recomendado):
```bash
curl -sL https://raw.githubusercontent.com/Juandocoro/Vpsservice-Bash-Free/main/setup.sh -o /tmp/vps.sh && sudo bash /tmp/vps.sh
```

### ✅ Con wget:
```bash
wget -qO /tmp/vps.sh https://raw.githubusercontent.com/Juandocoro/Vpsservice-Bash-Free/main/setup.sh && sudo bash /tmp/vps.sh
```

> ⚠️ **Nota:** Asegúrate de que el repositorio esté subido y sea público antes de usar estos comandos.

El instalador hace todo automáticamente:
- ✅ Clona el repositorio en `/opt/vpsservice-free`
- ✅ Aplica permisos `+x` a todos los archivos
- ✅ Instala dependencias base (curl, stunnel4, dropbear, python3...)
- ✅ Activa el monitor de cuotas (cron Auto-Killer)
- ✅ Registra el comando global `menu`
- ✅ Abre el panel al terminar

---

## 🔁 Volver al panel después de instalar

Desde cualquier carpeta en el VPS escribe:

```bash
menu
```

---

## 📦 Protocolos disponibles

| Categoría | Protocolos |
|---|---|
| SSH | Stunnel SSL, UDP/BadVPN, WebSocket, Dropbear |
| Proxy | SlowDNS, Squid HTTP Proxy |
| VPN | V2Ray (VMess+WS), Shadowsocks, OpenVPN, WireGuard |

---

## 🆚 Diferencias vs BASIC

| Feature | FREE | BASIC |
|---|---|---|
| Key de licencia | ❌ No requiere | ✅ Requerida |
| Validación externa | ❌ No | ✅ Sí |
| Protocolos | ✅ 10 | ✅ 3 |
| Panel con colores | ✅ | ✅ |
| Auto-Killer | ✅ | ✅ |
| Actualizaciones OTA | ✅ | ✅ |

---

## 🐛 Si el instalador falla

Si el comando da error al clonar:
1. Verifica que el repo exista: `https://github.com/Juandocoro/Vpsservice-Bash-Free`
2. Asegúrate que sea **público**
3. Prueba con el método wget como alternativa
