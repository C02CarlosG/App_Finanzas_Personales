-- Fase 2 (Paso 5): préstamos, suscripciones y tarjetas de crédito entran al sync (ver docs/sync.md).
-- Misma mecánica que 002: client_updated_at (árbitro de last-write-wins), trigger para escrituras
-- sin sello (REST) e índice del pull incremental.
ALTER TABLE loans                ADD COLUMN client_updated_at TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE loan_movements       ADD COLUMN client_updated_at TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE subscriptions        ADD COLUMN client_updated_at TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE credit_cards         ADD COLUMN client_updated_at TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE credit_card_payments ADD COLUMN client_updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

CREATE TRIGGER loans_bump_client_updated_at                BEFORE UPDATE ON loans                FOR EACH ROW EXECUTE FUNCTION bump_client_updated_at();
CREATE TRIGGER loan_movements_bump_client_updated_at       BEFORE UPDATE ON loan_movements       FOR EACH ROW EXECUTE FUNCTION bump_client_updated_at();
CREATE TRIGGER subscriptions_bump_client_updated_at        BEFORE UPDATE ON subscriptions        FOR EACH ROW EXECUTE FUNCTION bump_client_updated_at();
CREATE TRIGGER credit_cards_bump_client_updated_at         BEFORE UPDATE ON credit_cards         FOR EACH ROW EXECUTE FUNCTION bump_client_updated_at();
CREATE TRIGGER credit_card_payments_bump_client_updated_at BEFORE UPDATE ON credit_card_payments FOR EACH ROW EXECUTE FUNCTION bump_client_updated_at();

CREATE INDEX loans_sync_idx                ON loans                (user_id, updated_at, id);
CREATE INDEX loan_movements_sync_idx       ON loan_movements       (user_id, updated_at, id);
CREATE INDEX subscriptions_sync_idx        ON subscriptions        (user_id, updated_at, id);
CREATE INDEX credit_cards_sync_idx         ON credit_cards         (user_id, updated_at, id);
CREATE INDEX credit_card_payments_sync_idx ON credit_card_payments (user_id, updated_at, id);

-- Un abono (o pago de tarjeta) que mueve dinero queda ligado a su ingreso/gasto. El vínculo vive en el
-- movimiento (hijo de la transacción); transactions.loan_id de 001 queda sin uso.
ALTER TABLE loan_movements       ADD COLUMN transaction_id UUID REFERENCES transactions(id);
ALTER TABLE credit_card_payments ADD COLUMN transaction_id UUID REFERENCES transactions(id);
CREATE INDEX loan_movements_tx_idx       ON loan_movements (transaction_id)       WHERE transaction_id IS NOT NULL;
CREATE INDEX credit_card_payments_tx_idx ON credit_card_payments (transaction_id) WHERE transaction_id IS NOT NULL;

-- Para que dos dispositivos converjan, el saldo de un préstamo se deriva y no se guarda:
--   total = principal + Σ aumentos;  pendiente = total − Σ abonos.
COMMENT ON COLUMN loans.principal IS 'Monto original (no cambia con aumentos ni abonos; esos viven en loan_movements)';
COMMENT ON COLUMN transactions.loan_id IS 'En desuso: el vínculo vive en loan_movements.transaction_id';

-- Categorías de sistema nuevas (no se renombran ni se borran): gastos que generan abonos a lo que se debe
-- y pagos de tarjeta. Si el usuario ya tenía una con ese nombre, se vuelve de sistema en lugar de duplicarla.
-- BACKFILL BEGIN
DO $$
DECLARE u RECORD; n TEXT;
BEGIN
  FOR u IN SELECT id FROM users LOOP
    FOREACH n IN ARRAY ARRAY['Pago de préstamo', 'Pago de tarjeta'] LOOP
      UPDATE categories SET name = n, is_system = true
       WHERE user_id = u.id AND kind = 'expense' AND lower(name) = lower(n) AND deleted_at IS NULL;
      IF NOT FOUND THEN
        INSERT INTO categories (user_id, kind, name, is_system) VALUES (u.id, 'expense', n, true);
      END IF;
    END LOOP;
  END LOOP;
END $$;
-- BACKFILL END
