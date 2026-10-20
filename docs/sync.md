# Protocolo de sincronización offline

Estado: **implementado en el backend** (Paso 2). El cliente móvil lo consumirá desde el Paso 3/4.
Código: `backend/src/routes/sync.js`, `backend/src/sync/*`, migración `002_sync.sql`. Pruebas: `backend/test/sync.test.js`.

## 1. Principios

1. **El dispositivo manda en lo local.** La app lee y escribe siempre en SQLite; la red nunca bloquea una operación.
2. **Pull/push, sin tiempo real.** Dos endpoints: `POST /sync/push` (subir cambios) y `GET /sync/pull` (bajar cambios). No hay websockets.
3. **Conflictos: last-write-wins por registro** (decisión del 2026-10-20). Gana la edición con `client_updated_at` más reciente; no se mezclan campos entre versiones.
4. **Un borrado (tombstone) gana a cualquier edición**, sin importar su fecha.
5. **Idempotente.** Reenviar el mismo lote no duplica ni cambia nada; sirve para reintentos tras una red caída.
6. **Los saldos no se sincronizan.** Se recalculan en cada lado como `saldo inicial + ingresos − gastos` sobre transacciones no borradas.
7. **Todo aislado por usuario** (el token JWT decide; el cliente nunca envía `user_id`).

## 2. Qué se sincroniza

| Tabla | Dirección | Notas |
|---|---|---|
| `banks` | solo pull | Catálogo global sembrado. El cliente no lo modifica. |
| `categories` | push + pull | `is_system` solo lectura (p. ej. "Préstamo cobrado"). |
| `accounts` | push + pull | `type`/`bank_id` inmutables tras crear. |
| `transactions` | push + pull | |

Fase 2 y 3 (`loans`, `loan_movements`, `subscriptions`, `credit_cards`, `credit_card_payments`, `budgets`) se agregan registrándolas en `backend/src/sync/entities.js` (esquema Zod, columnas, orden de dependencia, regla de borrado). El esquema SQL ya existe; falta añadirles `client_updated_at` en su migración.

## 3. Tiempos: tres relojes distintos

| Campo | Quién lo fija | Para qué |
|---|---|---|
| `client_updated_at` | El dispositivo al editar (servidor lo acota) | **Árbitro del conflicto**: LWW compara este campo. |
| `updated_at` | El servidor al escribir | **Ordena el pull**: el cursor avanza por `(updated_at, id)`. |
| `deleted_at` | El servidor al borrar | Tombstone (soft delete). |

- Formato: ISO 8601 UTC. En las respuestas de sync los timestamps llevan **microsegundos** (`2026-10-20T15:04:05.123456Z`); si se truncaran a milisegundos el cursor repetiría la última fila indefinidamente. El cliente debe tratarlos como strings opacos y no recalcularlos.
- **Reloj del dispositivo adelantado:** si `client_updated_at` supera la hora del servidor por más de 5 minutos, el servidor lo reemplaza por su hora actual. Un reloj mal puesto hacia el futuro no puede ganar para siempre. Un reloj atrasado solo hace que las ediciones pierdan frente a otras más nuevas (comportamiento esperado de LWW).
- Ediciones por los endpoints REST (`PATCH /transactions/:id`, etc.) sellan `client_updated_at = now()` mediante trigger, por lo que compiten de forma coherente con los cambios de sync.

## 4. `POST /sync/push`

Sube los cambios locales pendientes (outbox). Requiere `Authorization: Bearer <jwt>`.

```jsonc
{
  "changes": [
    {
      "table": "transactions",              // categories | accounts | transactions
      "id": "7d0f5a0e-3f43-4a52-9a1c-0c1b8f6d2e11",   // UUID generado en el dispositivo
      "client_updated_at": "2026-10-20T15:04:05.123Z",
      "deleted": false,                     // true = borrar (no lleva data)
      "data": {                             // registro COMPLETO (no parcial)
        "type": "expense", "amount": "250.50",
        "account_id": "…", "category_id": "…",
        "occurred_on": "2026-10-19",
        "description": "Súper", "counterparty": null
      }
    }
  ]
}
```

Campos de `data` por tabla (el esquema es estricto: campos desconocidos → `invalid`):

- `categories`: `kind`, `name`, `icon?`, `color?` (`#RRGGBB`)
- `accounts`: `type` (`banco`/`efectivo`), `bank_id?`, `name`, `card_type?`, `initial_balance`
- `transactions`: `type`, `amount`, `account_id`, `category_id`, `occurred_on` (`YYYY-MM-DD`), `description?`, `counterparty?`

Dinero: string decimal (`"250.50"`) o número, máximo 2 decimales. **Nunca float** en el cliente: guárdalo como entero de centavos o `Decimal` y envíalo como string.

Límites: máx. **200 cambios** por lote; un mismo `(table, id)` solo una vez por lote (envía su estado final); si se excede, `400`.

### Respuesta

```jsonc
{
  "results": [   // mismo orden y longitud que changes
    { "table": "transactions", "id": "…", "status": "applied", "record": { /* versión del servidor */ } }
  ],
  "server_time": "2026-10-20T15:04:06.001Z"
}
```

