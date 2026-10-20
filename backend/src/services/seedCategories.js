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

async function seedCategories(client, userId) {
  const rows = [
    ...INCOME.map((name) => ['income', name, false]),
    ['income', LOAN_COLLECTED, true],
    ...EXPENSE.map((name) => ['expense', name, false]),
  ];
  for (const [kind, name, isSystem] of rows) {
    await client.query(
      'INSERT INTO categories (user_id, kind, name, is_system) VALUES ($1, $2, $3, $4)',
      [userId, kind, name, isSystem],
    );
  }
}

module.exports = { seedCategories, LOAN_COLLECTED };
