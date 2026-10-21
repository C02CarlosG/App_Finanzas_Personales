# Móvil (Flutter)

App de Finanzas Personales. **Offline-first**: la interfaz lee y escribe siempre en SQLite local y el motor de sincronización
(`lib/core/sync`) la reconcilia con la API según [`docs/sync.md`](../docs/sync.md).

Estado: **Paso 3 (scaffold)**. Hay login/registro, barra inferior con las 5 secciones, capa de datos local, cliente HTTP y motor de
sync probado contra el backend real. Las pantallas de negocio (bancos, transacciones, etc.) llegan en el Paso 4.

## Comandos

Requiere Flutter 3.47+ (Dart 3.13+). Desde `mobile/`:

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # genera el código de drift (*.g.dart, no se versiona)
flutter analyze
flutter test                                               # unitarias + interfaz (la e2e se omite sin E2E_API_URL)

# Correr la app
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:3000   # emulador Android → API en el equipo
flutter run --dart-define=DEMO_MODE=true                       # SOLO para ver pantallas: sin login ni servidor
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
  features/        auth · dashboard · accounts · categories · transactions · reports · profile
test/              core · sync (motor, con SQLite en memoria) · features (interfaz) · e2e (API real)
```

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
- **Modo demo (`DEMO_MODE`)** es solo para revisar pantallas; nunca en producción.

## Dependencias

| Paquete | Para qué |
|---|---|
| `flutter_riverpod` | Estado e inyección de dependencias |
| `go_router` | Navegación con redirección por sesión y barra inferior |
| `drift`, `drift_flutter`, `drift_dev`, `build_runner` | SQLite local tipada (generación de código en desarrollo) |
| `http` | Cliente HTTP (suficiente para JSON + JWT) |
| `flutter_secure_storage` | Guardar el JWT cifrado en el dispositivo |
| `uuid` | UUID v4 generados en el dispositivo (ids de registros offline) |

## Pendiente (siguientes pasos)

- Paso 4: pantallas de negocio, disparo automático del sync (al abrir, al recuperar red, tras escribir), **sesión expirada (401)** sin perder datos locales y UX de errores de sync (transacciones huérfanas, outbox bloqueada).
- **Web con base local:** `web/sqlite3.wasm` (sqlite3 3.7.1, de [sqlite3.dart](https://github.com/simolus3/sqlite3.dart/releases)) y `web/drift_worker.js` (drift 2.35.2, de [drift](https://github.com/simolus3/drift/releases)) deben coincidir con las versiones de `pubspec.lock`. Si se actualiza drift/sqlite3, hay que volver a descargarlos.
- iOS: se agrega la plataforma cuando haya Mac/CI para compilarla.
- Pruebas de interfaz con la base real en dispositivo (hoy se prueban con SQLite en memoria).
