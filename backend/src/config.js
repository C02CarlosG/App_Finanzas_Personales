require('dotenv').config();

const config = {
  port: Number(process.env.PORT) || 3000,
  databaseUrl: process.env.DATABASE_URL,
  jwtSecret: process.env.JWT_SECRET,
  jwtExpiresIn: process.env.JWT_EXPIRES_IN || '7d',
  bcryptRounds: Number(process.env.BCRYPT_ROUNDS) || 10,
  // El pull no entrega cambios más recientes que este margen: cubre transacciones en vuelo
  // cuyo updated_at (inicio de transacción) es anterior al de otras ya confirmadas.
  syncSafetyLagMs: Number.isFinite(Number(process.env.SYNC_SAFETY_LAG_MS)) && process.env.SYNC_SAFETY_LAG_MS !== undefined
    ? Number(process.env.SYNC_SAFETY_LAG_MS) : 5000,
};

module.exports = config;
