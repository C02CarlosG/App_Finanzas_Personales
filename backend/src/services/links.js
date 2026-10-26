// Vínculos de integridad de la Fase 2, compartidos por sync y REST para que no diverjan.
// `client` es un cliente de pg o el pool (ambos tienen query()).

// ¿Esta transacción respalda un abono de préstamo o un pago de tarjeta vivos?
async function transactionIsBacked(client, userId, transactionId) {
  const { rowCount } = await client.query(
    `SELECT 1 FROM loan_movements WHERE transaction_id = $1 AND user_id = $2 AND deleted_at IS NULL
     UNION ALL
     SELECT 1 FROM credit_card_payments WHERE transaction_id = $1 AND user_id = $2 AND deleted_at IS NULL LIMIT 1`,
    [transactionId, userId]);
  return rowCount > 0;
}

// ¿Alguna suscripción o pago de tarjeta vivos usa esta cuenta?
async function accountHasLinks(client, userId, accountId) {
  const { rowCount } = await client.query(
    `SELECT 1 FROM subscriptions WHERE account_id = $1 AND user_id = $2 AND deleted_at IS NULL
     UNION ALL
     SELECT 1 FROM credit_card_payments WHERE account_id = $1 AND user_id = $2 AND deleted_at IS NULL LIMIT 1`,
    [accountId, userId]);
  return rowCount > 0;
}

// Los campos que mueven saldos de una transacción ligada no cambian: el ingreso/gasto se rehace desde su origen.
const LOCKED_TX_FIELDS = ['type', 'amount', 'account_id'];

function changesLockedFields(existing, next) {
  return LOCKED_TX_FIELDS.some((f) => (f === 'amount' ? Number(existing[f]) !== Number(next[f]) : existing[f] !== next[f]));
}

module.exports = { transactionIsBacked, accountHasLinks, changesLockedFields };
