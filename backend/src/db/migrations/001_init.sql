-- Esquema completo para todas las fases. Convenciones:
--  * PK UUID; updated_at (trigger) y deleted_at (soft delete) en todas las tablas de datos.
--  * Dinero en NUMERIC(14,2), nunca float. Moneda por usuario (default MXN).
--  * Saldos calculados vía vista, no almacenados.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ---------- Usuarios ----------
CREATE TABLE users (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email         TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  name          TEXT NOT NULL,
  currency      CHAR(3) NOT NULL DEFAULT 'MXN',
  plan          TEXT NOT NULL DEFAULT 'free' CHECK (plan IN ('free', 'premium')),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at    TIMESTAMPTZ
);
CREATE UNIQUE INDEX users_email_uq ON users (lower(email)) WHERE deleted_at IS NULL;

-- ---------- Catálogo de bancos (global, sembrado) ----------
CREATE TABLE banks (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name       TEXT NOT NULL UNIQUE,
  logo_key   TEXT NOT NULL UNIQUE,      -- clave del asset de logo en la app móvil
  sort_order INT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at TIMESTAMPTZ
);

-- ---------- Cuentas (banco / efectivo) ----------
CREATE TABLE accounts (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES users(id),
  type            TEXT NOT NULL CHECK (type IN ('banco', 'efectivo')),
  bank_id         UUID REFERENCES banks(id),
  name            TEXT NOT NULL,
  card_type       TEXT CHECK (card_type IN ('debito', 'credito')),
  initial_balance NUMERIC(14,2) NOT NULL DEFAULT 0,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at      TIMESTAMPTZ,
  CHECK (type = 'banco' OR bank_id IS NULL)
);
CREATE INDEX accounts_user_idx ON accounts (user_id, updated_at);

-- ---------- Categorías (editables, sembradas al registrarse) ----------
CREATE TABLE categories (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID NOT NULL REFERENCES users(id),
  kind       TEXT NOT NULL CHECK (kind IN ('income', 'expense')),
  name       TEXT NOT NULL,
  icon       TEXT,
  color      TEXT,
  is_system  BOOLEAN NOT NULL DEFAULT false, -- p. ej. "Préstamo cobrado": no se puede borrar
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX categories_name_uq ON categories (user_id, kind, lower(name)) WHERE deleted_at IS NULL;
CREATE INDEX categories_user_idx ON categories (user_id, updated_at);

-- ---------- Transacciones (ingresos / gastos) ----------
CREATE TABLE transactions (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES users(id),
  account_id  UUID NOT NULL REFERENCES accounts(id),
  category_id UUID NOT NULL REFERENCES categories(id),
  type        TEXT NOT NULL CHECK (type IN ('income', 'expense')),
  amount      NUMERIC(14,2) NOT NULL CHECK (amount > 0),
  occurred_on DATE NOT NULL,
  description TEXT,
  counterparty TEXT,                    -- p. ej. nombre de la persona en "Préstamo cobrado"
  loan_id     UUID,                     -- FK agregada abajo (Fase 2)
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at  TIMESTAMPTZ
);
CREATE INDEX transactions_user_date_idx ON transactions (user_id, occurred_on DESC);
CREATE INDEX transactions_user_updated_idx ON transactions (user_id, updated_at);
CREATE INDEX transactions_account_idx ON transactions (account_id);
CREATE INDEX transactions_category_idx ON transactions (category_id);

-- ---------- Fase 2: préstamos ----------
CREATE TABLE loans (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES users(id),
  person_name TEXT NOT NULL,
  direction   TEXT NOT NULL CHECK (direction IN ('i_owe', 'owed_to_me')),
  principal   NUMERIC(14,2) NOT NULL CHECK (principal > 0), -- monto acumulado (incluye aumentos)
  due_date    DATE,                                          -- plazo opcional
  status      TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'paid')),
  notes       TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at  TIMESTAMPTZ
);
CREATE INDEX loans_user_idx ON loans (user_id, updated_at);

CREATE TABLE loan_movements (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID NOT NULL REFERENCES users(id),
  loan_id    UUID NOT NULL REFERENCES loans(id),
  kind       TEXT NOT NULL CHECK (kind IN ('payment', 'increase')),
  amount     NUMERIC(14,2) NOT NULL CHECK (amount > 0),
  occurred_on DATE NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at TIMESTAMPTZ
);
CREATE INDEX loan_movements_loan_idx ON loan_movements (loan_id);
CREATE INDEX loan_movements_user_idx ON loan_movements (user_id, updated_at);

