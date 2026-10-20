import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'tables.dart';

part 'app_database.g.dart';

@DriftDatabase(tables: [Banks, Categories, Accounts, Transactions, SyncOutbox, SyncState])
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

  @override
  int get schemaVersion => 1;

  Future<String?> readState(String key) async {
    final row = await (select(syncState)..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> writeState(String key, String value) =>
      into(syncState).insertOnConflictUpdate(SyncStateCompanion.insert(key: key, value: value));
}