| `status` | Significado | Qué hace el cliente |
|---|---|---|
| `applied` | El cambio se aplicó (o el borrado ya estaba aplicado). `record` = versión del servidor (`null` si borró algo que el servidor no conocía). | Guardar `record`; quitar de la outbox. |
| `stale` | El servidor tiene una versión igual o más nueva (perdió LWW o es un reintento). | **Adoptar `record`**; quitar de la outbox. |
| `deleted` | El registro ya está borrado en el servidor (tombstone gana). | Marcar borrado localmente con `record`; quitar de la outbox. |
| `rejected` | Cambio válido pero choca con una regla de estado (`code`). | Ver tabla de códigos. |
| `invalid` | Datos o referencias inválidos (`code`, `message`). No se reintenta tal cual. | Sacar de la outbox y avisar/arreglar (ver abajo). |

### Códigos de `rejected` / `invalid`

| `code` | `status` | Causa | Acción del cliente |
|---|---|---|---|
| `in_use` | rejected | Borrar cuenta/categoría que aún tiene transacciones activas (p. ej. creadas desde otro dispositivo). Trae `record` vivo. | Adoptar `record` (se "resucita" localmente) y avisar al usuario. |
| `system_category` | rejected | Renombrar/borrar una categoría del sistema. Trae `record`. | Adoptar `record`. |
| `duplicate_name` | rejected | Ya existe una categoría activa con ese nombre y tipo. Trae `conflicting_id`. | **Fusionar**: reasignar localmente las transacciones de la categoría local a `conflicting_id` (cada una es una edición nueva en la outbox), borrar físicamente la categoría local (nunca llegó al servidor) y sacarla de la outbox. |
| `conflict` | rejected | Escritura concurrente del mismo id. | Reintentar en el siguiente ciclo (devolverá `stale`). |
| `validation_error` | invalid | Esquema/regla (`message` lista campos). | Bug del cliente o dato corrupto; registrar. |
| `invalid_reference` | invalid | Cuenta/categoría inexistente, ajena o **borrada**. | Si el padre fue borrado en otro dispositivo: la transacción queda **huérfana**; la app debe pedir al usuario reasignar a otra cuenta/categoría o descartarla. |
| `category_kind_mismatch` | invalid | Categoría de ingreso en un gasto o viceversa. | Bug del cliente. |
| `immutable_field` | invalid | Cambió `type`/`bank_id` de cuenta o `kind` de categoría. | Bug del cliente. |
| `invalid_id` | invalid | El `id` ya pertenece a otro usuario. | Regenerar UUID. |

### Orden de aplicación en el servidor

El lote se aplica en **una transacción** con un *savepoint* por cambio (un cambio inválido no arrastra a los demás):

1. Altas y ediciones, **padres primero**: `categories` → `accounts` → `transactions`.
2. Borrados, **hijos primero**: `transactions` → `accounts` → `categories`.

Así un lote "crear cuenta + sus transacciones" o "borrar cuenta + sus transacciones" funciona sin importar el orden en que el cliente lo arme.

### Reglas de decisión por cambio (en orden)

1. `id` ya existe y es de otro usuario → `invalid/invalid_id` (en borrado: `applied` sin hacer nada, sin revelar existencia).
2. **Borrado**: no existe → `applied` (`record: null`); ya borrado → `applied`; regla de uso (`in_use`, `system_category`) → `rejected`; si no, `deleted_at = now()` → `applied`.
3. **Alta/edición**: `data` inválido → `invalid`; el registro tiene tombstone → `deleted`.
4. Edición: campos inmutables cambiados → `invalid`; `client_updated_at` (acotado) **no es estrictamente mayor** que el guardado → `stale` (el empate lo gana quien llegó primero; el otro adopta el registro); reglas de estado (`system_category`) → `rejected`.
5. Referencias (cuenta/categoría propias, vivas y del tipo correcto) → si fallan, `invalid`.
6. Se escribe con `client_updated_at` del cambio; `applied` con el registro resultante.

## 5. `GET /sync/pull`

Baja lo que cambió en el servidor desde el último cursor.

```
GET /sync/pull?cursor=<next_cursor anterior>&limit=500
```

- Sin `cursor` = sincronización inicial (todo, incluidos tombstones).
- `limit` por tabla (1–1000, default 500).

```jsonc
{
  "changes": {
    "banks":        [ { "id": "…", "name": "BBVA México", "logo_key": "bbva", "updated_at": "…", "deleted_at": null } ],
    "categories":   [ { "id": "…", "kind": "expense", "name": "Vivienda", "icon": null, "color": null, "is_system": false,
                        "updated_at": "…", "client_updated_at": "…", "deleted_at": null } ],
    "accounts":     [ /* … */ ],
    "transactions": [ /* … */ ]
  },
  "next_cursor": "eyJ…",      // opaco: guardarlo tal cual
  "has_more": true,           // true = hay más páginas: volver a llamar con next_cursor
  "server_time": "…"
}
```

