import 'package:drift/drift.dart';

import '../db/app_database.dart';
import '../money/money.dart';

/// Adaptador entre una tabla local y el formato JSON del protocolo de sync.
abstract class SyncTable {
  const SyncTable(this.db);

  final AppDatabase db;

  String get entity;

  /// `data` del cambio a enviar; `null` si el registro ya no existe localmente.
  Future<Map<String, dynamic>?> dataFor(String id);

  /// Escribe (inserta o reemplaza) la fila local con la versión del servidor.
  Future<void> applyServerRecord(Map<String, dynamic> record);

  /// Solo actualiza `updated_at` del servidor (conserva los datos locales más nuevos).
  Future<void> markSynced(String id, String updatedAt);

  /// Borra físicamente la fila local (alta que el servidor rechazó o desconoce).
  Future<void> removeLocal(String id);
}

class CategoriesSync extends SyncTable {
  const CategoriesSync(super.db);

  @override
  String get entity => 'categories';

  @override
  Future<Map<String, dynamic>?> dataFor(String id) async {
    final r = await (db.select(db.categories)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (r == null) return null;
    return {'kind': r.kind, 'name': r.name, 'icon': r.icon, 'color': r.color};
  }

  @override
  Future<void> applyServerRecord(Map<String, dynamic> r) => db.into(db.categories).insertOnConflictUpdate(
        CategoriesCompanion(
          id: Value(r['id'] as String),
          kind: Value(r['kind'] as String),
          name: Value(r['name'] as String),
          icon: Value(r['icon'] as String?),
          color: Value(r['color'] as String?),
          isSystem: Value((r['is_system'] as bool?) ?? false),
          updatedAt: Value(r['updated_at'] as String?),
          clientUpdatedAt: Value(r['client_updated_at'] as String),
          deletedAt: Value(r['deleted_at'] as String?),
        ),
      );

  @override
  Future<void> markSynced(String id, String updatedAt) =>
      (db.update(db.categories)..where((t) => t.id.equals(id))).write(CategoriesCompanion(updatedAt: Value(updatedAt)));

  @override
  Future<void> removeLocal(String id) => (db.delete(db.categories)..where((t) => t.id.equals(id))).go();
}

class AccountsSync extends SyncTable {
  const AccountsSync(super.db);

  @override
  String get entity => 'accounts';

  @override
  Future<Map<String, dynamic>?> dataFor(String id) async {
    final r = await (db.select(db.accounts)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (r == null) return null;
    return {
      'type': r.type,
      'bank_id': r.bankId,
      'name': r.name,
      'card_type': r.cardType,
      'initial_balance': Money(r.initialBalanceCents).toApiString(),
    };
  }

  @override
  Future<void> applyServerRecord(Map<String, dynamic> r) => db.into(db.accounts).insertOnConflictUpdate(
        AccountsCompanion(
          id: Value(r['id'] as String),
          type: Value(r['type'] as String),
          bankId: Value(r['bank_id'] as String?),
          name: Value(r['name'] as String),
          cardType: Value(r['card_type'] as String?),
          initialBalanceCents: Value(Money.parse(r['initial_balance'].toString()).cents),
          updatedAt: Value(r['updated_at'] as String?),
          clientUpdatedAt: Value(r['client_updated_at'] as String),
          deletedAt: Value(r['deleted_at'] as String?),
        ),
      );

  @override
  Future<void> markSynced(String id, String updatedAt) =>
      (db.update(db.accounts)..where((t) => t.id.equals(id))).write(AccountsCompanion(updatedAt: Value(updatedAt)));

  @override
  Future<void> removeLocal(String id) => (db.delete(db.accounts)..where((t) => t.id.equals(id))).go();
}

class TransactionsSync extends SyncTable {
  const TransactionsSync(super.db);

  @override
  String get entity => 'transactions';

  @override
  Future<Map<String, dynamic>?> dataFor(String id) async {
    final r = await (db.select(db.transactions)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (r == null) return null;
    return {
      'type': r.type,
      'amount': Money(r.amountCents).toApiString(),
      'account_id': r.accountId,
      'category_id': r.categoryId,
      'occurred_on': r.occurredOn,
      'description': r.description,
      'counterparty': r.counterparty,
    };
  }

  @override
  Future<void> applyServerRecord(Map<String, dynamic> r) => db.into(db.transactions).insertOnConflictUpdate(
        TransactionsCompanion(
          id: Value(r['id'] as String),
          type: Value(r['type'] as String),
          amountCents: Value(Money.parse(r['amount'].toString()).cents),
          accountId: Value(r['account_id'] as String),
          categoryId: Value(r['category_id'] as String),
          occurredOn: Value(r['occurred_on'] as String),
          description: Value(r['description'] as String?),
          counterparty: Value(r['counterparty'] as String?),
          updatedAt: Value(r['updated_at'] as String?),
          clientUpdatedAt: Value(r['client_updated_at'] as String),
          deletedAt: Value(r['deleted_at'] as String?),
        ),
      );

  @override
  Future<void> markSynced(String id, String updatedAt) =>
      (db.update(db.transactions)..where((t) => t.id.equals(id))).write(TransactionsCompanion(updatedAt: Value(updatedAt)));

  @override
  Future<void> removeLocal(String id) => (db.delete(db.transactions)..where((t) => t.id.equals(id))).go();
}