ALTER TABLE transactions
  ADD CONSTRAINT transactions_loan_fk FOREIGN KEY (loan_id) REFERENCES loans(id);

-- ---------- Fase 2: suscripciones ----------
CREATE TABLE subscriptions (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL REFERENCES users(id),
  name          TEXT NOT NULL,
  amount        NUMERIC(14,2) NOT NULL CHECK (amount > 0),
  renewal_date  DATE NOT NULL,
  period        TEXT NOT NULL DEFAULT 'monthly' CHECK (period IN ('weekly', 'monthly', 'yearly')),
  account_id    UUID REFERENCES accounts(id),
  active        BOOLEAN NOT NULL DEFAULT true,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at    TIMESTAMPTZ
);
CREATE INDEX subscriptions_user_idx ON subscriptions (user_id, updated_at);

-- ---------- Fase 2: tarjetas de crédito ----------
CREATE TABLE credit_cards (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES users(id),
  bank_id         UUID REFERENCES banks(id),
  name            TEXT NOT NULL,
  pending_balance NUMERIC(14,2) NOT NULL DEFAULT 0,
  due_date        DATE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at      TIMESTAMPTZ
);
CREATE INDEX credit_cards_user_idx ON credit_cards (user_id, updated_at);

CREATE TABLE credit_card_payments (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        UUID NOT NULL REFERENCES users(id),
  credit_card_id UUID NOT NULL REFERENCES credit_cards(id),
  account_id     UUID REFERENCES accounts(id),
  amount         NUMERIC(14,2) NOT NULL CHECK (amount > 0),
  paid_on        DATE NOT NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at     TIMESTAMPTZ
);
CREATE INDEX credit_card_payments_card_idx ON credit_card_payments (credit_card_id);
CREATE INDEX credit_card_payments_user_idx ON credit_card_payments (user_id, updated_at);

-- ---------- Fase 3: presupuestos ----------
CREATE TABLE budgets (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL REFERENCES users(id),
  category_id   UUID NOT NULL REFERENCES categories(id),
  monthly_limit NUMERIC(14,2) NOT NULL CHECK (monthly_limit > 0),
  alert_percent INT NOT NULL DEFAULT 80 CHECK (alert_percent BETWEEN 1 AND 100),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at    TIMESTAMPTZ
);
CREATE UNIQUE INDEX budgets_category_uq ON budgets (user_id, category_id) WHERE deleted_at IS NULL;

-- ---------- Triggers updated_at ----------
DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['users','banks','accounts','categories','transactions','loans',
    'loan_movements','subscriptions','credit_cards','credit_card_payments','budgets']
  LOOP
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION set_updated_at()',
                   t || '_set_updated_at', t);
  END LOOP;
END $$;

-- ---------- Saldos calculados ----------
CREATE VIEW account_balances AS
SELECT a.id AS account_id,
       a.user_id,
       a.initial_balance
         + COALESCE(SUM(CASE WHEN t.type = 'income'  THEN t.amount END), 0)
         - COALESCE(SUM(CASE WHEN t.type = 'expense' THEN t.amount END), 0) AS balance
FROM accounts a
LEFT JOIN transactions t ON t.account_id = a.id AND t.deleted_at IS NULL
WHERE a.deleted_at IS NULL
GROUP BY a.id;

-- ---------- Catálogo de bancos mexicanos ----------
INSERT INTO banks (name, logo_key, sort_order) VALUES
  ('BBVA México', 'bbva', 1),
  ('Santander', 'santander', 2),
  ('Banamex', 'banamex', 3),
  ('Banorte', 'banorte', 4),
  ('HSBC', 'hsbc', 5),
  ('Scotiabank', 'scotiabank', 6),
  ('Inbursa', 'inbursa', 7),
  ('Banco Azteca', 'azteca', 8),
  ('BanCoppel', 'bancoppel', 9),
  ('Afirme', 'afirme', 10),
  ('Banregio', 'banregio', 11),
  ('Nu México', 'nu', 12),
  ('Hey Banco', 'hey', 13),
  ('Mercado Pago', 'mercadopago', 14),
  ('Klar', 'klar', 15),
  ('Spin by OXXO', 'spin', 16);
