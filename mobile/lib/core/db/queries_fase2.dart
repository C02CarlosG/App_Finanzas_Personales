import 'package:drift/drift.dart';

import '../money/money.dart';
import 'app_database.dart';

// Vistas y consultas reactivas de la Fase 2 (préstamos, suscripciones y tarjetas de crédito).

/// Un préstamo con sus totales derivados de los movimientos:
/// `total = principal + aumentos`, `pendiente = total − abonos` (nunca menor a cero al mostrarse).
class LoanView {
  const LoanView({
    required this.id,
    required this.personName,
    required this.direction,
    required this.principal,
    required this.increases,
    required this.payments,
    required this.status,
    required this.pending,
    this.dueDate,
    this.notes,
  });

  final String id;
  final String personName;
  final String direction; // i_owe | owed_to_me
  final Money principal;
  final Money increases;
  final Money payments;
  final String status; // active | paid
  final String? dueDate;
  final String? notes;
  final bool pending; // tiene cambios sin enviar

  bool get iOwe => direction == 'i_owe';
  bool get isPaid => status == 'paid';
  Money get total => principal + increases;

  /// Lo que falta por pagar o cobrar. Dos dispositivos que abonen lo mismo antes de sincronizar pueden
  /// dejar los abonos por encima del total: se muestra 0, no un saldo negativo.
  Money get remaining => payments.cents >= total.cents ? Money.zero : total - payments;
}

class LoanMovementView {
  const LoanMovementView({
    required this.id,
    required this.loanId,
    required this.kind,
    required this.amount,
    required this.occurredOn,
    required this.pending,
    this.transactionId,
    this.accountName,
  });

  final String id;
  final String loanId;
  final String kind; // payment | increase
  final Money amount;
  final String occurredOn;
  final String? transactionId;
  final String? accountName;
  final bool pending;

  bool get isPayment => kind == 'payment';
}

/// Lo que te deben y lo que debes en préstamos activos.
class LoansSummary {
  const LoansSummary({required this.owedToMe, required this.iOwe});
  final Money owedToMe;
  final Money iOwe;
}

class SubscriptionView {
  const SubscriptionView({
    required this.id,
    required this.name,
    required this.amount,
    required this.renewalDate,
    required this.period,
    required this.active,
    required this.pending,
    this.accountId,
    this.accountName,
  });

  final String id;
  final String name;
  final Money amount;
  final String renewalDate;
  final String period; // weekly | monthly | yearly
  final bool active;
  final bool pending;
  final String? accountId;
  final String? accountName;

  /// Costo mensual aproximado (semanal × 52 / 12, anual / 12), redondeado al centavo.
  Money get monthlyEquivalent => switch (period) {
    'weekly' => Money((amount.cents * 52 / 12).round()),
    'yearly' => Money((amount.cents / 12).round()),
    _ => amount,
  };
}

class CreditCardView {
  const CreditCardView({
    required this.id,
    required this.name,
    required this.pendingBalance,
    required this.pending,
    this.bankId,
    this.bankName,
    this.logoKey,
    this.dueDate,
  });

  final String id;
  final String name;
  final Money pendingBalance;
  final bool pending; // tiene cambios sin enviar
  final String? bankId;
  final String? bankName;
  final String? logoKey;
  final String? dueDate;
}

class CardPaymentView {
  const CardPaymentView({
    required this.id,
    required this.creditCardId,
    required this.amount,
    required this.paidOn,
    required this.pending,
    this.transactionId,
    this.accountName,
  });

  final String id;
  final String creditCardId;
  final Money amount;
  final String paidOn;
  final String? transactionId;
  final String? accountName;
  final bool pending;
}

extension Fase2Queries on AppDatabase {
  Set<ResultSetImplementation> get _loanTables => {loans, loanMovements, syncOutbox};

  static const _loanSelect = '''
    SELECT l.id, l.person_name, l.direction, l.principal_cents, l.due_date, l.status, l.notes,
           COALESCE((SELECT SUM(m.amount_cents) FROM loan_movements m
                     WHERE m.loan_id = l.id AND m.kind = 'increase' AND m.deleted_at IS NULL), 0) AS increases_cents,
           COALESCE((SELECT SUM(m.amount_cents) FROM loan_movements m
                     WHERE m.loan_id = l.id AND m.kind = 'payment' AND m.deleted_at IS NULL), 0) AS payments_cents,
           EXISTS(SELECT 1 FROM sync_outbox o WHERE o.entity = 'loans' AND o.record_id = l.id) AS pending
    FROM loans l
    WHERE l.deleted_at IS NULL''';

  LoanView _toLoanView(QueryRow r) => LoanView(
    id: r.read<String>('id'),
    personName: r.read<String>('person_name'),
    direction: r.read<String>('direction'),
    principal: Money(r.read<int>('principal_cents')),
    increases: Money(r.read<int>('increases_cents')),
    payments: Money(r.read<int>('payments_cents')),
    status: r.read<String>('status'),
    dueDate: r.readNullable<String>('due_date'),
    notes: r.readNullable<String>('notes'),
    pending: r.read<int>('pending') == 1,
  );

