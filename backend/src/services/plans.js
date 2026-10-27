// Único lugar donde se decide qué incluye cada plan (Paso 7: base técnica para la suscripción).
// Hoy free y premium incluyen lo mismo: no hay límites ni cobro. Cuando exista el plan de pago,
// la diferencia se declara aquí y las rutas la consultan con entitlementsFor(user.plan).
const FEATURES = {
  free: { sync: true, export: true },
  premium: { sync: true, export: true },
};

function entitlementsFor(plan) {
  // Un plan desconocido (dato corrupto) nunca debe dar más que el gratuito.
  const key = Object.hasOwn(FEATURES, plan) ? plan : 'free';
  return { plan: key, features: { ...FEATURES[key] } };
}

module.exports = { entitlementsFor };
