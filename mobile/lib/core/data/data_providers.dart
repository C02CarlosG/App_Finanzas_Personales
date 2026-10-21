import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/accounts/data/accounts_repository.dart';
import '../../features/categories/data/categories_repository.dart';
import '../../features/transactions/data/transactions_repository.dart';
import '../db/app_database.dart';
import '../db/local_store.dart';
import '../db/queries.dart';
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

LocalStore _store(Ref ref) {
  final store = ref.watch(localStoreProvider);
  if (store == null) throw StateError('No hay base local: inicia sesión primero');
  return store;
}

