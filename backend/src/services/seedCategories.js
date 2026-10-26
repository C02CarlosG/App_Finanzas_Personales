// Categorías iniciales (spec 4.3 y 4.4). El usuario las puede editar; las
// marcadas is_system no se renombran ni se borran porque otros flujos dependen de ellas.
const INCOME = [
  'Salario / quincena', 'Freelance', 'Negocio propio', 'Inversiones',
  'Bonificaciones', 'Regalos', 'Reembolsos',
];
const EXPENSE = [
  'Vivienda', 'Transporte', 'Alimentación', 'Servicios',
  'Entretenimiento', 'Educación', 'Salud',
];
const LOAN_COLLECTED = 'Préstamo cobrado';
// Gastos que genera la app al abonar a lo que debes o pagar una tarjeta (Fase 2).
const LOAN_PAYMENT = 'Pago de préstamo';
const CARD_PAYMENT = 'Pago de tarjeta';

async function seedCategories(client, userId) {
  const rows = [
    ...INCOME.map((name) => ['income', name, false]),
    ['income', LOAN_COLLECTED, true],
    ...EXPENSE.map((name) => ['expense', name, false]),
    ['expense', LOAN_PAYMENT, true],
    ['expense', CARD_PAYMENT, true],
  ];
  for (const [kind, name, isSystem] of rows) {
    await client.query(
      'INSERT INTO categories (user_id, kind, name, is_system) VALUES ($1, $2, $3, $4)',
      [userId, kind, name, isSystem],
    );
  }
}

module.exports = { seedCategories, LOAN_COLLECTED, LOAN_PAYMENT, CARD_PAYMENT };
