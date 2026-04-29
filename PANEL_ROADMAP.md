# VPSService PANEL — Roadmap de Mejoras

**Rama:** `panel`  
**Base:** `beta` (incluye todos los fixes de seguridad)  
**Estado:** Rama feature para mejorar la interfaz y experiencia del panel  
**Propósito:** Desarrollar versión mejorada del menú interactivo terminal

---

## 🎯 Objetivos de la Rama Panel

Mejorar la experiencia del usuario en el menú terminal actual (`main.sh`) sin sacrificar estabilidad.

---

## 📋 Roadmap de Features

### Fase 1: Mejoras de UX (Prioridad Alta)

- [ ] **1.1 - Navegación mejorada**
  - Agregar números de opción con highlighting
  - Permitir salir con `q` o `ESC` desde cualquier submenú
  - Mostrar breadcrumb (ej: `Main > Protocolos > Stunnel`)
  - Mejor visualización de estado ON/OFF con símbolos

- [ ] **1.2 - Búsqueda rápida**
  - Búsqueda de protocolos por nombre
  - Buscar usuarios por nombre
  - Filtrar puertos activos

- [ ] **1.3 - Paginación**
  - Si hay muchos usuarios → paginar lista
  - Si hay muchos protocolos activos → scrollable

- [ ] **1.4 - Confirmaciones mejoradas**
  - Antes de eliminar usuario → confirmar dos veces
  - Antes de desinstalar protocolo → mostrar dependencias
  - "¿Estás seguro? (s/n)" → mejorar visual

### Fase 2: Información Mejorada (Prioridad Media)

- [ ] **2.1 - Dashboard principal**
  - Gráfico ASCII de uso de recursos
  - Timeline de últimas acciones
  - Alertas de seguridad (puertos duplicados, etc)

- [ ] **2.2 - Detalles de servicios**
  - Ver logs últimos 5 minutos de cada protocolo
  - Mostrar consumo de CPU/RAM por servicio
  - Estado de conectividad de cada usuario

- [ ] **2.3 - Reportes**
  - Generar reporte de configuración actual
  - Exportar lista de usuarios y puertos (JSON)
  - Auditoría de cambios recientes

### Fase 3: Automatización (Prioridad Media)

- [ ] **3.1 - Tareas programadas**
  - Menu → "Programar tareas" (reinicio automático, backups, limpieza)
  - Ver tareas cron configuradas

- [ ] **3.2 - Snapshots de configuración**
  - Guardar estado actual de servicios
  - Restaurar desde snapshot anterior
  - Comparar cambios entre snapshots

### Fase 4: Temas y Personalización (Prioridad Baja)

- [ ] **4.1 - Temas de color**
  - Tema oscuro (actual) vs claro
  - Guardar preferencia de tema por usuario

- [ ] **4.2 - Atajo de teclado**
  - `ctrl+d` → dashboard
  - `ctrl+u` → usuarios
  - `ctrl+p` → protocolos
  - `ctrl+s` → salir

---

## 🔧 Cambios Técnicos Esperados

```bash
# Archivo principal
main.sh
  ├─ Refactorizar funciones de navegación
  ├─ Agregar función de búsqueda genérica
  ├─ Mejorar paleta de colores
  └─ Agregar manejo de entrada mejorado

# Módulos nuevos
modules/ui/
  ├─ helpers.sh        (funciones de UI reutilizables)
  ├─ theme.sh          (paleta de colores y tema)
  ├─ navigation.sh     (menú y navegación)
  └─ dashboard.sh      (vista principal mejorada)

modules/reports/
  ├─ export.sh         (exportar en JSON/CSV)
  ├─ audit.sh          (auditoría de cambios)
  └─ snapshot.sh       (guardar/restaurar estado)
```

---

## 📝 Notas de Desarrollo

### Standards de Código

- Mantener compatibilidad con bash 4.x+ (Ubuntu 20.04+)
- Seguir naming conventions actuales (`_ok`, `_info`, `_err`)
- Documentar funciones nuevas con comentarios
- Preservar todos los fixes de seguridad de rama `beta`

### Testing Esperado

- [ ] Probar en Ubuntu 20.04 LTS
- [ ] Probar en Ubuntu 22.04 LTS
- [ ] Validar que no se rompe ningún instalador
- [ ] Performance: menú debe responder en < 500ms

### Merge a Beta

Una vez completada una fase:
```bash
git checkout beta
git merge panel --no-ff  # Merge commit para trazabilidad
```

---

## 🚀 Cómo Contribuir a esta Rama

```bash
# Cambiar a rama panel
git checkout panel

# Crear branch feature desde panel
git checkout -b panel/feature-name

# Hacer cambios...
git add .
git commit -m "feat: descripcion del cambio"

# Publicar feature branch
git push origin panel/feature-name

# Crear Pull Request en GitHub (panel/feature-name → panel)
```

---

## ✅ Checklist Previo a Merge

Antes de mergear a `beta`:

- [ ] Todos los fixes de seguridad de `beta` están intactos
- [ ] Ningún protocolo roto
- [ ] Menu principal funciona sin errores
- [ ] Usuarios pueden crearse/eliminarse
- [ ] Todos los instaladores funcionan
- [ ] Logs no muestran warnings/errores

---

## 📊 Versionamiento

- **main** (v1.x) → Estable, cambios mínimos
- **beta** (v2.0) → Fixes de seguridad críticos
- **panel** (v2.x) → Mejoras de UX y features
- **panel/feature-\*** → Features en desarrollo

---

## 🔗 Referencias

- Branch base: `beta` (9a43729)
- Diferencias: `git diff beta panel` (antes de cambios)
- Pull Request: https://github.com/Juandocoro/Vpsservice-Bash-Free/pull/new/panel

---

**Estado:** 🟢 Abierto para desarrollo
