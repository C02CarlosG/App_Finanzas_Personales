import 'package:drift/drift.dart';

import '../money/money.dart';
import 'app_database.dart';
import 'queries_fase2.dart';

/// Cuenta con su banco y su saldo calculado (saldo inicial + ingresos − gastos).
class AccountView {
  const AccountView({
    required this.id,
    required this.type,
    required this.name,
    required this.initialBalance,
    required this.balance,
    required this.pending,
    this.bankId,
    this.bankName,
    this.logoKey,
    this.cardType,
  });

  final String id;
  final String type; // banco | efectivo
  final String? bankId;
  final String? bankName;
  final String? logoKey;
  final String name;
  final String? cardType; // debito | credito
  final Money initialBalance;
  final Money balance;
  final bool pending; // tiene cambios sin enviar

  bool get isCash => type == 'efectivo';
}

class TransactionView {
  const TransactionView({
    required this.id,
    required this.type,
    required this.amount,
    required this.accountId,
    required this.categoryId,
    required this.occurredOn,
    required this.pending,
    this.accountName,
    this.bankId,
    this.bankName,
    this.logoKey,
    this.categoryName,
    this.categoryColor,
    this.description,
    this.counterparty,
  });

  final String id;
  final String type; // income | expense
  final Money amount;
  final String accountId;
  final String? accountName;
  final String? bankId;
  final String? bankName;
  final String? logoKey;
  final String categoryId;
  final String? categoryName;
  final String? categoryColor;
  final String occurredOn;
  final String? description;
  final String? counterparty;
  final bool pending;

  bool get isIncome => type == 'income';

  /// Importe con signo para mostrar: ingresos positivos, gastos negativos.
  Money get signedAmount => isIncome ? amount : -amount;

  /// Falta la cuenta o la categoría, o quedó eliminada (p. ej. se borró en otro dispositivo): "huérfana".
  /// Los JOIN ignoran padres con tombstone, así que `accountName`/`categoryName` son null en ese caso.
  bool get isOrphan => accountName == null || categoryName == null;
}

/// Filtros de los listados (spec 4.3/4.4). Fechas como `YYYY-MM-DD`; rango `[from, to)`.
class TransactionFilter {
  const TransactionFilter({
    this.type,
    this.categoryId,
    this.accountId,
    this.bankId,
    this.query,
    this.from,
    this.to,
    this.limit,
  });

  final String? type;
  final String? categoryId;
  final String? accountId;
  final String? bankId;
  final String? query;
  final String? from;
  final String? to;
  final int? limit;

  @override
  bool operator ==(Object other) =>
      other is TransactionFilter &&
      other.type == type &&
      other.categoryId == categoryId &&
      other.accountId == accountId &&
      other.bankId == bankId &&
      other.query == query &&
      other.from == from &&
      other.to == to &&
      other.limit == limit;

  @override
  int get hashCode => Object.hash(type, categoryId, accountId, bankId, query, from, to, limit);

  TransactionFilter copyWith({
    String? Function()? categoryId,
    String? Function()? accountId,
    String? Function()? bankId,
    String? Function()? query,
  }) =>
      TransactionFilter(
        type: type,
        categoryId: categoryId != null ? categoryId() : this.categoryId,
        accountId: accountId != null ? accountId() : this.accountId,
        bankId: bankId != null ? bankId() : this.bankId,
        query: query != null ? query() : this.query,
        from: from,
        to: to,
        limit: limit,
      );
}

class Totals {
  const Totals({required this.income, required this.expense});
  final Money income;
  final Money expense;
  Money get net => income - expense;
}

/// Un cambio pendiente que el servidor rechazó o no pudo aplicar (docs/sync.md §4).
class OutboxProblem {
  const OutboxProblem(this.entry);
  final OutboxEntry entry;
}

/// Consultas reactivas para las pantallas. Todo se lee de SQLite local, nunca de la red.
extension AppQueries on AppDatabase {
  static const _txJoins = '''
    FROM transactions t
    LEFT JOIN accounts a ON a.id = t.account_id AND a.deleted_at IS NULL
    LEFT JOIN banks b ON b.id = a.bank_id
    LEFT JOIN categories c ON c.id = t.category_id AND c.deleted_at IS NULL''';

