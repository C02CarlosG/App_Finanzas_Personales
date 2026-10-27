import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'tables.dart';

part 'app_database.g.dart';

@DriftDatabase(tables: [
  Banks,
  Categories,
  Accounts,
  Transactions,
  Loans,
  LoanMovements,
  Subscriptions,
  CreditCards,
  CreditCardPayments,
  Budgets,
  SyncOutbox,
  SyncState,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// Una base por usuario (docs/sync.md §6): outbox, cursor y datos nunca se mezclan
  /// entre cuentas. El `userId` es el UUID del servidor, seguro como nombre de archivo.
  factory AppDatabase.forUser(String userId) => AppDatabase(
        driftDatabase(
          name: 'finanzas_$userId',
          web: DriftWebOptions(
            sqlite3Wasm: Uri.parse('sqlite3.wasm'),
            driftWorker: Uri.parse('drift_worker.js'),
          ),
        ),
      );

  /// 2 = Fase 2 (préstamos, suscripciones, tarjetas); 3 = Fase 3 (presupuestos). Una base de una versión
  /// anterior recibe las tablas nuevas; el cursor del pull no cambia: el servidor completa con cero las tablas
  /// que le faltan.
  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.createTable(loans);
            await m.createTable(loanMovements);
            await m.createTable(subscriptions);
            await m.createTable(creditCards);
            await m.createTable(creditCardPayments);
          }
          if (from < 3) {
            await m.createTable(budgets);
          }
        },
      );

  Future<String?> readState(String key) async {
    final row = await (select(syncState)..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> deleteState(String key) => (delete(syncState)..where((t) => t.key.equals(key))).go();

  Future<void> writeState(String key, String value) =>
      into(syncState).insertOnConflictUpdate(SyncStateCompanion.insert(key: key, value: value));
}
