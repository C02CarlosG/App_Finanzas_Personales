# PROGRESS

_Última actualización: 2026-10-20_

## Fase y paso actuales
**Fase 1 – Preparación del repositorio y Paso 1 (Diagnóstico).** Pendiente de tu visto bueno para el primer commit.

## Qué está hecho
- 2026-10-20 – Monorepo creado: `backend/`, `mobile/`, `docs/`, CI, `.gitignore`, `README.md`.
- 2026-10-20 – **Backend de Fase 1 reconstruido desde cero** (el `finanzas-backend.zip` original no estaba disponible): esquema completo para todas las fases, migración, auth, bancos, cuentas, categorías, transacciones y dashboard. 30 pruebas de integración pasando.

## Qué sigue (en orden)
1. Primer commit en `main` tras tu confirmación de la lista de archivos.
2. Paso 2 – Diseño de sync (`docs/sync.md`).
3. Paso 3 – Scaffold Flutter.
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
- **Pruebas**: BD aparte `*_test` obligatoria; el helper se niega a correr contra otra.

## Problemas abiertos / dudas para ti
1. **Moneda**: el spec dice "cambiar moneda" y tú pides MXN. ¿Fija en MXN por ahora? (hoy `users.currency` existe con default `MXN` y el dashboard devuelve `MXN` fijo).
2. **Préstamos en la navegación**: el spec no los ubica en la barra inferior (Inicio, Bancos, Categorías, Reportes, Perfil). ¿Dentro de Bancos, de Inicio o en otra parte?
3. El backend original no se recuperó; esta versión es una reconstrucción con las decisiones que me diste. Si aparece el original, hay que compararlos.
4. Sin límite de intentos de login ni recuperación de contraseña aún (a considerar en Fase 4).

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
