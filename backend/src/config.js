require('dotenv').config();

// Una variable vacía o no numérica cae al valor por defecto (Number('') sería 0 y apagaría el margen).
const envNumber = (raw, fallback) => (raw !== undefined && raw.trim() !== '' && Number.isFinite(Number(raw)) ? Number(raw) : fallback);

const config = {
  port: Number(process.env.PORT) || 3000,
  databaseUrl: process.env.DATABASE_URL,
  jwtSecret: process.env.JWT_SECRET,
  jwtExpiresIn: process.env.JWT_EXPIRES_IN || '7d',
  bcryptRounds: Number(process.env.BCRYPT_ROUNDS) || 10,
  // El pull no entrega cambios más recientes que este margen: cubre transacciones en vuelo
  // cuyo updated_at (inicio de transacción) es anterior al de otras ya confirmadas.
  syncSafetyLagMs: envNumber(process.env.SYNC_SAFETY_LAG_MS, 5000),
  // Días que se conserva un registro borrado (tombstone) antes de eliminarlo de verdad. Un dispositivo
  // que pase más tiempo sin sincronizar recibe 410 resync_required y vuelve a descargar todo. 0 = nunca purgar.
  tombstoneRetentionDays: envNumber(process.env.TOMBSTONE_RETENTION_DAYS, 180),
  // Intentos fallidos de contraseña permitidos por ventana (login, cambio de clave/correo, borrar cuenta).
  loginMaxAttempts: envNumber(process.env.LOGIN_MAX_ATTEMPTS, 5),
  attemptWindowMs: envNumber(process.env.LOGIN_WINDOW_MS, 15 * 60 * 1000),
  // Detrás de un proxy/balanceador req.ip sería la IP del proxy y el límite por IP bloquearía a todos:
  // define TRUST_PROXY (número de saltos, p. ej. 1) para leer X-Forwarded-For.
  trustProxy: process.env.TRUST_PROXY ? envNumber(process.env.TRUST_PROXY, false) : false,
};

module.exports = config;
