// Registro de entidades sincronizables. Para sumar una tabla (Fase 2/3) basta con
// agregarla aquí: esquema de datos, columnas, orden de dependencia y reglas de borrado.
const { z, money, nonNegativeMoney, signedMoney, uuid: uuidAny, isoDate } = require('../utils/schemas');
const { transactionIsBacked, accountHasLinks, changesLockedFields } = require('../services/links');

// Los UUID se canonicalizan a minúsculas (Postgres los devuelve así; comparar sin esto da falsos inmutables).
const uuid = uuidAny.transform((v) => v.toLowerCase());

// Timestamps con precisión de microsegundos (el driver pg los truncaría a milisegundos
// y el cursor se repetiría). Se entregan como string ISO UTC.
const ts = (col) => `to_char(t.${col} AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')`;
const syncCols = `${ts('updated_at')} AS updated_at, ${ts('client_updated_at')} AS client_updated_at, ${ts('deleted_at')} AS deleted_at`;

const nullableText = (max) => z.string().trim().max(max).nullish().transform((v) => v ?? null);
const nullable = (schema) => schema.nullish().transform((v) => v ?? null);

const accountData = z.object({
  type: z.enum(['banco', 'efectivo']),
  bank_id: nullable(uuid),
  name: z.string().trim().min(1).max(100),
  card_type: nullable(z.enum(['debito', 'credito'])),
  initial_balance: signedMoney,
}).strict().superRefine((v, ctx) => {
  if (v.type === 'banco' && !v.bank_id) ctx.addIssue({ code: 'custom', path: ['bank_id'], message: 'bank_id es requerido para cuentas de banco' });
  if (v.type === 'efectivo' && (v.bank_id || v.card_type)) ctx.addIssue({ code: 'custom', path: ['type'], message: 'Una cuenta de efectivo no lleva banco ni tipo de tarjeta' });
});

