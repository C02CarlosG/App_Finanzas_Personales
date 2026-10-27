# Despliegue gratuito de la API (Neon + Render)

Para probar la app con conocidos sin pagar hosting: **base PostgreSQL en Neon** y **API de Node en Render**. La API solo
necesita una `DATABASE_URL` estándar, así que cambiar de proveedor después (o pasar a un plan de pago) es cambiar esa variable.

> Los límites de los planes gratuitos cambian con frecuencia: revisa la página de precios de cada servicio antes de depender de ellos.
> Los nombres de botones pueden variar.

## 1. Base de datos (Neon)

1. Crea una cuenta en neon.tech y un proyecto (`finanzas`). Elige una región cercana a la de Render (la misma, si existe).
2. En el panel del proyecto, botón **Connect**: **desactiva «Connection pooling»** y copia la cadena de conexión **directa** (el host
   no lleva `-pooler`). Con el pooler (PgBouncer en modo transacción) el candado de sesión de la purga (`pg_try_advisory_lock`) no es fiable.
3. En esa cadena, cambia `sslmode=require` por `sslmode=verify-full` (mismo cifrado; evita un aviso del driver `pg`):

   ```
   postgresql://USUARIO:CLAVE@ep-xxxx.REGION.aws.neon.tech/neondb?sslmode=verify-full
   ```
4. Neon suspende el cómputo tras unos minutos sin uso: la primera consulta posterior tarda un poco más. El API ya tolera que una
   conexión ociosa se caiga (`src/db/pool.js`).

## 2. API (Render)

1. render.com → conecta tu GitHub → **New → Web Service** → `C02CarlosG/App_Finanzas_Personales`, rama `main`.
2. Configuración:

   | Campo | Valor |
   |---|---|
   | Root Directory | `backend` |
   | Build Command | `npm ci` |
   | Start Command | `npm run migrate && npm start` |
   | Instance Type | Free |
   | Health Check Path | `/health` |

   El `migrate` es idempotente (`schema_migrations`): aplica solo lo pendiente cada vez que el servicio arranca.
3. Variables de entorno:

   | Variable | Valor |
   |---|---|
   | `DATABASE_URL` | la cadena directa del paso 1 |
   | `JWT_SECRET` | `node -e "console.log(require('crypto').randomBytes(48).toString('hex'))"` (no lo compartas) |
   | `TRUST_PROXY` | `1` |
   | `NODE_VERSION` | `22` |

4. Despliega. En los registros debe aparecer `Migraciones aplicadas: …` y `API escuchando en :…`. Abre
   `https://TU-SERVICIO.onrender.com/health`: debe responder `{"status":"ok"}`.

**Esa URL es la `API_BASE_URL`** del release de Android (`docs/release-android.md` §4). Va compilada en el APK: si algún día cambias el
host, hay que compilar e instalar un APK nuevo. Con un dominio propio apuntando al servicio evitas atarte al host del proveedor.

### API dormida

En el plan gratuito, Render apaga la API tras un rato sin tráfico y la primera petición la vuelve a arrancar (decenas de segundos).
El sync reintenta solo, pero el cliente espera **20 s** por petición (`mobile/lib/core/network/api_client.dart`): un primer
registro o login con la API dormida puede fallar y funcionar al reintentar.

## 3. Respaldos (aunque sea gratis)

Un plan gratuito no es garantía de conservar datos financieros. Con las herramientas de cliente de PostgreSQL (versión igual o mayor
que la del servidor), cada semana:

```bash
pg_dump "$DATABASE_URL" -Fc -f respaldo-AAAA-MM-DD.dump
```

Restaurar en una base nueva: `pg_restore -d "URL_DE_LA_NUEVA" --no-owner --no-privileges respaldo-AAAA-MM-DD.dump`.
Guarda los `.dump` fuera del proveedor (contienen datos de tus usuarios: trátalos como confidenciales).

## 4. Pasar a un plan de pago

Crea la base nueva, restaura el respaldo (paso 3), cambia `DATABASE_URL` en Render y vuelve a desplegar. Los dispositivos no
cambian nada si la URL del API se mantiene.

## 5. Si algo falla

| Síntoma | Causa y arreglo |
|---|---|
| `Faltan DATABASE_URL o JWT_SECRET` en los registros | Falta una variable de entorno en Render. |
| `no pg_hba.conf entry` / `SSL` / `self-signed` al conectar | La cadena no lleva `?sslmode=verify-full`, o se copió con el pooler. |
| `password authentication failed` | Clave mal copiada; vuelve a copiar la cadena completa de Neon. |
| La app dice «sin conexión» solo la primera vez | API dormida (ver arriba): reintenta. |
| La purga diaria no corre o se repite | Se usó la cadena con `-pooler`; usa la directa. |
