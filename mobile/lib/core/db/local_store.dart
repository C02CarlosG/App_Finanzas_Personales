import 'package:drift/drift.dart';

import '../money/money.dart';
import '../sync/stamp.dart';
import 'app_database.dart';

/// Nombres de entidad sincronizable, en orden de dependencia (padres primero).
const syncEntities = ['categories', 'accounts', 'transactions'];

/// Escrituras locales: cada cambio actualiza la tabla, sella `client_updated_at`
/// y deja (o reemplaza) el renglón de la outbox, todo en una transacción.
///
/// Las pantallas escriben **solo** por aquí; nunca directo a las tablas.
class LocalStore {
  LocalStore(this.db, this.clock, {bool Function()? isSyncing}) : _isSyncing = isSyncing ?? (() => false);

  final AppDatabase db;
  final StampClock clock;
  final bool Function() _isSyncing;

  Future<void> saveCategory({
    required String id,
    required String kind,
    required String name,
    String? icon,
    String? color,
  }) =>
      db.transaction(() async {
        final stamp = clock.stamp();
        await db.into(db.categories).insertOnConflictUpdate(CategoriesCompanion(
          id: Value(id),
          kind: Value(kind),
          name: Value(name),
          icon: Value(icon),
          color: Value(color),
          clientUpdatedAt: Value(stamp),
        ));
        await enqueue('categories', id, stamp);
      });

  Future<void> saveAccount({
    required String id,
    required String type,
    String? bankId,
    required String name,
    String? cardType,
    Money initialBalance = Money.zero,
  }) =>
      db.transaction(() async {
        final stamp = clock.stamp();
        await db.into(db.accounts).insertOnConflictUpdate(AccountsCompanion(
          id: Value(id),
          type: Value(type),
          bankId: Value(bankId),
          name: Value(name),
          cardType: Value(cardType),
          initialBalanceCents: Value(initialBalance.cents),
          clientUpdatedAt: Value(stamp),
        ));
        await enqueue('accounts', id, stamp);
      });

  Future<void> saveTransaction({
    required String id,
    required String type,
    required Money amount,
    required String accountId,
    required String categoryId,
    required String occurredOn,
    String? description,
    String? counterparty,
  }) =>
      db.transaction(() async {
        final stamp = clock.stamp();
        await db.into(db.transactions).insertOnConflictUpdate(TransactionsCompanion(
          id: Value(id),
          type: Value(type),
          amountCents: Value(amount.cents),
          accountId: Value(accountId),
          categoryId: Value(categoryId),
          occurredOn: Value(occurredOn),
          description: Value(description),
          counterparty: Value(counterparty),
          clientUpdatedAt: Value(stamp),
        ));
        await enqueue('transactions', id, stamp);
      });

  /// Borra un registro. Se elimina físicamente (y se quita de la outbox) solo si
  /// **nunca se envió** (sin `updated_at` del servidor y sin sincronización en curso);
  /// en otro caso queda como tombstone local con un renglón `deleted` (docs/sync.md §6).
  Future<void> delete(String entity, String id) => db.transaction(() async {
        final updatedAt = await _updatedAt(entity, id);
        final neverSent = updatedAt == null && !_isSyncing();
        if (neverSent) {
          await _hardDelete(entity, id);
          await _removeOutbox(entity, id);
          return;
        }
        final stamp = clock.stamp();
        await _markDeleted(entity, id, stamp);
        await enqueue(entity, id, stamp, deleted: true);
      });

  /// Deja (o reemplaza) el renglón de la outbox del registro: un solo renglón por registro.
  Future<void> enqueue(String entity, String id, String stamp, {bool deleted = false}) =>
      db.into(db.syncOutbox).insertOnConflictUpdate(SyncOutboxCompanion(
        entity: Value(entity),
        recordId: Value(id),
        clientUpdatedAt: Value(stamp),
        deleted: Value(deleted),
        attempts: const Value(0),
        lastError: const Value(null),
        blocked: const Value(false),
      ));

  Future<void> _removeOutbox(String entity, String id) =>
      (db.delete(db.syncOutbox)..where((t) => t.entity.equals(entity) & t.recordId.equals(id))).go();

  Future<String?> _updatedAt(String entity, String id) async {
    switch (entity) {
      case 'categories':
        return (await (db.select(db.categories)..where((t) => t.id.equals(id))).getSingleOrNull())?.updatedAt;
      case 'accounts':
        return (await (db.select(db.accounts)..where((t) => t.id.equals(id))).getSingleOrNull())?.updatedAt;
      case 'transactions':
        return (await (db.select(db.transactions)..where((t) => t.id.equals(id))).getSingleOrNull())?.updatedAt;
    }
    throw ArgumentError('Entidad desconocida: $entity');
  }

  Future<void> _hardDelete(String entity, String id) async {
    switch (entity) {
      case 'categories':
        await (db.delete(db.categories)..where((t) => t.id.equals(id))).go();
      case 'accounts':
        await (db.delete(db.accounts)..where((t) => t.id.equals(id))).go();
      case 'transactions':
        await (db.delete(db.transactions)..where((t) => t.id.equals(id))).go();
      default:
        throw ArgumentError('Entidad desconocida: $entity');
    }
  }

  Future<void> _markDeleted(String entity, String id, String stamp) async {
    switch (entity) {
      case 'categories':
        await (db.update(db.categories)..where((t) => t.id.equals(id)))
            .write(CategoriesCompanion(deletedAt: Value(stamp), clientUpdatedAt: Value(stamp)));
      case 'accounts':
        await (db.update(db.accounts)..where((t) => t.id.equals(id)))
            .write(AccountsCompanion(deletedAt: Value(stamp), clientUpdatedAt: Value(stamp)));
      case 'transactions':
        await (db.update(db.transactions)..where((t) => t.id.equals(id)))
            .write(TransactionsCompanion(deletedAt: Value(stamp), clientUpdatedAt: Value(stamp)));
      default:
        throw ArgumentError('Entidad desconocida: $entity');
    }
  }
}