  /// Activos primero (los que vencen antes, arriba; sin plazo al final), luego los pagados.
  Stream<List<LoanView>> watchLoans() => customSelect(
    '$_loanSelect ORDER BY (l.status = \'paid\'), (l.due_date IS NULL), l.due_date, lower(l.person_name)',
    readsFrom: _loanTables,
  ).watch().map((rows) => [for (final r in rows) _toLoanView(r)]);

  Selectable<QueryRow> _loanById(String id) =>
      customSelect('$_loanSelect AND l.id = ?', variables: [Variable.withString(id)], readsFrom: _loanTables);

  Stream<LoanView?> watchLoan(String id) => _loanById(id).watch().map((rows) => rows.isEmpty ? null : _toLoanView(rows.first));

  /// Lectura única (sin flujo): la usan los repositorios dentro de sus transacciones.
  Future<LoanView?> findLoan(String id) async {
    final rows = await _loanById(id).get();
    return rows.isEmpty ? null : _toLoanView(rows.first);
  }

  /// Historial del préstamo, del más reciente al más viejo.
  Stream<List<LoanMovementView>> watchLoanMovements(String loanId) =>
      customSelect(
        '''
        SELECT m.id, m.loan_id, m.kind, m.amount_cents, m.occurred_on, m.transaction_id, a.name AS account_name,
               EXISTS(SELECT 1 FROM sync_outbox o WHERE o.entity = 'loan_movements' AND o.record_id = m.id) AS pending
        FROM loan_movements m
        LEFT JOIN transactions t ON t.id = m.transaction_id AND t.deleted_at IS NULL
        LEFT JOIN accounts a ON a.id = t.account_id AND a.deleted_at IS NULL
        WHERE m.loan_id = ? AND m.deleted_at IS NULL
        ORDER BY m.occurred_on DESC, m.client_updated_at DESC''',
        variables: [Variable.withString(loanId)],
        readsFrom: {loanMovements, transactions, accounts, syncOutbox},
      ).watch().map(
        (rows) => [
          for (final r in rows)
            LoanMovementView(
              id: r.read<String>('id'),
              loanId: r.read<String>('loan_id'),
              kind: r.read<String>('kind'),
              amount: Money(r.read<int>('amount_cents')),
              occurredOn: r.read<String>('occurred_on'),
              transactionId: r.readNullable<String>('transaction_id'),
              accountName: r.readNullable<String>('account_name'),
              pending: r.read<int>('pending') == 1,
            ),
        ],
      );

  /// Total pendiente de los préstamos activos, separado por sentido.
  Stream<LoansSummary> watchLoansSummary() => watchLoans().map((list) {
    var owed = 0;
    var owe = 0;
    for (final l in list.where((l) => !l.isPaid)) {
      if (l.iOwe) {
        owe += l.remaining.cents;
      } else {
        owed += l.remaining.cents;
      }
    }
    return LoansSummary(owedToMe: Money(owed), iOwe: Money(owe));
  });

  Selectable<QueryRow> get _subscriptionRows => customSelect(
    '''
        SELECT s.id, s.name, s.amount_cents, s.renewal_date, s.period, s.active, s.account_id, a.name AS account_name,
               EXISTS(SELECT 1 FROM sync_outbox o WHERE o.entity = 'subscriptions' AND o.record_id = s.id) AS pending
        FROM subscriptions s
        LEFT JOIN accounts a ON a.id = s.account_id AND a.deleted_at IS NULL
        WHERE s.deleted_at IS NULL
        ORDER BY s.active DESC, lower(s.name)''',
    readsFrom: {subscriptions, accounts, syncOutbox},
  );

  List<SubscriptionView> _toSubscriptionViews(List<QueryRow> rows) => [
    for (final r in rows)
      SubscriptionView(
        id: r.read<String>('id'),
        name: r.read<String>('name'),
        amount: Money(r.read<int>('amount_cents')),
        renewalDate: r.read<String>('renewal_date'),
        period: r.read<String>('period'),
        active: r.read<bool>('active'),
        accountId: r.readNullable<String>('account_id'),
        accountName: r.readNullable<String>('account_name'),
        pending: r.read<int>('pending') == 1,
      ),
  ];

  Stream<List<SubscriptionView>> watchSubscriptions() => _subscriptionRows.watch().map(_toSubscriptionViews);

  Future<SubscriptionView?> findSubscription(String id) async =>
      _toSubscriptionViews(await _subscriptionRows.get()).where((s) => s.id == id).firstOrNull;

