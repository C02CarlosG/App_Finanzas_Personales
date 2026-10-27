const { AppError } = require('../utils/errors');
const config = require('../config');

// Limita intentos FALLIDOS por clave dentro de una ventana fija. En memoria: vale para un solo
// proceso; con varias instancias del API hay que moverlo a Redis o a la BD (ver docs/sync.md §8).
const MAX_KEYS = 10_000;

function createAttemptLimiter({ max, windowMs, now = Date.now }) {
  const hits = new Map(); // clave -> { count, resetAt }

  const live = (key) => {
    const hit = hits.get(key);
    if (hit && hit.resetAt <= now()) {
      hits.delete(key);
      return undefined;
    }
    return hit;
  };

  return {
    // Lanza 429 si la clave ya agotó sus intentos. Se llama ANTES de verificar la contraseña.
    check(key) {
      const hit = live(key);
      if (hit && hit.count >= max) {
        const retryAfter = Math.max(1, Math.ceil((hit.resetAt - now()) / 1000));
        throw new AppError(429, `Demasiados intentos. Vuelve a intentar en ${Math.ceil(retryAfter / 60)} min`,
          'too_many_attempts', { retryAfter });
      }
    },
    fail(key) {
      const hit = live(key);
      if (hit) {
        hit.count += 1;
        return;
      }
      if (hits.size >= MAX_KEYS) {
        for (const [k, v] of hits) if (v.resetAt <= now()) hits.delete(k);
        // Si aun así está lleno, se sacrifica la clave más antigua: la memoria nunca crece sin límite.
        if (hits.size >= MAX_KEYS) hits.delete(hits.keys().next().value);
      }
      hits.set(key, { count: 1, resetAt: now() + windowMs });
    },
    clear(key) {
      hits.delete(key);
    },
    reset() {
      hits.clear();
    },
  };
}

const windowMs = config.attemptWindowMs;
// Por correo + IP: frena la fuerza bruta sin que un tercero pueda bloquear a la víctima desde otra IP.
const loginByEmail = createAttemptLimiter({ max: config.loginMaxAttempts, windowMs });
// Por IP: frena probar muchos correos desde un mismo lugar.
const loginByIp = createAttemptLimiter({ max: config.loginMaxAttempts * 10, windowMs });
// Confirmaciones de contraseña de una sesión ya iniciada (cambiar clave/correo, borrar cuenta).
const passwordByUser = createAttemptLimiter({ max: config.loginMaxAttempts, windowMs });

const resetAll = () => [loginByEmail, loginByIp, passwordByUser].forEach((l) => l.reset());

module.exports = { createAttemptLimiter, loginByEmail, loginByIp, passwordByUser, resetAll };
