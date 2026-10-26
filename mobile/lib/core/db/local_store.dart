import 'package:drift/drift.dart';

import '../money/money.dart';
import '../sync/stamp.dart';
import 'app_database.dart';

/// Nombres de entidad sincronizable, en orden de dependencia (padres primero). Mismo orden que el
/// campo `order` de backend/src/sync/entities.js; el nombre es también el de la tabla SQL.
const syncEntities = [
  'categories',
  'accounts',
  'loans',
  'credit_cards',
  'transactions',
  'subscriptions',
  'loan_movements',
  'credit_card_payments',
];

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
      '${[for (final e in syncEntities) 'SELECT MAX(client_updated_at) AS s FROM $e'].join(' UNION ALL ')}'
      ' UNION ALL SELECT MAX(client_updated_at) FROM sync_outbox)',
      readsFrom: {..._tables.values, db.syncOutbox},
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

  // ---------- Fase 2 ----------

  Future<void> saveLoan({
    required String id,
    required String personName,
    required String direction,
    required Money principal,
    String? dueDate,
    String status = 'active',
    String? notes,
  }) async {
    await _ensureClock();
    await db.transaction(() async {
      final stamp = clock.stamp();
      await db.into(db.loans).insertOnConflictUpdate(LoansCompanion(
        id: Value(id),
        personName: Value(personName),
        direction: Value(direction),
        principalCents: Value(principal.cents),
        dueDate: Value(dueDate),
        status: Value(status),
        notes: Value(notes),
        clientUpdatedAt: Value(stamp),
      ));
      await enqueue('loans', id, stamp);
    });
    _onChanged?.call();
  }

  Future<void> saveLoanMovement({
    required String id,
    required String loanId,
    required String kind,
    required Money amount,
    required String occurredOn,
    String? transactionId,
  }) async {
    await _ensureClock();
    await db.transaction(() async {
      final stamp = clock.stamp();
      await db.into(db.loanMovements).insertOnConflictUpdate(LoanMovementsCompanion(
        id: Value(id),
        loanId: Value(loanId),
        kind: Value(kind),
        amountCents: Value(amount.cents),
        occurredOn: Value(occurredOn),
        transactionId: Value(transactionId),
        clientUpdatedAt: Value(stamp),
      ));
      await enqueue('loan_movements', id, stamp);
    });
    _onChanged?.call();
  }

  Future<void> saveSubscription({
    required String id,
    required String name,
    required Money amount,
    required String renewalDate,
    required String period,
    String? accountId,
    bool active = true,
  }) async {
    await _ensureClock();
    await db.transaction(() async {
      final stamp = clock.stamp();
      await db.into(db.subscriptions).insertOnConflictUpdate(SubscriptionsCompanion(
        id: Value(id),
        name: Value(name),
        amountCents: Value(amount.cents),
        renewalDate: Value(renewalDate),
        period: Value(period),
        accountId: Value(accountId),
        active: Value(active),
        clientUpdatedAt: Value(stamp),
      ));
      await enqueue('subscriptions', id, stamp);
    });
    _onChanged?.call();
  }

  Future<void> saveCreditCard({
    required String id,
    String? bankId,
    required String name,
    required Money pendingBalance,
    String? dueDate,
  }) async {
    await _ensureClock();
    await db.transaction(() async {
      final stamp = clock.stamp();
      await db.into(db.creditCards).insertOnConflictUpdate(CreditCardsCompanion(
        id: Value(id),
        bankId: Value(bankId),
        name: Value(name),
        pendingBalanceCents: Value(pendingBalance.cents),
        dueDate: Value(dueDate),
        clientUpdatedAt: Value(stamp),
      ));
      await enqueue('credit_cards', id, stamp);
    });
    _onChanged?.call();
  }

  Future<void> saveCreditCardPayment({
    required String id,
    required String creditCardId,
    String? accountId,
    String? transactionId,
    required Money amount,
    required String paidOn,
  }) async {
    await _ensureClock();
    await db.transaction(() async {
      final stamp = clock.stamp();
      await db.into(db.creditCardPayments).insertOnConflictUpdate(CreditCardPaymentsCompanion(
        id: Value(id),
        creditCardId: Value(creditCardId),
        accountId: Value(accountId),
        transactionId: Value(transactionId),
        amountCents: Value(amount.cents),
        paidOn: Value(paidOn),
        clientUpdatedAt: Value(stamp),
      ));
      await enqueue('credit_card_payments', id, stamp);
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

  late final Map<String, TableInfo> _tables = {
    for (final t in db.allTables)
      if (syncEntities.contains(t.actualTableName)) t.actualTableName: t,
  };

  TableInfo _table(String entity) => _tables[entity] ?? (throw ArgumentError('Entidad desconocida: $entity'));

  Future<String?> _updatedAt(String entity, String id) async {
    final row = await db.customSelect(
      'SELECT updated_at FROM $entity WHERE id = ?',
      variables: [Variable.withString(id)],
      readsFrom: {_table(entity)},
    ).getSingleOrNull();
    return row?.read<String?>('updated_at');
  }

  Future<void> _hardDelete(String entity, String id) => db.customUpdate(
        'DELETE FROM $entity WHERE id = ?',
        variables: [Variable.withString(id)],
        updates: {_table(entity)},
        updateKind: UpdateKind.delete,
      );

  Future<void> _markDeleted(String entity, String id, String stamp) => db.customUpdate(
        'UPDATE $entity SET deleted_at = ?, client_updated_at = ? WHERE id = ?',
        variables: [Variable.withString(stamp), Variable.withString(stamp), Variable.withString(id)],
        updates: {_table(entity)},
        updateKind: UpdateKind.update,
      );
}
