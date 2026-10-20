# App de Seguimiento de Ingresos y Gastos — Documento de Especificación

## 1. Resumen del proyecto

Aplicación móvil (Android/iOS) para seguimiento de ingresos, gastos, bancos, efectivo y préstamos personales. Diseñada para uso individual inicial (dueño + amigos cercanos), con visión de escalar a modelo de suscripción y público general.

**Problema que resuelve:** falta de visibilidad sobre finanzas personales — faltantes de dinero no rastreados, suscripciones olvidadas, y préstamos informales sin control.

---

## 2. Stack tecnológico

| Capa | Tecnología |
|---|---|
| Móvil (Android/iOS) | Flutter |
| Backend / API | Node.js + Express |
| Base de datos | PostgreSQL |
| Frontend web (futuro) | React + TypeScript |
| Almacenamiento local (offline) | SQLite local en dispositivo (Flutter) con sincronización a PostgreSQL |

**Justificación:**
- Flutter → un solo código base para Android e iOS.
- Node.js/Express → desarrollo ágil de API REST.
- PostgreSQL → robustez para app multiusuario (vs. SQLite en servidor).

---

## 3. Requisitos no funcionales

- **Autenticación de usuario:** cada persona tiene su cuenta (registro/login).
- **Modo offline first:** los datos se guardan localmente en el dispositivo y se sincronizan automáticamente con el servidor cuando hay conexión a Internet.
- **Escalabilidad:** arquitectura pensada para crecer de uso personal a modelo de suscripción con múltiples usuarios.

---

## 4. Módulos funcionales

### 4.1 Tipos de efectivo
Dos formas de dinero:
- **Cuenta bancaria**
- **Efectivo en mano**

### 4.2 Bancos
- Listado de bancos registrados por el usuario, con logo (BBVA, Santander, Scotiabank, Banamex, etc. — selección visual al agregar).
- Al agregar un banco: nombre/logo del banco, saldo inicial, tipo de cuenta (débito o crédito — opcional).
- Cada banco muestra su saldo actual, actualizado por los movimientos de ingresos/gastos asociados.

### 4.3 Ingresos
- Registro con: monto, categoría, tipo de efectivo (banco específico o efectivo), fecha, descripción opcional.
- **Categorías sugeridas:** salario/quincena, freelance, negocio propio, inversiones, bonificaciones, regalos, reembolsos, préstamo cobrado (con nombre de la persona), y categoría personalizada.
- Pantalla de listado: ordenado por fecha (más reciente primero), filtro por categoría, filtro por banco, búsqueda por descripción, resumen de total del mes.

### 4.4 Gastos
- Registro con: monto, categoría, tipo de efectivo, fecha, descripción opcional.
- **Categorías sugeridas:** vivienda, transporte, alimentación, servicios, entretenimiento, educación, salud, y categoría personalizada.
- Pantalla organizada en **pestañas**:
  1. **Gastos generales** — listado filtrable por categoría y banco, búsqueda, resumen mensual.
  2. **Suscripciones** — listado de servicios recurrentes (Netflix, Spotify, Amazon, etc.): nombre del servicio, monto, fecha de renovación. Objetivo: evitar que el usuario olvide qué tiene contratado.
  3. **Pagos de tarjeta de crédito** — listado de tarjetas: saldo pendiente, fecha de vencimiento, registro de pagos.

### 4.5 Préstamos / Deudas
- Registro de dinero prestado (a alguien) o recibido en préstamo (de alguien).
- Datos por préstamo: nombre de la persona, monto, dirección de la deuda (le debo / me debe), plazo de pago **opcional** (puede no tener fecha límite).
- Acciones sobre un préstamo activo:
  - **Abonar** (reduce el monto pendiente).
  - **Aumentar monto** (si la persona presta más dinero adicional).
  - **Marcar como pagado**.
- Cuando se cobra un préstamo, se registra como ingreso con categoría "préstamo cobrado" + nombre de la persona.

