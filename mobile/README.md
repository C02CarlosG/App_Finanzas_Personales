# Móvil (Flutter)

App de Finanzas Personales. **Offline-first**: la interfaz lee y escribe siempre en SQLite local y el motor de sincronización
(`lib/core/sync`) la reconcilia con la API según [`docs/sync.md`](../docs/sync.md).

Estado: **Paso 5 (Fase 2 en móvil)**. Login/registro, Bancos (selector visual, cuentas de banco y efectivo) con la pestaña
**Préstamos**, Categorías, ingreso/gasto, Inicio con datos reales y "pagos próximos", Movimientos (filtros, búsqueda, total del
mes) con las secciones de Gastos **Suscripciones** y **Tarjetas**, sync automático y sesión expirada. Reportes y Perfil completo
llegan en pasos posteriores (6 y 7).

## Comandos

Requiere Flutter 3.47+ (Dart 3.13+). Desde `mobile/`:

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # genera el código de drift (*.g.dart, no se versiona)
flutter analyze
flutter test                                               # unitarias + interfaz (la e2e se omite sin E2E_API_URL)

# Correr la app
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:3000   # emulador Android → API en el equipo
flutter run --dart-define=DEMO_MODE=true                       # SOLO desarrollo: base local con datos de ejemplo, sin login ni servidor
```

**Prueba de extremo a extremo** (dos dispositivos simulados contra la API real):

```bash
cd backend && SYNC_SAFETY_LAG_MS=0 PORT=3111 JWT_SECRET=x DATABASE_URL=postgres://... npm run migrate && node src/server.js
cd mobile && E2E_API_URL=http://localhost:3111 flutter test test/e2e
```

El CI (`.github/workflows/ci.yml`) corre todo lo anterior y, en el trabajo `mobile-demo`, publica como artefactos un **APK de
depuración** y la **web** en modo demo.

## Estructura

```
lib/
  main.dart, app.dart            Arranque y MaterialApp.router
  core/
    config/        AppConfig (API_BASE_URL, DEMO_MODE por --dart-define)
    money/         Money: centavos enteros, nunca double
    db/            drift: tables.dart (espejo del servidor + outbox), AppDatabase (una base por usuario), LocalStore (escrituras + outbox)
    sync/          SyncEngine (push→pull), SyncApi, adaptadores por tabla, StampClock (sellos µs crecientes)
    network/       ApiClient (JWT, errores tipados), ApiException
    storage/       SessionStore (token en almacenamiento seguro)
    router/        go_router con redirección por sesión y barra inferior
    providers.dart Riverpod: sesión, base local, motor de sync
  features/        auth · dashboard · accounts · categories · transactions (formulario y Movimientos) · loans · subscriptions · cards · sync (banner y problemas) · reports · profile
  core/data/       repositorios con reglas de negocio y providers reactivos; core/demo: datos de ejemplo (DEMO_MODE)