  Set<ResultSetImplementation> get _allTables => {accounts, banks, categories, transactions, syncOutbox};

  Stream<List<BankRow>> watchBanks() =>
      (select(banks)
            ..where((b) => b.deletedAt.isNull())
            ..orderBy([(b) => OrderingTerm.asc(b.name.lower())]))
          .watch();

  Stream<List<CategoryRow>> watchCategories({String? kind}) =>
      (select(categories)
            ..where((c) => c.deletedAt.isNull() & (kind == null ? const Constant(true) : c.kind.equals(kind)))
            ..orderBy([(c) => OrderingTerm.asc(c.isSystem), (c) => OrderingTerm.asc(c.name.lower())]))
          .watch();

  Stream<List<AccountView>> watchAccounts() => customSelect(
        '''
        SELECT a.id, a.type, a.bank_id, b.name AS bank_name, b.logo_key, a.name, a.card_type,
               a.initial_balance_cents,
               a.initial_balance_cents + COALESCE(SUM(CASE t.type
                 WHEN 'income' THEN t.amount_cents WHEN 'expense' THEN -t.amount_cents END), 0) AS balance_cents,
               EXISTS(SELECT 1 FROM sync_outbox o WHERE o.entity = 'accounts' AND o.record_id = a.id) AS pending
        FROM accounts a
        LEFT JOIN banks b ON b.id = a.bank_id
        LEFT JOIN transactions t ON t.account_id = a.id AND t.deleted_at IS NULL
        WHERE a.deleted_at IS NULL
        GROUP BY a.id
        ORDER BY a.type, lower(a.name)''',
        readsFrom: _allTables,
      ).watch().map((rows) => [
            for (final r in rows)
              AccountView(
                id: r.read<String>('id'),
                type: r.read<String>('type'),
                bankId: r.readNullable<String>('bank_id'),
                bankName: r.readNullable<String>('bank_name'),
                logoKey: r.readNullable<String>('logo_key'),
                name: r.read<String>('name'),
                cardType: r.readNullable<String>('card_type'),
                initialBalance: Money(r.read<int>('initial_balance_cents')),
                balance: Money(r.read<int>('balance_cents')),
                pending: r.read<int>('pending') == 1,
              ),
          ]);

  /// Saldo total = suma de los saldos de todas las cuentas (spec 5.2).
  Stream<Money> watchTotalBalance() =>
      watchAccounts().map((list) => list.fold(Money.zero, (sum, a) => sum + a.balance));

