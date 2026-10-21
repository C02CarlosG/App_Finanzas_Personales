# PROGRESS

_Última actualización: 2026-10-20 (Paso 2)_

## Fase y paso actuales
**Fase 1 – Paso 2 (Diseño de sync) terminado, en revisión (PR `paso-2-sync`).** Siguiente: Paso 3 (scaffold Flutter), previa aprobación del PR.

## Qué está hecho
- 2026-10-20 – Monorepo creado: `backend/`, `mobile/`, `docs/`, CI, `.gitignore`, `README.md`.
- 2026-10-20 – **Backend de Fase 1 reconstruido desde cero** (el `finanzas-backend.zip` original no estaba disponible): esquema completo para todas las fases, migración, auth, bancos, cuentas, categorías, transacciones y dashboard. 30 pruebas de integración pasando.

- 2026-10-20 – Commit inicial en `main` (monorepo + backend reconstruido, 30 pruebas).
- 2026-10-20 – **Revisión adversarial del Paso 2** (4 revisores + verificadores independientes): 13 hallazgos confirmados y corregidos en código y documento (falso `duplicate_name` al borrar+recrear, carrera de FK, deadlock, margen de seguridad sin garantía, cursor con fecha imposible, UUID en mayúsculas, etc.), 3 refutados, 9 de `client-doc` sin verificador (límite de sesión) evaluados a mano: 8 eran defectos reales del algoritmo del cliente y se corrigieron en `docs/sync.md`.
- 2026-10-20 – **Paso 2**: protocolo de sync documentado en `docs/sync.md` e implementado: `POST /sync/push`, `GET /sync/pull`, migración `002_sync.sql`. 63 pruebas pasando (tras la revisión adversarial).

## Qué sigue (en orden)
1. Revisar y aprobar el PR del Paso 2.
2. Paso 3 – Scaffold Flutter (estado, SQLite local, cliente HTTP, navegación inferior, outbox/sync según `docs/sync.md`).
4. Paso 4 – Fase 1 en móvil.
5. Paso 5 – Fase 2 (préstamos, suscripciones, tarjetas): endpoints y móvil. El esquema ya existe.
6. Paso 6 – Fase 3 (reportes, presupuestos, alertas).
7. Paso 7 – Fase 4 (exportación, perfil, sync robusto, suscripción de pago).

## Decisiones tomadas y por qué
- **Esquema**: `accounts` con `type` (`banco`/`efectivo`); `transactions` con `type` (`income`/`expense`); saldos por vista SQL `account_balances`; UUID + `updated_at` + `deleted_at` en todas las tablas; categorías por usuario sembradas al registrarse; catálogo de 16 bancos mexicanos sembrado.
- **Dinero**: `NUMERIC(14,2)`; la API recibe string o número con máximo 2 decimales y devuelve strings decimales. Sin `float`.
- **Llaves del cliente**: `POST` acepta `id` UUID opcional para que el móvil offline cree registros sin esperar al servidor.
- **Dependencias** (todas necesarias): `express`, `pg`, `zod`, `jsonwebtoken`, `dotenv`, `bcryptjs` (bcrypt en JS puro, sin compilación nativa), `supertest` (dev).
- **Borrado**: soft delete. Una cuenta o categoría con transacciones activas no se puede eliminar (409). Las categorías del sistema ("Préstamo cobrado") no se renombran ni borran.
- **Sync (Paso 2)**: pull/push sin tiempo real; last-write-wins **por registro** comparando `client_updated_at` (el servidor lo acota a `now()` si el dispositivo lo trae >5 min en el futuro); tombstone gana a cualquier edición; el cursor del pull es por tabla `(updated_at µs, id)` con margen de seguridad de 5 s (`SYNC_SAFETY_LAG_MS`) porque `updated_at` es el inicio de la transacción; lote máx. 200 cambios; los saldos nunca se sincronizan. Detalle y razones en `docs/sync.md`.
- **Borrado por sync** respeta las mismas reglas que REST (cuenta/categoría con transacciones → `in_use`); el dispositivo "resucita" el registro al adoptar la versión del servidor.
- **Sync, endurecimiento**: bloqueo previo de filas propias en orden fijo + reintento por deadlock; `FOR SHARE` en padres; segundo pase para `duplicate_name`/`invalid_reference`; presupuesto de tiempo por lote = 80 % del margen (si no, `503 batch_too_slow` y el cliente divide el lote). El cliente debe: un solo ciclo de sync a la vez, base local por usuario, lotes en orden padre→hijo, página de pull = una transacción local con su cursor, corregir su reloj con `server_time`.
- **Pruebas**: BD aparte `*_test` obligatoria; el helper se niega a correr contra otra.

## Problemas abiertos / dudas para ti
1. **Moneda**: el spec dice "cambiar moneda" y tú pides MXN. ¿Fija en MXN por ahora? (hoy `users.currency` existe con default `MXN` y el dashboard devuelve `MXN` fijo).
2. **Préstamos en la navegación**: el spec no los ubica en la barra inferior (Inicio, Bancos, Categorías, Reportes, Perfil). ¿Dentro de Bancos, de Inicio o en otra parte?
3. El backend original no se recuperó; esta versión es una reconstrucción con las decisiones que me diste. Si aparece el original, hay que compararlos.
4. Sin límite de intentos de login ni recuperación de contraseña aún (a considerar en Fase 4).
5. **Transacción huérfana** (solo si el padre ya llegó como tombstone; mientras esté pendiente, el cliente reintenta) (otro dispositivo borró la cuenta/categoría mientras este creaba una transacción offline): el servidor responde `invalid_reference`; la UX para reasignar o descartar se define en el Paso 4.
6. **Tombstones** nunca se purgan; definir retención y `410 resync_required` en Fase 4.
7. LWW por registro pierde ediciones concurrentes de campos distintos (aceptado); si molesta, evaluar resolución por campo.

## Comandos
```bash
# Backend
cd backend && cp .env.example .env && npm install
npm run migrate && npm start

# Pruebas (BD con nombre *_test)
export TEST_DATABASE_URL=postgres://usuario:password@localhost:5432/finanzas_test
cd backend && npm test

# App móvil: pendiente (Paso 3)
```

## Notas del entorno cloud
- `gh` no autenticado (token inválido); se usan las herramientas GitHub de la sesión para commits/PR.
- Repo: `C02CarlosG/App_Finanzas_Personales` (vacío antes del commit inicial).
