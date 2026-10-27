import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/accounts/data/accounts_repository.dart';
import '../../features/budgets/data/budgets_repository.dart';
import '../../features/cards/data/credit_cards_repository.dart';
import '../../features/categories/data/categories_repository.dart';
import '../../features/loans/data/loans_repository.dart';
import '../../features/subscriptions/data/subscriptions_repository.dart';
import '../../features/transactions/data/transactions_repository.dart';
import '../db/app_database.dart';
import '../db/local_store.dart';
import '../db/queries.dart';
import '../db/queries_fase2.dart';
import '../db/queries_fase3.dart';
import '../money/money.dart';
import '../providers.dart';

// Todo se lee de SQLite local (streams reactivos). Sin base abierta no emiten nada.

final banksProvider = StreamProvider<List<BankRow>>(
  (ref) => ref.watch(databaseProvider)?.watchBanks() ?? const Stream.empty(),
);

final accountsProvider = StreamProvider<List<AccountView>>(
  (ref) => ref.watch(databaseProvider)?.watchAccounts() ?? const Stream.empty(),
);

final totalBalanceProvider = StreamProvider<Money>(
  (ref) => ref.watch(databaseProvider)?.watchTotalBalance() ?? const Stream.empty(),
);

/// `kind` = `income` | `expense`; `null` = todas.
final categoriesProvider = StreamProvider.family<List<CategoryRow>, String?>(
  (ref, kind) => ref.watch(databaseProvider)?.watchCategories(kind: kind) ?? const Stream.empty(),
);

final transactionsProvider = StreamProvider.family<List<TransactionView>, TransactionFilter>(
  (ref, filter) => ref.watch(databaseProvider)?.watchTransactions(filter) ?? const Stream.empty(),
);

final totalsProvider = StreamProvider.family<Totals, TransactionFilter>(
  (ref, filter) => ref.watch(databaseProvider)?.watchTotals(filter) ?? const Stream.empty(),
);

// Fase 2

/// "Hoy" para fechas límite y renovaciones; las pruebas lo sustituyen.
final todayProvider = Provider<DateTime>((ref) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
});

final loansProvider = StreamProvider<List<LoanView>>(
  (ref) => ref.watch(databaseProvider)?.watchLoans() ?? const Stream.empty(),
);

final loanProvider = StreamProvider.family<LoanView?, String>(
  (ref, id) => ref.watch(databaseProvider)?.watchLoan(id) ?? const Stream.empty(),
);

final loanMovementsProvider = StreamProvider.family<List<LoanMovementView>, String>(
  (ref, loanId) => ref.watch(databaseProvider)?.watchLoanMovements(loanId) ?? const Stream.empty(),
);

final loansSummaryProvider = StreamProvider<LoansSummary>(
  (ref) => ref.watch(databaseProvider)?.watchLoansSummary() ?? const Stream.empty(),
);

final subscriptionsProvider = StreamProvider<List<SubscriptionView>>(
  (ref) => ref.watch(databaseProvider)?.watchSubscriptions() ?? const Stream.empty(),
);

final creditCardsProvider = StreamProvider<List<CreditCardView>>(
  (ref) => ref.watch(databaseProvider)?.watchCreditCards() ?? const Stream.empty(),
);

final cardPaymentsProvider = StreamProvider.family<List<CardPaymentView>, String>(
  (ref, cardId) => ref.watch(databaseProvider)?.watchCardPayments(cardId) ?? const Stream.empty(),
);

/// `loan` / `card` si el movimiento respalda un abono o un pago de tarjeta (no se edita desde Movimientos).
/// Reactivo y por pantalla: no queda obsoleto al llegar o deshacerse el abono.
final linkedKindProvider = StreamProvider.autoDispose.family<String?, String>(
  (ref, transactionId) => ref.watch(databaseProvider)?.watchLinkedKind(transactionId) ?? const Stream.empty(),
);

// Fase 3: reportes y presupuestos. Los rangos son `[from, to)` en `YYYY-MM-DD`.

typedef DateRange = ({String from, String to});

final expensesByCategoryProvider = StreamProvider.autoDispose.family<List<CategorySpend>, DateRange>(
  (ref, r) => ref.watch(databaseProvider)?.watchExpensesByCategory(r.from, r.to) ?? const Stream.empty(),
);

final monthlyTrendProvider = StreamProvider.autoDispose.family<List<MonthPoint>, ({int year, int month})>(
  (ref, m) => ref.watch(databaseProvider)?.watchMonthlyTrend(m.year, m.month) ?? const Stream.empty(),
);

final budgetsProvider = StreamProvider.autoDispose.family<List<BudgetProgress>, DateRange>(
  (ref, r) => ref.watch(databaseProvider)?.watchBudgets(r.from, r.to) ?? const Stream.empty(),
);

final pendingCountProvider = StreamProvider<int>(
  (ref) => ref.watch(databaseProvider)?.watchPendingCount() ?? const Stream.empty(),
);

final outboxProblemsProvider = StreamProvider<List<OutboxEntry>>(
  (ref) => ref.watch(databaseProvider)?.watchOutboxProblems() ?? const Stream.empty(),
);

// Repositorios (reglas de negocio + escritura local con outbox).

final accountsRepositoryProvider = Provider<AccountsRepository>(
  (ref) => AccountsRepository(_store(ref)),
);

final categoriesRepositoryProvider = Provider<CategoriesRepository>(
  (ref) => CategoriesRepository(_store(ref)),
);

final transactionsRepositoryProvider = Provider<TransactionsRepository>(
  (ref) => TransactionsRepository(_store(ref)),
);

final loansRepositoryProvider = Provider<LoansRepository>(
  (ref) => LoansRepository(_store(ref)),
);

final subscriptionsRepositoryProvider = Provider<SubscriptionsRepository>(
  (ref) => SubscriptionsRepository(_store(ref)),
);

final creditCardsRepositoryProvider = Provider<CreditCardsRepository>(
  (ref) => CreditCardsRepository(_store(ref)),
);

final budgetsRepositoryProvider = Provider<BudgetsRepository>(
  (ref) => BudgetsRepository(_store(ref)),
);

LocalStore _store(Ref ref) {
  final store = ref.watch(localStoreProvider);
  if (store == null) throw StateError('No hay base local: inicia sesión primero');
  return store;
}

