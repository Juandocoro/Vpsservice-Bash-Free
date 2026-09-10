# VPSService Script - FREE

Panel de administración para servidores VPS en Ubuntu. Instala y configura protocolos de túnel, proxies y servicios VPN desde un menú interactivo en terminal.

---

## Instalación

```bash
bash <(curl -sL https://raw.githubusercontent.com/Juandocoro/Vpsservice-Bash-Free/main/setup.sh)
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

## El panel

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   ►►►  V P S S E R V I C E  ◄◄◄       [ FREE · v1.0 · e6b47c7 ]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  OS: Ubuntu 22.04    ▸ ARCH: x86_64        ▸ CORES: 2
  IP: 216.238.77.196  ▸ HORA: 12:17:35      ▸ UPTIME: 3d 4h
────────────────────────────────────────────────────────────────
  ● RAM   ▰▰▰▱▱▱▱▱▱▱ 77Mi/976Mi     (8%)
  ● DISCO ▰▰▰▰▱▱▱▱▱▱ 3.2G/25G       (13%)
  ● CPU   ▰▱▱▱▱▱▱▱▱▱ 2 nucleo(s)    (4%)
────────────────────────────────────────────────────────────────
  CUENTAS  ▸ Activas: 3      ▸ Por vencer: 1     ▸ Vencidas: 0
  ONLINE   ▸ SSH: 2          ▸ Dropbear: 1       ▸ OpenVPN: 0
────────────────────────────────────────────────────────────────
  ▪ SSH: 22           ▸ ▪ Dropbear: 442     ▸ ▪ SSL: 443
  ▪ WebSocket: 80     ▸ ▪ BadVPN: 7300      ▸ ▪ V2Ray: 8080
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  [1] ▸ ADMINISTRAR CUENTAS     │ crear · editar
  [2] ▸ FÁBRICA DE TÚNELES      │ 11 protocolos
  [3] ▸ ARRANQUE AUTOMÁTICO                        [ OFF ]
  [4] ▸ ACTUALIZAR SCRIPT       │ desde GitHub
  [5] ▸ DESINSTALAR PANEL       │ borrado total
  [6] ▸ SINCRONIZAR UFW         │ cortafuegos
  [7] ▸ OPTIMIZAR SERVIDOR      │ RAM · caché
  [8] ▸ GATEWAY RESIDENCIAL     │ WireGuard       [ ON  ]

  [0] ▸ SALIR
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Digita una acción [0-8] »
```

Todo el aspecto gráfico vive en un único módulo, `modules/ui.sh`: paleta,
marcos, celdas alineadas, barras de carga y etiquetas `[ ON ]` / `[ OFF ]`.
El resto de módulos e instaladores lo importan, así que cambiar un color o el
ancho del panel se hace en un solo sitio y afecta a todas las pantallas.

---

## Estructura

```
main.sh                     Panel principal y bucle de menús
setup.sh                    Instalador remoto (clona y configura el VPS)
modules/
  ui.sh                     Lenguaje visual compartido
  network.sh                Tablero de estado, puertos y cortafuegos UFW
  users.sh                  Alta, baja y monitor de cuentas
  optimize.sh               Limpieza de RAM, swap, caché y logs
  killer.sh                 Auto-killer de cuotas (cron, cada minuto)
  installers/               Un script por protocolo (11 en total)
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

---

## Aviso legal

Este proyecto se distribuye con fines educativos y para la administración legítima de servidores VPS. El autor no se responsabiliza por el uso indebido de estas herramientas. El usuario es responsable de cumplir con las leyes y los términos de servicio de su país y proveedor de internet. Este software no contiene puertas traseras, registro de credenciales ni recolección de datos de ningún tipo.
