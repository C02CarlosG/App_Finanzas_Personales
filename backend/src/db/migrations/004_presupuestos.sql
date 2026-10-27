-- Fase 3 (Paso 6): los presupuestos entran al sync (ver docs/sync.md). Misma mecánica que 002 y 003.
ALTER TABLE budgets ADD COLUMN client_updated_at TIMESTAMPTZ NOT NULL DEFAULT now();
CREATE TRIGGER budgets_bump_client_updated_at BEFORE UPDATE ON budgets FOR EACH ROW EXECUTE FUNCTION bump_client_updated_at();
CREATE INDEX budgets_sync_idx ON budgets (user_id, updated_at, id);

-- Un presupuesto vivo por categoría ya lo garantiza budgets_category_uq (001). El avance (gastado / límite) no se
-- guarda: cada dispositivo lo calcula con las transacciones del mes, así que nunca diverge.
COMMENT ON COLUMN budgets.monthly_limit IS 'Límite mensual de la categoría de gastos; el gastado se deriva de transactions';
