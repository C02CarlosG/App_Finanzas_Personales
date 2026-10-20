-- Sincronización offline (ver docs/sync.md).
-- client_updated_at: sello de la última edición según el cliente (acotado por el servidor).
-- Es el árbitro de last-write-wins por registro; updated_at (servidor) solo ordena el pull.
-- Filas existentes quedan con la fecha de la migración como valor inicial.
ALTER TABLE accounts     ADD COLUMN client_updated_at TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE categories   ADD COLUMN client_updated_at TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE transactions ADD COLUMN client_updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

-- Si quien escribe no fija client_updated_at (p. ej. los endpoints REST), se sella con now():
-- así una edición REST posterior siempre gana a un cambio de sync más viejo.
CREATE OR REPLACE FUNCTION bump_client_updated_at() RETURNS trigger AS $$
BEGIN
  IF NEW.client_updated_at IS NOT DISTINCT FROM OLD.client_updated_at THEN
    NEW.client_updated_at = now();
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER accounts_bump_client_updated_at     BEFORE UPDATE ON accounts     FOR EACH ROW EXECUTE FUNCTION bump_client_updated_at();
CREATE TRIGGER categories_bump_client_updated_at   BEFORE UPDATE ON categories   FOR EACH ROW EXECUTE FUNCTION bump_client_updated_at();
CREATE TRIGGER transactions_bump_client_updated_at BEFORE UPDATE ON transactions FOR EACH ROW EXECUTE FUNCTION bump_client_updated_at();

-- Índice para el pull incremental por (updated_at, id) de las tablas sincronizadas.
CREATE INDEX accounts_sync_idx     ON accounts     (user_id, updated_at, id);
CREATE INDEX categories_sync_idx   ON categories   (user_id, updated_at, id);
CREATE INDEX transactions_sync_idx ON transactions (user_id, updated_at, id);