  (String, List<Variable>) _where(TransactionFilter f) {
    final clauses = <String>['t.deleted_at IS NULL'];
    final vars = <Variable>[];
    void add(String sql, String? value) {
      if (value == null) return;
      clauses.add(sql);
      vars.add(Variable.withString(value));
    }

    add('t.type = ?', f.type);
    add('t.category_id = ?', f.categoryId);
    add('t.account_id = ?', f.accountId);
    add('a.bank_id = ?', f.bankId);
    add('t.occurred_on >= ?', f.from);
    add('t.occurred_on < ?', f.to);
    final q = f.query?.trim();
    if (q != null && q.isNotEmpty) {
      clauses.add(r"(t.description LIKE ? ESCAPE '\' OR t.counterparty LIKE ? ESCAPE '\')");
      final like = '%${q.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_')}%';
      vars..add(Variable.withString(like))..add(Variable.withString(like));
    }
    return (clauses.join(' AND '), vars);
  }

  Stream<List<TransactionView>> watchTransactions(TransactionFilter f) {
    final (where, vars) = _where(f);
    return customSelect(
      '''
      SELECT t.id, t.type, t.amount_cents, t.account_id, a.name AS account_name, a.bank_id, b.name AS bank_name,
             b.logo_key, t.category_id, c.name AS category_name, c.color AS category_color, t.occurred_on,
             t.description, t.counterparty,
             EXISTS(SELECT 1 FROM sync_outbox o WHERE o.entity = 'transactions' AND o.record_id = t.id) AS pending
      $_txJoins
      WHERE $where
      ORDER BY t.occurred_on DESC, t.client_updated_at DESC
      ${f.limit != null ? 'LIMIT ${f.limit}' : ''}''',
      variables: vars,
      readsFrom: _allTables,
    ).watch().map((rows) => [for (final r in rows) _toTransactionView(r)]);
  }

  Future<TransactionView?> findTransaction(String id) async {
    final rows = await customSelect(
      '''
      SELECT t.id, t.type, t.amount_cents, t.account_id, a.name AS account_name, a.bank_id, b.name AS bank_name,
             b.logo_key, t.category_id, c.name AS category_name, c.color AS category_color, t.occurred_on,
             t.description, t.counterparty,
             EXISTS(SELECT 1 FROM sync_outbox o WHERE o.entity = 'transactions' AND o.record_id = t.id) AS pending
      $_txJoins
      WHERE t.id = ? AND t.deleted_at IS NULL''',
      variables: [Variable.withString(id)],
      readsFrom: _allTables,
    ).get();
    return rows.isEmpty ? null : _toTransactionView(rows.first);
  }

  TransactionView _toTransactionView(QueryRow r) => TransactionView(
        id: r.read<String>('id'),
        type: r.read<String>('type'),
        amount: Money(r.read<int>('amount_cents')),
        accountId: r.read<String>('account_id'),
        accountName: r.readNullable<String>('account_name'),
        bankId: r.readNullable<String>('bank_id'),
        bankName: r.readNullable<String>('bank_name'),
        logoKey: r.readNullable<String>('logo_key'),
        categoryId: r.read<String>('category_id'),
        categoryName: r.readNullable<String>('category_name'),
        categoryColor: r.readNullable<String>('category_color'),
        occurredOn: r.read<String>('occurred_on'),
        description: r.readNullable<String>('description'),
        counterparty: r.readNullable<String>('counterparty'),
        pending: r.read<int>('pending') == 1,
      );

  /// Totales de ingresos y gastos del filtro (p. ej. "resumen del mes", spec 4.3).
  Stream<Totals> watchTotals(TransactionFilter f) {
    final (where, vars) = _where(f);
    return customSelect(
      '''
      SELECT COALESCE(SUM(CASE WHEN t.type = 'income' THEN t.amount_cents END), 0) AS income,
             COALESCE(SUM(CASE WHEN t.type = 'expense' THEN t.amount_cents END), 0) AS expense
      $_txJoins
      WHERE $where''',
      variables: vars,
      readsFrom: _allTables,
    ).watchSingle().map((r) => Totals(income: Money(r.read<int>('income')), expense: Money(r.read<int>('expense'))));
  }

  /// Cambios con error o bloqueados (no los que solo esperan turno).
  Stream<List<OutboxEntry>> watchOutboxProblems() =>
      (select(syncOutbox)..where((o) => o.blocked.equals(true) | o.lastError.isNotNull())).watch();

  Stream<int> watchPendingCount() => customSelect(
        'SELECT COUNT(*) AS n FROM sync_outbox',
        readsFrom: {syncOutbox},
      ).watchSingle().map((r) => r.read<int>('n'));

  /// Texto corto para identificar un cambio pendiente (pantalla de problemas de sincronización).
  Future<String> describeOutboxEntry(OutboxEntry e) async {
    switch (e.entity) {
      case 'transactions':
        final t = await findTransaction(e.recordId) ??
            (await (select(transactions)..where((x) => x.id.equals(e.recordId))).getSingleOrNull())
                ?.let((r) => TransactionView(
                      id: r.id,
                      type: r.type,
                      amount: Money(r.amountCents),
                      accountId: r.accountId,
                      categoryId: r.categoryId,
                      occurredOn: r.occurredOn,
                      description: r.description,
                      pending: true,
                    ));
        if (t == null) return e.deleted ? 'Movimiento eliminado' : 'Movimiento';
        final kind = t.isIncome ? 'Ingreso' : 'Gasto';
        final what = (t.description?.isNotEmpty ?? false) ? ' · ${t.description}' : '';
        return '$kind de ${t.amount.format()}$what (${t.occurredOn})';
      case 'accounts':
        final a = await (select(accounts)..where((x) => x.id.equals(e.recordId))).getSingleOrNull();
        return 'Cuenta: ${a?.name ?? '(eliminada)'}';
      case 'categories':
        final c = await (select(categories)..where((x) => x.id.equals(e.recordId))).getSingleOrNull();
        return 'Categoría: ${c?.name ?? '(eliminada)'}';
    }
    return await describePhase2Entry(e) ?? e.entity;
  }
}

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