const categoryData = z.object({
  kind: z.enum(['income', 'expense']),
  name: z.string().trim().min(1).max(60),
  icon: nullableText(40),
  color: nullable(z.string().regex(/^#[0-9a-fA-F]{6}$/, 'Color hex #RRGGBB')),
}).strict();

const transactionData = z.object({
  type: z.enum(['income', 'expense']),
  amount: money,
  account_id: uuid,
  category_id: uuid,
  occurred_on: isoDate,
  description: nullableText(500),
  counterparty: nullableText(100),
}).strict();

const loanData = z.object({
  person_name: z.string().trim().min(1).max(100),
  direction: z.enum(['i_owe', 'owed_to_me']),
  principal: money, // monto original: aumentos y abonos viven en loan_movements
  due_date: nullable(isoDate),
  status: z.enum(['active', 'paid']),
  notes: nullableText(500),
}).strict();

const loanMovementData = z.object({
  loan_id: uuid,
  kind: z.enum(['payment', 'increase']),
  amount: money,
  occurred_on: isoDate,
  transaction_id: nullable(uuid), // ingreso/gasto que movió dinero (solo abonos)
}).strict();

const subscriptionData = z.object({
  name: z.string().trim().min(1).max(100),
  amount: money,
  renewal_date: isoDate,
  period: z.enum(['weekly', 'monthly', 'yearly']),
  account_id: nullable(uuid),
  active: z.boolean(),
}).strict();

const creditCardData = z.object({
  bank_id: nullable(uuid),
  name: z.string().trim().min(1).max(100),
  pending_balance: nonNegativeMoney,
  due_date: nullable(isoDate),
}).strict();

const creditCardPaymentData = z.object({
  credit_card_id: uuid,
  account_id: nullable(uuid),
  transaction_id: nullable(uuid),
  amount: money,
  paid_on: isoDate,
}).strict();

const invalidRef = (message) => ({ code: 'invalid_reference', message });

// Padre propio y vivo; FOR SHARE para que un borrado concurrente espere a que este lote termine.
async function ownLive(client, table, userId, id, cols = '1') {
  return (await client.query(
    `SELECT ${cols} FROM ${table} WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL FOR SHARE`, [id, userId])).rows[0] ?? null;
}

const ENTITIES = {
  categories: {
    table: 'categories',
    order: 1, // padres primero al insertar; al borrar se invierte. Debe ser único (ver aserción al final)
    dataCols: ['kind', 'name', 'icon', 'color'],
    immutable: ['kind'],
    schema: categoryData,
    select: `t.id, t.kind, t.name, t.icon, t.color, t.is_system, ${syncCols}`,
    async validateRefs() { return null; },
    checkUpdate(_client, _userId, existing, data) {
      if (existing.is_system && data.name !== existing.name) {
        return { code: 'system_category', message: 'Las categorías del sistema no se pueden renombrar' };
      }
      return null;
    },
    async blockDelete(client, userId, existing) {
      if (existing.is_system) return { code: 'system_category', message: 'Las categorías del sistema no se pueden eliminar' };
      const used = await client.query(
        'SELECT 1 FROM transactions WHERE category_id = $1 AND user_id = $2 AND deleted_at IS NULL LIMIT 1', [existing.id, userId]);
      return used.rowCount ? { code: 'in_use', message: 'La categoría tiene transacciones' } : null;
    },
  },

  accounts: {
    table: 'accounts',
    order: 2,
    dataCols: ['type', 'bank_id', 'name', 'card_type', 'initial_balance'],
    immutable: ['type', 'bank_id'],
    schema: accountData,
    select: `t.id, t.type, t.bank_id, t.name, t.card_type, t.initial_balance, ${syncCols}`,
    async validateRefs(client, _userId, data, existing) {
      if (!existing && data.bank_id) {
        const bank = await client.query('SELECT 1 FROM banks WHERE id = $1 AND deleted_at IS NULL FOR SHARE', [data.bank_id]);
        if (!bank.rowCount) return invalidRef('Banco no existe en el catálogo');
      }
      return null;
    },
    checkUpdate() { return null; },
    async blockDelete(client, userId, existing) {
      const used = await client.query(
        'SELECT 1 FROM transactions WHERE account_id = $1 AND user_id = $2 AND deleted_at IS NULL LIMIT 1', [existing.id, userId]);
      if (used.rowCount) return { code: 'in_use', message: 'La cuenta tiene transacciones' };
      return (await accountHasLinks(client, userId, existing.id)) ? { code: 'in_use', message: 'La cuenta tiene suscripciones o pagos de tarjeta' } : null;
    },
  },

  transactions: {
    table: 'transactions',
    order: 5,
    dataCols: ['type', 'amount', 'account_id', 'category_id', 'occurred_on', 'description', 'counterparty'],
    immutable: [],
    schema: transactionData,
    select: `t.id, t.type, t.amount, t.account_id, t.category_id, t.occurred_on, t.description, t.counterparty, ${syncCols}`,
    async validateRefs(client, userId, data) {
      const acc = await client.query('SELECT 1 FROM accounts WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL FOR SHARE', [data.account_id, userId]);
      if (!acc.rowCount) return invalidRef('Cuenta no encontrada o eliminada');
      const cat = await client.query('SELECT kind FROM categories WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL FOR SHARE', [data.category_id, userId]);
      if (!cat.rowCount) return invalidRef('Categoría no encontrada o eliminada');
      if (cat.rows[0].kind !== data.type) return { code: 'category_kind_mismatch', message: 'La categoría no corresponde al tipo de transacción' };
      return null;
    },
    // Un ingreso/gasto que respalda un abono o un pago de tarjeta no cambia de tipo, monto ni cuenta: los
    // saldos del préstamo/tarjeta y los de las cuentas dejarían de cuadrar. Se deshace desde su origen.
    async checkUpdate(client, userId, existing, data) {
      if (!changesLockedFields(existing, data)) return null;
      return (await transactionIsBacked(client, userId, existing.id))
        ? { code: 'in_use', message: 'La transacción pertenece a un abono o a un pago de tarjeta; no se puede cambiar su tipo, monto ni cuenta' }
        : null;
    },
    // ...y se borra desde su origen (el movimiento).
    async blockDelete(client, userId, existing) {
      return (await transactionIsBacked(client, userId, existing.id))
        ? { code: 'in_use', message: 'La transacción pertenece a un abono o a un pago de tarjeta' }
        : null;
    },
  },

  // ---------- Fase 2 ----------
  loans: {
    table: 'loans',
    order: 3,
    dataCols: ['person_name', 'direction', 'principal', 'due_date', 'status', 'notes'],
    immutable: ['direction'], // cambiarla invertiría el sentido de los abonos ya registrados
    schema: loanData,
    select: `t.id, t.person_name, t.direction, t.principal, t.due_date, t.status, t.notes, ${syncCols}`,
    async validateRefs() { return null; },
    checkUpdate() { return null; },
    async blockDelete(client, userId, existing) {
      const used = await client.query(
        'SELECT 1 FROM loan_movements WHERE loan_id = $1 AND user_id = $2 AND deleted_at IS NULL LIMIT 1', [existing.id, userId]);
      return used.rowCount ? { code: 'in_use', message: 'El préstamo tiene movimientos' } : null;
    },
  },

  credit_cards: {
    table: 'credit_cards',
    order: 4,
    dataCols: ['bank_id', 'name', 'pending_balance', 'due_date'],
    immutable: [],
    schema: creditCardData,
    select: `t.id, t.bank_id, t.name, t.pending_balance, t.due_date, ${syncCols}`,
    async validateRefs(client, _userId, data, existing) {
      if (data.bank_id && existing?.bank_id !== data.bank_id) {
        const bank = await client.query('SELECT 1 FROM banks WHERE id = $1 AND deleted_at IS NULL FOR SHARE', [data.bank_id]);
        if (!bank.rowCount) return invalidRef('Banco no existe en el catálogo');
      }
      return null;
    },
    checkUpdate() { return null; },
    async blockDelete(client, userId, existing) {
      const used = await client.query(
        'SELECT 1 FROM credit_card_payments WHERE credit_card_id = $1 AND user_id = $2 AND deleted_at IS NULL LIMIT 1', [existing.id, userId]);
      return used.rowCount ? { code: 'in_use', message: 'La tarjeta tiene pagos' } : null;
    },
  },

  subscriptions: {
    table: 'subscriptions',
    order: 6,
    dataCols: ['name', 'amount', 'renewal_date', 'period', 'account_id', 'active'],
    immutable: [],
    schema: subscriptionData,
    select: `t.id, t.name, t.amount, t.renewal_date, t.period, t.account_id, t.active, ${syncCols}`,
    async validateRefs(client, userId, data, existing) {
      if (data.account_id && existing?.account_id !== data.account_id) {
        if (!(await ownLive(client, 'accounts', userId, data.account_id))) return invalidRef('Cuenta no encontrada o eliminada');
      }
      return null;
    },
    checkUpdate() { return null; },
    async blockDelete() { return null; },
  },

  loan_movements: {
    table: 'loan_movements',
    order: 7,
    dataCols: ['loan_id', 'kind', 'amount', 'occurred_on', 'transaction_id'],
    immutable: ['loan_id', 'kind', 'transaction_id'], // un movimiento no se reasigna: se borra y se vuelve a crear
    schema: loanMovementData,
    select: `t.id, t.loan_id, t.kind, t.amount, t.occurred_on, t.transaction_id, ${syncCols}`,
    async validateRefs(client, userId, data, existing) {
      if (existing) return null; // los campos de referencia son inmutables
      const loan = await ownLive(client, 'loans', userId, data.loan_id, 'direction');
      if (!loan) return invalidRef('Préstamo no encontrado o eliminado');
      if (data.transaction_id) {
        // Solo los abonos mueven dinero; un aumento es el registro de un hecho ya ocurrido.
        if (data.kind !== 'payment') return { code: 'validation_error', message: 'Solo un abono puede llevar transaction_id' };
        const tx = await ownLive(client, 'transactions', userId, data.transaction_id, 'type, amount');
        if (!tx) return invalidRef('Transacción no encontrada o eliminada');
        if (tx.type !== (loan.direction === 'owed_to_me' ? 'income' : 'expense')) {
          return { code: 'type_mismatch', message: 'El abono no corresponde al tipo de transacción (cobro = ingreso, pago = gasto)' };
        }
        if (Number(tx.amount) !== Number(data.amount)) return { code: 'amount_mismatch', message: 'El monto del abono no coincide con el de su transacción' };
        if (await transactionIsBacked(client, userId, data.transaction_id)) {
          return { code: 'validation_error', message: 'La transacción ya respalda otro movimiento' };
        }
      }
      return null;
    },
    checkUpdate() { return null; },
    async blockDelete() { return null; },
  },

  credit_card_payments: {
    table: 'credit_card_payments',
    order: 8,
    dataCols: ['credit_card_id', 'account_id', 'transaction_id', 'amount', 'paid_on'],
    immutable: ['credit_card_id', 'account_id', 'transaction_id'],
    schema: creditCardPaymentData,
    select: `t.id, t.credit_card_id, t.account_id, t.transaction_id, t.amount, t.paid_on, ${syncCols}`,
    async validateRefs(client, userId, data, existing) {
      if (existing) return null;
      if (!(await ownLive(client, 'credit_cards', userId, data.credit_card_id))) return invalidRef('Tarjeta no encontrada o eliminada');
      if (data.account_id && !(await ownLive(client, 'accounts', userId, data.account_id))) return invalidRef('Cuenta no encontrada o eliminada');
      if (data.transaction_id) {
        const tx = await ownLive(client, 'transactions', userId, data.transaction_id, 'type, amount, account_id');
        if (!tx) return invalidRef('Transacción no encontrada o eliminada');
        if (tx.type !== 'expense') return { code: 'type_mismatch', message: 'Un pago de tarjeta se registra como gasto' };
        if (Number(tx.amount) !== Number(data.amount)) return { code: 'amount_mismatch', message: 'El monto del pago no coincide con el de su transacción' };
        if (data.account_id && tx.account_id !== data.account_id) return { code: 'validation_error', message: 'La cuenta del pago no coincide con la de su transacción' };
        if (await transactionIsBacked(client, userId, data.transaction_id)) {
          return { code: 'validation_error', message: 'La transacción ya respalda otro movimiento' };
        }
      }
      return null;
    },
    checkUpdate() { return null; },
    async blockDelete() { return null; },
  },
};

// lockOwnRows bloquea las tablas en este orden: si dos tablas empataran, dos lotes que las toquen en
// distinto orden podrían bloquearse entre sí. Un empate es un error de programación.
{
  const orders = Object.values(ENTITIES).map((e) => e.order);
  if (new Set(orders).size !== orders.length) throw new Error('ENTITIES: el campo order debe ser único');
}

// FOR SHARE en las lecturas de padres: un borrado concurrente del padre espera a que este lote
// termine y entonces ve la transacción nueva (→ in_use), en lugar de dejarla viva sobre un padre borrado.

// Tablas de solo lectura para el cliente (catálogo global, sin user_id).
const READONLY_CATALOGS = {
  banks: {
    table: 'banks',
    select: `t.id, t.name, t.logo_key, ${ts('updated_at')} AS updated_at, ${ts('deleted_at')} AS deleted_at`,
  },
};

// Orden de entrega en el pull: catálogos y padres primero.
const PULL_ORDER = ['banks', 'categories', 'accounts', 'loans', 'credit_cards', 'transactions', 'subscriptions', 'loan_movements', 'credit_card_payments'];

module.exports = { ENTITIES, READONLY_CATALOGS, PULL_ORDER };
