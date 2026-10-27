// Borra TODOS los datos de un usuario (derecho de cancelación): se elimina de verdad, no se marca
// deleted_at, porque un tombstone seguiría guardando sus datos. Orden: hijos antes que padres (FKs).
// Debe llamarse dentro de una transacción. El catálogo de bancos es global y no se toca.
const TABLES_CHILDREN_FIRST = [
  'sync_purge_watermarks', 'credit_card_payments', 'loan_movements', 'budgets', 'subscriptions', 'transactions',
  'credit_cards', 'loans', 'accounts', 'categories',
];

async function deleteUserData(client, userId) {
  // Bloquea la fila del usuario: espera a los pushes en vuelo (que toman KEY SHARE al insertar).
  await client.query('SELECT 1 FROM users WHERE id = $1 FOR UPDATE', [userId]);
  for (const table of TABLES_CHILDREN_FIRST) {
    await client.query(`DELETE FROM ${table} WHERE user_id = $1`, [userId]);
  }
  await client.query('DELETE FROM users WHERE id = $1', [userId]);
}

module.exports = { deleteUserData, TABLES_CHILDREN_FIRST };