- Las tablas llegan en orden de dependencia (`banks`, `categories`, `accounts`, `transactions`); filas dentro de cada tabla ordenadas por `(updated_at, id)`.
- Un registro borrado llega con `deleted_at` no nulo (tombstone) y el cliente lo marca borrado.
- El cursor es **por tabla** (cada una avanza con su propia clave `(updated_at µs, id)`), dentro de un cursor opaco único. Una página se lee en una sola foto consistente (`REPEATABLE READ`).
- Un cursor mal formado → `400 invalid_cursor`.

### Margen de seguridad (`SYNC_SAFETY_LAG_MS`, default 5000)

`updated_at` lo fija PostgreSQL con `now()` = *inicio* de la transacción, no el momento del commit. Una transacción lenta puede confirmar después de otra más nueva; un cliente que ya avanzó su cursor se la saltaría para siempre. Para evitarlo, el pull **no entrega filas con `updated_at` más recientes que `now() − margen`**. Consecuencias:

- Los cambios de otro dispositivo se ven con hasta ~5 s de retraso (aceptable para sync de segundo plano).
- Los cambios propios no dependen del pull: el push ya devuelve el `record` resultante.
- El margen debe ser mayor que la duración máxima de una escritura. Por eso el lote máximo es 200 cambios.
- Pruebas lo ponen en `0` para ser deterministas.

## 6. Algoritmo del cliente

**Esquema local sugerido (SQLite)**

- Mismas tablas que el servidor (`categories`, `accounts`, `transactions`, `banks`) más `updated_at` (servidor, `NULL` si nunca sincronizó), `client_updated_at` y `deleted_at`. UUIDs generados en el dispositivo. **Sin claves foráneas forzadas** durante la sincronización (o aplicar cada pull completo en una sola transacción local con FKs diferidas), porque las tablas se paginan por separado.
- `sync_outbox(table, id, client_updated_at, deleted)`, clave `(table, id)`: un solo renglón por registro con su estado más reciente (coalescencia).
- `sync_state(cursor)`.
- Saldos: `SUM` local; nunca almacenados.

**Escritura local** (crear/editar/borrar): aplicar en SQLite, poner `client_updated_at = ahora (UTC)`, escribir/reemplazar el renglón en la outbox. Un borrado es `deleted_at` local + renglón `deleted: true`. Si un registro se crea y se borra antes de sincronizar, se puede eliminar físicamente y quitar de la outbox.

**Ciclo de sincronización** (al recuperar conexión, al abrir la app, tras escribir con *debounce* y periódicamente), siempre **push y luego pull**:

1. **Push**: tomar la outbox en lotes de ≤ 200 y enviarlos. Por cada resultado, guardar `record` sobre la fila local según la tabla de `status` y quitar el renglón de la outbox, **salvo** que el usuario haya vuelto a editar ese registro después de armar el lote (su `client_updated_at` en la outbox es posterior al enviado): en ese caso se conserva para el siguiente ciclo.
2. **Pull**: repetir con el `next_cursor` hasta `has_more = false`, aplicando todo en **una transacción local**. Para cada fila recibida:
   - Si trae `deleted_at` → borrar/tombstonear localmente y descartar cualquier edición pendiente de ese id (el servidor la rechazaría con `deleted`).
   - Si hay una edición local pendiente en la outbox con `client_updated_at` **mayor** que el de la fila recibida → conservar lo local (ganará al subirse).
   - En otro caso → sobrescribir la fila local con la del servidor y quitar su renglón de la outbox.
3. Guardar `next_cursor` **después** de confirmar la transacción local. Si algo falla antes, se repite el pull desde el cursor anterior: es seguro porque aplicar una fila es idempotente.

Ambos lados aplican la misma regla de LWW, por lo que los dispositivos convergen a la misma versión sin importar el orden en que sincronicen (hay una prueba que lo verifica).

## 7. Garantías y límites conocidos

- **LWW por registro pierde cambios concurrentes de campos distintos** (si A cambia el monto y B la descripción, gana uno completo). Es la decisión aceptada; si duele en la práctica, el siguiente paso sería resolución por campo.
- **Tombstones nunca se purgan todavía.** A futuro (Fase 4) se podrá purgar después de N días y responder `410 resync_required` a cursores más viejos para forzar una sincronización inicial.
- **Empate exacto** de `client_updated_at` entre dispositivos: gana quien llegó primero al servidor; el otro adopta el registro. El resultado es determinista y convergente.
- **Borrado vs. uso desde otro dispositivo:** el servidor no borra cuentas/categorías con transacciones activas (`in_use`), igual que `DELETE` por REST; el dispositivo que borró lo "resucita" al adoptar el registro.
- **Transacciones huérfanas:** si otro dispositivo borró (legítimamente) una cuenta o categoría mientras este creaba una transacción offline sobre ella, el push devuelve `invalid_reference`. La UX para reasignar o descartar se define en el Paso 4.
- **Sin cifrado ni firma de lotes** más allá de TLS + JWT.
- **Un solo `user_id` por token:** la compartición de cuentas entre usuarios queda fuera de alcance.
- El campo `plan` de usuario (`free`/`premium`) ya existe para limitar sync/dispositivos en el modelo de suscripción; hoy no se aplica ninguna restricción.
