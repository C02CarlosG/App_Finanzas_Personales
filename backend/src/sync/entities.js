// Registro de entidades sincronizables. Para sumar una tabla (Fase 2/3) basta con
// agregarla aquí: esquema de datos, columnas, orden de dependencia y reglas de borrado.
const { z, money, signedMoney, uuid: uuidAny, isoDate } = require('../utils/schemas');

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

const invalidRef = (message) => ({ code: 'invalid_reference', message });

const ENTITIES = {
  categories: {
    table: 'categories',
    order: 1, // padres primero al insertar; al borrar se invierte
    dataCols: ['kind', 'name', 'icon', 'color'],
    immutable: ['kind'],
    schema: categoryData,
    select: `t.id, t.kind, t.name, t.icon, t.color, t.is_system, ${syncCols}`,
    async validateRefs() { return null; },
    checkUpdate(existing, data) {
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
      return used.rowCount ? { code: 'in_use', message: 'La cuenta tiene transacciones' } : null;
    },
  },

  transactions: {
    table: 'transactions',
    order: 3,
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
    checkUpdate() { return null; },
    async blockDelete() { return null; },
  },
};

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
const PULL_ORDER = ['banks', 'categories', 'accounts', 'transactions'];

module.exports = { ENTITIES, READONLY_CATALOGS, PULL_ORDER };