  Selectable<QueryRow> get _creditCardRows => customSelect(
    '''
        SELECT c.id, c.name, c.pending_balance_cents, c.due_date, c.bank_id, b.name AS bank_name, b.logo_key,
               EXISTS(SELECT 1 FROM sync_outbox o WHERE o.entity = 'credit_cards' AND o.record_id = c.id) AS pending
        FROM credit_cards c
        LEFT JOIN banks b ON b.id = c.bank_id
        WHERE c.deleted_at IS NULL
        ORDER BY (c.due_date IS NULL), c.due_date, lower(c.name)''',
    readsFrom: {creditCards, banks, syncOutbox},
  );

  List<CreditCardView> _toCreditCardViews(List<QueryRow> rows) => [
    for (final r in rows)
      CreditCardView(
        id: r.read<String>('id'),
        name: r.read<String>('name'),
        pendingBalance: Money(r.read<int>('pending_balance_cents')),
        dueDate: r.readNullable<String>('due_date'),
        bankId: r.readNullable<String>('bank_id'),
        bankName: r.readNullable<String>('bank_name'),
        logoKey: r.readNullable<String>('logo_key'),
        pending: r.read<int>('pending') == 1,
      ),
  ];

  Stream<List<CreditCardView>> watchCreditCards() => _creditCardRows.watch().map(_toCreditCardViews);

  Future<CreditCardView?> findCreditCard(String id) async =>
      _toCreditCardViews(await _creditCardRows.get()).where((c) => c.id == id).firstOrNull;

  Stream<List<CardPaymentView>> watchCardPayments(String cardId) =>
      customSelect(
        '''
        SELECT p.id, p.credit_card_id, p.amount_cents, p.paid_on, p.transaction_id, a.name AS account_name,
               EXISTS(SELECT 1 FROM sync_outbox o WHERE o.entity = 'credit_card_payments' AND o.record_id = p.id) AS pending
        FROM credit_card_payments p
        LEFT JOIN accounts a ON a.id = p.account_id AND a.deleted_at IS NULL
        WHERE p.credit_card_id = ? AND p.deleted_at IS NULL
        ORDER BY p.paid_on DESC, p.client_updated_at DESC''',
        variables: [Variable.withString(cardId)],
        readsFrom: {creditCardPayments, accounts, syncOutbox},
      ).watch().map(
        (rows) => [
          for (final r in rows)
            CardPaymentView(
              id: r.read<String>('id'),
              creditCardId: r.read<String>('credit_card_id'),
              amount: Money(r.read<int>('amount_cents')),
              paidOn: r.read<String>('paid_on'),
              transactionId: r.readNullable<String>('transaction_id'),
              accountName: r.readNullable<String>('account_name'),
              pending: r.read<int>('pending') == 1,
            ),
        ],
      );

  /// `loan` / `card` si la transacción respalda un abono o un pago de tarjeta vivo (no se edita sola).
  Future<String?> linkedKindOfTransaction(String transactionId) async {
    final row = await customSelect(
      '''
      SELECT CASE
        WHEN EXISTS(SELECT 1 FROM loan_movements m WHERE m.transaction_id = ?1 AND m.deleted_at IS NULL) THEN 'loan'
        WHEN EXISTS(SELECT 1 FROM credit_card_payments p WHERE p.transaction_id = ?1 AND p.deleted_at IS NULL) THEN 'card'
      END AS kind''',
      variables: [Variable.withString(transactionId)],
      readsFrom: {loanMovements, creditCardPayments},
    ).getSingle();
    return row.readNullable<String>('kind');
  }

  /// Texto de la pantalla de problemas para las entidades de la Fase 2.
  Future<String?> describePhase2Entry(OutboxEntry e) async {
    switch (e.entity) {
      case 'loans':
        final l = await (select(loans)..where((x) => x.id.equals(e.recordId))).getSingleOrNull();
        return 'Préstamo: ${l?.personName ?? '(eliminado)'}';
      case 'loan_movements':
        final m = await (select(loanMovements)..where((x) => x.id.equals(e.recordId))).getSingleOrNull();
        if (m == null) return 'Movimiento de préstamo (eliminado)';
        return '${m.kind == 'payment' ? 'Abono' : 'Aumento'} de ${Money(m.amountCents).format()} (${m.occurredOn})';
      case 'subscriptions':
        final s = await (select(subscriptions)..where((x) => x.id.equals(e.recordId))).getSingleOrNull();
        return 'Suscripción: ${s?.name ?? '(eliminada)'}';
      case 'credit_cards':
        final c = await (select(creditCards)..where((x) => x.id.equals(e.recordId))).getSingleOrNull();
        return 'Tarjeta: ${c?.name ?? '(eliminada)'}';
      case 'credit_card_payments':
        final p = await (select(creditCardPayments)..where((x) => x.id.equals(e.recordId))).getSingleOrNull();
        if (p == null) return 'Pago de tarjeta (eliminado)';
        return 'Pago de tarjeta de ${Money(p.amountCents).format()} (${p.paidOn})';
    }
    return null;
  }
}
