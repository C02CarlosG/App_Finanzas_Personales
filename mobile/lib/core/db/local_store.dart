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
  LocalStore(this.db, this.clock, {bool Function()? isSyncing, this._onChanged})
      : _isSyncing = isSyncing ?? (() => false);

  final AppDatabase db;
  final StampClock clock;
  final bool Function() _isSyncing;

  /// Se avisa tras confirmar cada escritura local (el sync automático se programa desde aquí).
  final void Function()? _onChanged;
  Future<void>? _clockReady;

  /// Antes del primer sello de la sesión: restaura el desfase de reloj aprendido y garantiza que
  /// ningún sello nuevo sea menor que uno ya guardado (ediciones tras reiniciar la app).
  Future<void> _ensureClock() => _clockReady ??= _loadClock();

  Future<void> _loadClock() async {
    final saved = await db.readState('clock_offset_ms');
    if (saved != null) clock.offset = Duration(milliseconds: int.parse(saved));
    final row = await db.customSelect(
      'SELECT MAX(s) AS m FROM ('
      'SELECT MAX(client_updated_at) AS s FROM categories UNION ALL '
      'SELECT MAX(client_updated_at) FROM accounts UNION ALL '
      'SELECT MAX(client_updated_at) FROM transactions UNION ALL '
      'SELECT MAX(client_updated_at) FROM sync_outbox)',
      readsFrom: {db.categories, db.accounts, db.transactions, db.syncOutbox},
    ).getSingle();
    final floor = row.read<String?>('m');
    if (floor != null) clock.seed(floor);
  }

  Future<void> saveCategory({
    required String id,
    required String kind,
    required String name,
    String? icon,
    String? color,
  }) async {
    await _ensureClock();
    await db.transaction(() async {
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
    _onChanged?.call();
  }

  Future<void> saveAccount({
    required String id,
    required String type,
    String? bankId,
    required String name,
    String? cardType,
    Money initialBalance = Money.zero,
  }) async {
    await _ensureClock();
    await db.transaction(() async {
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
    _onChanged?.call();
  }

  Future<void> saveTransaction({
    required String id,
    required String type,
    required Money amount,
    required String accountId,
    required String categoryId,
    required String occurredOn,
    String? description,
    String? counterparty,
  }) async {
    await _ensureClock();
    await db.transaction(() async {
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
    _onChanged?.call();
  }

  /// Borra un registro. Se elimina físicamente (y se quita de la outbox) solo si **nunca pudo
  /// llegar al servidor**: sin `updated_at`, sin sincronización en curso y sin marca `maybe_sent`
  /// (un envío cuya respuesta se perdió). En otro caso queda como tombstone local con un renglón
  /// `deleted`, para que el servidor también lo borre (docs/sync.md §6).
  Future<void> delete(String entity, String id) async {
    await _ensureClock();
    await db.transaction(() async {
      final updatedAt = await _updatedAt(entity, id);
      final entry = await _outboxEntry(entity, id);
      final neverSent = updatedAt == null && !_isSyncing() && !(entry?.maybeSent ?? false);
      if (neverSent) {
        await _hardDelete(entity, id);
        await _removeOutbox(entity, id);
        return;
      }
      final stamp = clock.stamp();
      await _markDeleted(entity, id, stamp);
      await enqueue(entity, id, stamp, deleted: true);
    });
    _onChanged?.call();
  }

  /// Deja (o reemplaza) el renglón de la outbox del registro: un solo renglón por registro.
  /// Conserva `maybe_sent`: una edición posterior a un envío dudoso sigue siendo "posiblemente enviado".
  Future<void> enqueue(String entity, String id, String stamp, {bool deleted = false}) async {
    final previous = await _outboxEntry(entity, id);
    await db.into(db.syncOutbox).insertOnConflictUpdate(SyncOutboxCompanion(
      entity: Value(entity),
      recordId: Value(id),
      clientUpdatedAt: Value(stamp),
      deleted: Value(deleted),
      attempts: const Value(0),
      lastError: const Value(null),
      blocked: const Value(false),
      maybeSent: Value(previous?.maybeSent ?? false),
    ));
  }

  Future<OutboxEntry?> _outboxEntry(String entity, String id) =>
      (db.select(db.syncOutbox)..where((t) => t.entity.equals(entity) & t.recordId.equals(id))).getSingleOrNull();

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
