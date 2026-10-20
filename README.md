# Finanzas Personales

App móvil de seguimiento de ingresos y gastos para usuarios en México: cuentas bancarias y efectivo, categorías, préstamos, suscripciones, tarjetas de crédito, reportes y presupuestos. Diseño **offline-first** con sincronización a un servidor, y base lista para un modelo de suscripción de pago.

La especificación funcional está en [`docs/app-finanzas-personales-spec.md`](docs/app-finanzas-personales-spec.md). El estado y los siguientes pasos, en [`PROGRESS.md`](PROGRESS.md).

## Stack

| Capa | Tecnología |
|---|---|
| Móvil | Flutter (Android primero, iOS después) |
| API | Node.js + Express |
| BD servidor | PostgreSQL |
| BD local | SQLite en el dispositivo (offline-first) |
| Validación / Auth | Zod / JWT |
| Pruebas | `node:test` + `supertest` |
| Web (futuro) | React + TypeScript |

## Estructura

```
backend/   API Express + esquema PostgreSQL + pruebas
mobile/    App Flutter (pendiente)
docs/      Especificación y documentos de diseño
PROGRESS.md  Estado, decisiones y siguientes pasos
```

## Correr el backend

Requisitos: Node 20+ y PostgreSQL 14+.

```bash
cd backend
cp .env.example .env        # completa DATABASE_URL y JWT_SECRET
npm install
npm run migrate             # crea el esquema y siembra el catálogo de bancos
npm start                   # API en http://localhost:3000
```

## Pruebas

Las pruebas usan una BD aparte cuyo nombre **debe terminar en `_test`** (se vacía entre pruebas):

```bash
createdb finanzas_test
export TEST_DATABASE_URL=postgres://usuario:password@localhost:5432/finanzas_test
cd backend && npm test
```

CI (GitHub Actions) corre las mismas pruebas con un PostgreSQL en contenedor en cada push y pull request.