### 4.6 Reportes y gráficas
- Comparativa ingresos vs. gastos del mes actual (números destacados).
- Gráfica de pastel: desglose de gastos por categoría.
- Gráfica de líneas: tendencia de los últimos 3 meses.

### 4.7 Presupuestos
- Límites mensuales configurables por categoría de gasto.
- Alertas cuando el usuario se acerca o excede el límite.

### 4.8 Exportación
- Exportar movimientos/reportes a Excel o PDF (para auditoría personal o compartir con un contador).

### 4.9 Categorías y configuración
- Crear/editar categorías personalizadas (ingresos y gastos).
- Cambiar moneda.
- Ajustes generales de la app.

### 4.10 Perfil de usuario
- Cambiar contraseña, correo, datos personales.
- Base para futura gestión de suscripción de pago.

---

## 5. Diseño de pantallas

### 5.1 Navegación general
**Menú inferior (bottom navigation)** con 5 secciones: Inicio, Bancos, Categorías, Reportes, Perfil.

### 5.2 Dashboard (Inicio)
- Saldo total (arriba, destacado).
- Dos botones grandes: **Agregar ingreso** / **Agregar gasto**.
- Listado de últimas transacciones.
- Sección de suscripciones y gastos pendientes próximos.

### 5.3 Agregar ingreso
Campos: monto, categoría (selector), tipo de efectivo — banco (dropdown, con opción de crear banco nuevo desde ahí) o efectivo, fecha, descripción (opcional).

### 5.4 Agregar gasto
Mismos campos que ingreso, adaptados a categorías de gasto.

### 5.5 Bancos
- Listado de bancos con nombre/logo y saldo actual.
- Botón "Agregar banco" → selector visual de bancos (BBVA, Santander, Scotiabank, Banamex, etc.) + saldo inicial + tipo de cuenta (opcional).

### 5.6 Ingresos
- Listado filtrable (categoría, banco) + búsqueda + resumen del mes.

### 5.7 Gastos
- Pestañas: Gastos generales / Suscripciones / Pagos tarjeta de crédito.

### 5.8 Préstamos
- Listado de préstamos activos: persona, monto, dirección (le debo/me debe), plazo si existe.
- Detalle de préstamo: historial de abonos, botones abonar / aumentar monto / marcar pagado.

### 5.9 Reportes
- Comparativa ingresos vs. gastos, gráfica de pastel por categoría, gráfica de líneas de tendencia (3 meses).

### 5.10 Categorías y configuración
- CRUD de categorías personalizadas, moneda, ajustes generales.

### 5.11 Perfil
- Datos de usuario, cambio de contraseña/correo.

---

## 6. Plan de desarrollo por fases

**Fase 1 — Núcleo funcional**
- Autenticación de usuario.
- Dashboard básico.
- Módulo de bancos (registro, saldo).
- Ingresos y gastos básicos (sin sub-módulos).

**Fase 2 — Módulos complementarios**
- Préstamos/deudas.
- Suscripciones.
- Pagos de tarjeta de crédito.

**Fase 3 — Analítica**
- Reportes y gráficas.
- Presupuestos y alertas.

**Fase 4 — Pulido y escalabilidad**
- Exportación a Excel/PDF.
- Perfil de usuario y ajustes.
- Sincronización offline robusta.
- Preparación para modelo de suscripción.

> **Nota de continuidad:** si el desarrollo se interrumpe, este documento sirve como referencia para retomar el trabajo — identifica en qué fase te quedaste y qué módulos de esa fase faltan.

---

## 7. Notas para Claude Code

- Priorizar arquitectura offline-first desde el inicio (no agregar como parche después).
- Diseñar el modelo de datos de bancos/ingresos/gastos/préstamos con relaciones claras desde la Fase 1, aunque los módulos de fases posteriores se implementen después — evita refactors grandes.
- Las categorías deben ser una tabla editable por el usuario, no un enum fijo en código.