test/              core · sync (motor, con SQLite en memoria) · features (interfaz) · e2e (API real)
```

## Cómo funciona el sync automático

`SyncController` (`core/sync/sync_controller.dart`) dispara el ciclo push→pull: al arrancar, 2 s después de la última escritura local
(*debounce*), al volver a la app, cada 5 min y con reintentos con retroceso (30 s, 60 s… hasta 5 min) si falla. No usa
`connectivity_plus`: un fallo de red se reintenta solo. Un **401** marca la sesión como expirada: se deja de reintentar, se conservan la
base local y la outbox, y el banner lleva a reingresar con el mismo correo (el token nuevo reanuda el sync). Los cambios que el servidor
rechaza se revisan en **Problemas de sincronización** (editar o eliminar).

## Decisiones

- **Estado: Riverpod 3.** Inyección de dependencias simple (la base local depende de la sesión y se cierra al cambiar de usuario), fácil de probar con `overrides`.
- **Navegación: go_router.** Redirección declarativa por sesión y `StatefulShellRoute` para conservar el estado de cada pestaña.
- **SQLite: drift.** Consultas tipadas, migraciones, mismo código en Android y web.
- **Dinero:** `Money` guarda centavos enteros; el servidor intercambia strings decimales (`"250.50"`). No hay `double` en el flujo.
- **Una base por usuario** (`finanzas_<userId>`): outbox, cursor y datos nunca se mezclan entre cuentas.
- **Escribir solo por `LocalStore`:** cada cambio sella `client_updated_at` y deja su renglón en la outbox en una sola transacción.
- **`StampClock`:** sellos con 6 decimales y **estrictamente crecientes**; el motor distingue "edité mientras se enviaba" comparando sellos. Al arrancar restaura el desfase de reloj y no emite sellos menores al mayor ya guardado.
- **`maybe_sent`:** la outbox marca (de forma persistente, antes de enviar) lo que pudo llegar al servidor; un borrado posterior deja tombstone y se envía, en vez de eliminar la fila y dejar que el servidor la resucite.
- **Sesión guardada = confianza sin red:** al abrir la app no se consulta al servidor; el primer login sí requiere internet.
- **Escribir solo por repositorios** (`features/*/data`): validan con las reglas del servidor (nombre único por tipo, cuenta/categoría en uso, monto > 0…) y escriben por `LocalStore`.
- **Listados en pantalla Movimientos** (Inicio → "Ver todos"), con pestañas Ingresos | Gastos; la barra inferior queda como el spec. Filtro por **cuenta** (cubre banco y efectivo), no solo por banco.
- **Logos de bancos:** `assets/banks/<logo_key>.png` si existe; si no, iniciales con el color de marca. Hoy no hay logos reales en el repo.
- **Fechas y dinero sin `intl`:** `core/format/dates.dart` y `Money`/`parseMoneyInput` (acepta `$`, comas de miles y coma decimal). El selector de fecha va en es-MX con `flutter_localizations` (del SDK).
- **Modo demo (`DEMO_MODE`)** siembra una base local de ejemplo y es solo para desarrollo; nunca en producción.

## Dependencias

| Paquete | Para qué |
|---|---|
| `flutter_riverpod` | Estado e inyección de dependencias |
| `go_router` | Navegación con redirección por sesión y barra inferior |
| `drift`, `drift_flutter`, `drift_dev`, `build_runner` | SQLite local tipada (generación de código en desarrollo) |
| `http` | Cliente HTTP (suficiente para JSON + JWT) |
| `flutter_secure_storage` | Guardar el JWT cifrado en el dispositivo |
| `uuid` | UUID v4 generados en el dispositivo (ids de registros offline) |
| `flutter_localizations` (SDK) | Selector de fecha y textos de Material en español |
| `fake_async` (dev) | Probar temporizadores del sync (debounce, reintentos) con reloj simulado |

## Pendiente (siguientes pasos)

- **Reglas de la Fase 2 (resumen):** el pendiente de un préstamo se deriva (`original + aumentos − abonos`); un abono mueve el saldo de la
  cuenta elegida (cobro = ingreso "Préstamo cobrado" + persona; pago de una deuda o de tarjeta = gasto de sistema) y su transacción solo se
  modifica desde el préstamo/tarjeta; los aumentos no mueven saldos; eliminar un préstamo o tarjeta conserva los ingresos/gastos ya
  registrados. Detalle y razones en [`docs/sync.md`](../docs/sync.md) §2.
- **Esquema local v2:** `schemaVersion = 2` con migración que agrega las tablas de la Fase 2 a bases creadas con la v1.
- **Búsqueda y orden sin acentos:** SQLite compara ASCII sin distinguir mayúsculas; "cafe" no encuentra "Café" y las letras acentuadas ordenan al final. Pendiente una normalización.
- **Web con base local:** `web/sqlite3.wasm` (sqlite3 3.7.1, de [sqlite3.dart](https://github.com/simolus3/sqlite3.dart/releases)) y `web/drift_worker.js` (drift 2.35.2, de [drift](https://github.com/simolus3/drift/releases)) deben coincidir con las versiones de `pubspec.lock`. Si se actualiza drift/sqlite3, hay que volver a descargarlos.
- iOS: se agrega la plataforma cuando haya Mac/CI para compilarla.
- Pruebas de interfaz con la base real en dispositivo (hoy se prueban con SQLite en memoria).
