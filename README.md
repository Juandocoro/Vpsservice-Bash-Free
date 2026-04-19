# 🆓 vpsservice Script FREE

Suite de administración VPS — Sin licencia, sin verificaciones externas. Instala y corre en un solo comando.

---

## ⚡ Instalación — Un Solo Comando

Pega esto en la terminal de tu VPS (como root):

```bash
sudo bash <(curl -sL https://raw.githubusercontent.com/Juandocoro/Vpsservice-Bash-Free/main/setup.sh)
```

O con wget:
```bash
sudo bash <(wget -qO- https://raw.githubusercontent.com/Juandocoro/Vpsservice-Bash-Free/main/setup.sh)
```

El instalador hará todo automáticamente:
- ✅ Clona el repositorio en `/opt/vpsservice-free`
- ✅ Aplica permisos `+x` a todos los archivos
- ✅ Instala dependencias base (curl, stunnel4, dropbear, python3...)
- ✅ Activa el monitor de cuotas (cron Auto-Killer)
- ✅ Registra el comando global `menu`
- ✅ Abre el panel al terminar

---

## 🔁 Volver al panel después

Una vez instalado, desde cualquier carpeta escribe:

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
