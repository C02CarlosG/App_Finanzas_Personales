-- Purga de tombstones (Paso 7, docs/sync.md §7). El servidor borra de verdad los registros eliminados hace
-- más de TOMBSTONE_RETENTION_DAYS; para que un dispositivo que no los vio no se quede con datos fantasma,
-- anota hasta dónde purgó, por usuario y tabla: la posición (updated_at, id) del tombstone más nuevo borrado.
-- Un cursor que quedó por detrás de esa marca recibe 410 resync_required.
CREATE TABLE sync_purge_watermarks (
  user_id    UUID NOT NULL REFERENCES users(id),
  table_name TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL,
  id         UUID NOT NULL,
  PRIMARY KEY (user_id, table_name)
);

-- La purga busca tombstones viejos sin recorrer las tablas completas.
CREATE INDEX accounts_tombstone_idx             ON accounts             (updated_at) WHERE deleted_at IS NOT NULL;
CREATE INDEX categories_tombstone_idx           ON categories           (updated_at) WHERE deleted_at IS NOT NULL;
CREATE INDEX transactions_tombstone_idx         ON transactions         (updated_at) WHERE deleted_at IS NOT NULL;
CREATE INDEX loans_tombstone_idx                ON loans                (updated_at) WHERE deleted_at IS NOT NULL;
CREATE INDEX loan_movements_tombstone_idx       ON loan_movements       (updated_at) WHERE deleted_at IS NOT NULL;
CREATE INDEX subscriptions_tombstone_idx        ON subscriptions        (updated_at) WHERE deleted_at IS NOT NULL;
CREATE INDEX credit_cards_tombstone_idx         ON credit_cards         (updated_at) WHERE deleted_at IS NOT NULL;
CREATE INDEX credit_card_payments_tombstone_idx ON credit_card_payments (updated_at) WHERE deleted_at IS NOT NULL;
CREATE INDEX budgets_tombstone_idx              ON budgets              (updated_at) WHERE deleted_at IS NOT NULL;
