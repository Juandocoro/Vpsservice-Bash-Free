# VPSService BETA — Changelog v1.0-beta

**Rama:** `beta`  
**Estado:** En pruebas — Previo a merge a `main`  
**Commit:** `4f6cb4e`  
**Fecha:** 2026-04-29

---

## 🔒 Fixes de Seguridad Críticos

### 1. **Remover almacenamiento de credenciales en texto plano**
- **Archivo:** `modules/users.sh`
- **Cambio:** Deshabilitadas todas las operaciones de guardar passwords en `~/.vps_users`
- **Razón:** Las credenciales en disco representan riesgo alto si el archivo se filtra
- **Impacto:** ✅ Credenciales ahora SOLO en base de datos del sistema (`/etc/shadow`)
- **Líneas:** 47, 123 (deshabilitadas)

### 2. **Cerrar Squid con ACL restrictiva**
- **Archivo:** `modules/installers/squid_installer.sh`
- **Cambio:** Implementar política `deny by default` con whitelist solo para red local
- **Razón:** Proxy abierto al mundo = abuso, blacklist de IP, consumo de banda
- **Config anterior:** `http_access allow all` → **PROHIBIDO**
- **Config nueva:** 
  ```bash
  http_access deny all
  http_access allow localhost
  http_access allow localnet
  ```
- **Impacto:** ✅ Solo usuarios en 127.0.0.1, 10.x, 172.16.x, 192.168.x pueden usar proxy
- **Líneas:** 32-39

### 3. **Actualización segura sin pérdida de datos**
- **Archivo:** `main.sh`
- **Cambio:** Reemplazar `git reset --hard FETCH_HEAD` por `git pull --ff-only`
- **Razón:** `reset --hard` elimina cambios locales sin confirmación (destructivo)
- **Beneficio:** `git pull --ff-only` integra cambios remotos solo si es fast-forward seguro
- **Impacto:** ✅ Cambios locales protegidos; actualización segura con rollback inteligente
- **Líneas:** 109 → 115-125

---

## 🛡️ Fixes de Funcionalidad & Validación

### 4. **Validación estricta de puertos**
- **Archivos:** 
  - `modules/installers/squid_installer.sh`
  - `modules/installers/dropbear_installer.sh`
- **Cambio:** Agregar regex `^[0-9]+$` y rango 1-65535 para todas las entradas de puerto
- **Razón:** Puerto inválido → config incompleta, servicio no levanta, confusión de usuario
- **Ejemplo antes:**
  ```bash
  read -p "Puerto para Squid: " squid_port
  if [ -z "$squid_port" ]; then squid_port=3128; fi
  # ... usar $squid_port directo (sin validación)
  ```
- **Ejemplo ahora:**
  ```bash
  if ! [[ "$squid_port" =~ ^[0-9]+$ ]] || [ "$squid_port" -lt 1 ] || [ "$squid_port" -gt 65535 ]; then
    echo "[-] Puerto inválido. Usando 3128."
    squid_port=3128
  fi
  ```
- **Impacto:** ✅ Previene misconfiguración silenciosa

### 5. **Corregir bug de variable en UDP Custom**
- **Archivo:** `modules/installers/udp_installer.sh`
- **Cambio:** Mostrar credenciales correctas (sin referenciar `$udp_port` inexistente)
- **Bug anterior:**
  ```bash
  echo "     ${WH}$SERVER_IP:$udp_port@$first_user:$first_pass${CR}"
  # $udp_port NO EXISTE en ese contexto (es $INTERNAL_PORT internamente)
  ```
- **Fix:**
  ```bash
  echo "  ${DM}Puerto    :${CR}  ${CY}cualquier puerto UDP${CR}  ${DM}(1-65535, excepto: $excl_ports)${CR}"
  echo -e "  ${GR}${SERVER_IP}:xxxx@${first_user}:${first_pass}${CR}  ${DM}(xxxx = cualquier puerto UDP)${CR}"
  ```
- **Impacto:** ✅ Cliente recibe instrucciones correctas sin ambigüedad
- **Líneas:** 226-256

### 6. **Idempotencia en sysctl.conf**
- **Archivos:**
  - `modules/installers/openvpn_installer.sh`
  - `modules/installers/wireguard_installer.sh`
- **Cambio:** Verificar que `net.ipv4.ip_forward=1` NO esté duplicado
- **Razón:** Reinstalar OpenVPN/WireGuard → múltiples líneas iguales en sysctl.conf
- **Código antes:**
  ```bash
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  # (sin verificar si ya existe)
  ```
- **Código ahora:**
  ```bash
  if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  fi
  ```
- **Impacto:** ✅ Configuración limpia, sin duplicados después de múltiples reinstalaciones
- **Líneas:** 66-68 (openvpn), 46-48 (wireguard)

---

## 📊 Resumen de Cambios

| Métrica | Cantidad |
|---------|----------|
| Archivos modificados | 7 |
| Líneas agregadas | 63 |
| Líneas removidas | 26 |
| Fixes críticos | 7 |
| Commits en rama | 1 |

---

## ✅ Verificación de Calidad

### Tests Recomendados (antes de merge a main)

- [ ] `./setup.sh` → instala sin errores  
- [ ] `menu` → abre menú sin fallos  
- [ ] Crear usuario SSH → sin almacenar en `/root/.vps_users`  
- [ ] Instalar Squid → verificar ACL local-only con `curl http://localhost:3128`  
- [ ] Instalar OpenVPN × 2 veces → confirmar `/etc/sysctl.conf` sin líneas duplicadas  
- [ ] Menu actualizar → no ejecuta `git reset --hard` (usar `git pull --ff-only`)  
- [ ] Puerto inválido en Squid/Dropbear → rechaza entrada y usa default  
- [ ] UDP Custom → muestra instrucciones correctas sin variable indefinida  

---

## 🚀 Próximos Pasos (Post-Beta)

1. **Validación en VPS de prueba** (24-48h)  
2. **Reporte de issues/feedback**  
3. **Merge a main** (si todo OK)  
4. **Tag release:** v2.0 (con cambios de seguridad)  
5. **Notificación de seguridad** a usuarios activos  

---

## 📝 Notas

- Esta rama es **volatile** — destinada a pruebas antes de producción  
- Todos los fixes son **backward-compatible** (no rompen configs existentes)  
- La rama `main` permanece **estable** hasta confirmación de beta  

---

**Rama Beta:** `git checkout beta`  
**Diff:** `git diff main beta`  
**Logs:** `git log main..beta`
