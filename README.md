# VPSService Script - FREE

Panel de administración para servidores VPS en Ubuntu. Instala y configura protocolos de túnel, proxies y servicios VPN desde un menú interactivo en terminal.

---

## Instalación

### Descargar según rama

- `main`: versión estable del panel por terminal
- `beta`: versión con correcciones y pruebas de seguridad
- `panel`: versión visual con carpeta `web-panel/` y flujo web

```bash
bash <(curl -sL https://raw.githubusercontent.com/Juandocoro/Vpsservice-Bash-Free/panel/setup.sh)
```

El instalador pregunta qué rama deseas instalar y usa `panel` por defecto para el flujo web.

Si quieres instalar una rama específica, cambia `panel` por `main` o `beta` en la URL anterior.

Ejemplos:

```bash
bash <(curl -sL https://raw.githubusercontent.com/Juandocoro/Vpsservice-Bash-Free/beta/setup.sh)
bash <(curl -sL https://raw.githubusercontent.com/Juandocoro/Vpsservice-Bash-Free/panel/setup.sh)
```

El instalador realiza lo siguiente:
- Clona el repositorio en `/opt/vpsservice-free`
- Asigna permisos de ejecución a todos los scripts
- Instala las dependencias base (curl, python3, stunnel4, dropbear)
- Registra el comando `menu` de forma global
- Activa el monitor de cuotas (auto-killer por cron)

Una vez instalado, abre el panel desde cualquier directorio del servidor:

```bash
menu
```

---

## Protocolos disponibles

| Categoría | Protocolos |
|---|---|
| SSH / Túnel | Stunnel SSL, WebSocket, Dropbear |
| UDP | UDP Custom (1-65535), BadVPN Gateway |
| Proxy | SlowDNS, Squid |
| VPN | V2Ray (VMess+WS), Shadowsocks, OpenVPN, WireGuard |

---

## Requisitos

- Ubuntu 20.04 / 22.04 x86_64
- Acceso root
- VPS con puertos abiertos

---

## FREE vs BASIC

| Característica | FREE | BASIC |
|---|---|---|
| Clave de licencia | No requerida | Requerida |
| Validación externa | No | Sí |
| Protocolos | 11 | 3 |
| Auto-Killer | Sí | Sí |
| Actualizaciones OTA | Sí | Sí |

---

## Solución de problemas

Si el instalador no puede clonar el repositorio:

1. Confirma que el repo sea público: `https://github.com/Juandocoro/Vpsservice-Bash-Free`
2. Verifica que el servidor tenga acceso saliente a GitHub
3. Revisa los logs del instalador para más detalles

### Enlaces por rama

- Estable: https://raw.githubusercontent.com/Juandocoro/Vpsservice-Bash-Free/main/setup.sh
- Beta: https://raw.githubusercontent.com/Juandocoro/Vpsservice-Bash-Free/beta/setup.sh
- Panel: https://raw.githubusercontent.com/Juandocoro/Vpsservice-Bash-Free/panel/setup.sh

---

## Aviso legal

Este proyecto se distribuye con fines educativos y para la administración legítima de servidores VPS. El autor no se responsabiliza por el uso indebido de estas herramientas. El usuario es responsable de cumplir con las leyes y los términos de servicio de su país y proveedor de internet. Este software no contiene puertas traseras, registro de credenciales ni recolección de datos de ningún tipo.
