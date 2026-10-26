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

// ---------- Fase 2 ----------

class LoansSync extends SyncTable {
  const LoansSync(super.db);

  @override
  String get entity => 'loans';

  @override
  Future<Map<String, dynamic>?> dataFor(String id) async {
    final r = await (db.select(db.loans)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (r == null) return null;
    return {
      'person_name': r.personName,
      'direction': r.direction,
      'principal': Money(r.principalCents).toApiString(),
      'due_date': r.dueDate,
      'status': r.status,
      'notes': r.notes,
    };
  }

  @override
  Future<void> applyServerRecord(Map<String, dynamic> r) => db.into(db.loans).insertOnConflictUpdate(
        LoansCompanion(
          id: Value(r['id'] as String),
          personName: Value(r['person_name'] as String),
          direction: Value(r['direction'] as String),
          principalCents: Value(Money.parse(r['principal'].toString()).cents),
          dueDate: Value(r['due_date'] as String?),
          status: Value(r['status'] as String),
          notes: Value(r['notes'] as String?),
          updatedAt: Value(r['updated_at'] as String?),
          clientUpdatedAt: Value(r['client_updated_at'] as String),
          deletedAt: Value(r['deleted_at'] as String?),
        ),
      );

  @override
  Future<void> markSynced(String id, String updatedAt) =>
      (db.update(db.loans)..where((t) => t.id.equals(id))).write(LoansCompanion(updatedAt: Value(updatedAt)));

  @override
  Future<void> removeLocal(String id) => (db.delete(db.loans)..where((t) => t.id.equals(id))).go();
}

class LoanMovementsSync extends SyncTable {
  const LoanMovementsSync(super.db);

  @override
  String get entity => 'loan_movements';

  @override
  Future<Map<String, dynamic>?> dataFor(String id) async {
    final r = await (db.select(db.loanMovements)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (r == null) return null;
    return {
      'loan_id': r.loanId,
      'kind': r.kind,
      'amount': Money(r.amountCents).toApiString(),
      'occurred_on': r.occurredOn,
      'transaction_id': r.transactionId,
    };
  }

  @override
  Future<void> applyServerRecord(Map<String, dynamic> r) => db.into(db.loanMovements).insertOnConflictUpdate(
        LoanMovementsCompanion(
          id: Value(r['id'] as String),
          loanId: Value(r['loan_id'] as String),
          kind: Value(r['kind'] as String),
          amountCents: Value(Money.parse(r['amount'].toString()).cents),
          occurredOn: Value(r['occurred_on'] as String),
          transactionId: Value(r['transaction_id'] as String?),
          updatedAt: Value(r['updated_at'] as String?),
          clientUpdatedAt: Value(r['client_updated_at'] as String),
          deletedAt: Value(r['deleted_at'] as String?),
        ),
      );

  @override
  Future<void> markSynced(String id, String updatedAt) =>
      (db.update(db.loanMovements)..where((t) => t.id.equals(id))).write(LoanMovementsCompanion(updatedAt: Value(updatedAt)));

  @override
  Future<void> removeLocal(String id) => (db.delete(db.loanMovements)..where((t) => t.id.equals(id))).go();
}

class SubscriptionsSync extends SyncTable {
  const SubscriptionsSync(super.db);

  @override
  String get entity => 'subscriptions';

  @override
  Future<Map<String, dynamic>?> dataFor(String id) async {
    final r = await (db.select(db.subscriptions)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (r == null) return null;
    return {
      'name': r.name,
      'amount': Money(r.amountCents).toApiString(),
      'renewal_date': r.renewalDate,
      'period': r.period,
      'account_id': r.accountId,
      'active': r.active,
    };
  }

  @override
  Future<void> applyServerRecord(Map<String, dynamic> r) => db.into(db.subscriptions).insertOnConflictUpdate(
        SubscriptionsCompanion(
          id: Value(r['id'] as String),
          name: Value(r['name'] as String),
          amountCents: Value(Money.parse(r['amount'].toString()).cents),
          renewalDate: Value(r['renewal_date'] as String),
          period: Value(r['period'] as String),
          accountId: Value(r['account_id'] as String?),
          active: Value(r['active'] as bool),
          updatedAt: Value(r['updated_at'] as String?),
          clientUpdatedAt: Value(r['client_updated_at'] as String),
          deletedAt: Value(r['deleted_at'] as String?),
        ),
      );

  @override
  Future<void> markSynced(String id, String updatedAt) =>
      (db.update(db.subscriptions)..where((t) => t.id.equals(id))).write(SubscriptionsCompanion(updatedAt: Value(updatedAt)));

  @override
  Future<void> removeLocal(String id) => (db.delete(db.subscriptions)..where((t) => t.id.equals(id))).go();
}

class CreditCardsSync extends SyncTable {
  const CreditCardsSync(super.db);

  @override
  String get entity => 'credit_cards';

  @override
  Future<Map<String, dynamic>?> dataFor(String id) async {
    final r = await (db.select(db.creditCards)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (r == null) return null;
    return {
      'bank_id': r.bankId,
      'name': r.name,
      'pending_balance': Money(r.pendingBalanceCents).toApiString(),
      'due_date': r.dueDate,
    };
  }

  @override
  Future<void> applyServerRecord(Map<String, dynamic> r) => db.into(db.creditCards).insertOnConflictUpdate(
        CreditCardsCompanion(
          id: Value(r['id'] as String),
          bankId: Value(r['bank_id'] as String?),
          name: Value(r['name'] as String),
          pendingBalanceCents: Value(Money.parse(r['pending_balance'].toString()).cents),
          dueDate: Value(r['due_date'] as String?),
          updatedAt: Value(r['updated_at'] as String?),
          clientUpdatedAt: Value(r['client_updated_at'] as String),
          deletedAt: Value(r['deleted_at'] as String?),
        ),
      );

  @override
  Future<void> markSynced(String id, String updatedAt) =>
      (db.update(db.creditCards)..where((t) => t.id.equals(id))).write(CreditCardsCompanion(updatedAt: Value(updatedAt)));

  @override
  Future<void> removeLocal(String id) => (db.delete(db.creditCards)..where((t) => t.id.equals(id))).go();
}

class CreditCardPaymentsSync extends SyncTable {
  const CreditCardPaymentsSync(super.db);

  @override
  String get entity => 'credit_card_payments';

  @override
  Future<Map<String, dynamic>?> dataFor(String id) async {
    final r = await (db.select(db.creditCardPayments)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (r == null) return null;
    return {
      'credit_card_id': r.creditCardId,
      'account_id': r.accountId,
      'transaction_id': r.transactionId,
      'amount': Money(r.amountCents).toApiString(),
      'paid_on': r.paidOn,
    };
  }

  @override
  Future<void> applyServerRecord(Map<String, dynamic> r) => db.into(db.creditCardPayments).insertOnConflictUpdate(
        CreditCardPaymentsCompanion(
          id: Value(r['id'] as String),
          creditCardId: Value(r['credit_card_id'] as String),
          accountId: Value(r['account_id'] as String?),
          transactionId: Value(r['transaction_id'] as String?),
          amountCents: Value(Money.parse(r['amount'].toString()).cents),
          paidOn: Value(r['paid_on'] as String),
          updatedAt: Value(r['updated_at'] as String?),
          clientUpdatedAt: Value(r['client_updated_at'] as String),
          deletedAt: Value(r['deleted_at'] as String?),
        ),
      );

  @override
  Future<void> markSynced(String id, String updatedAt) => (db.update(db.creditCardPayments)..where((t) => t.id.equals(id)))
      .write(CreditCardPaymentsCompanion(updatedAt: Value(updatedAt)));

  @override
  Future<void> removeLocal(String id) => (db.delete(db.creditCardPayments)..where((t) => t.id.equals(id))).go();
}

class BudgetsSync extends SyncTable {
  const BudgetsSync(super.db);

  @override
  String get entity => 'budgets';

  @override
  Future<Map<String, dynamic>?> dataFor(String id) async {
    final r = await (db.select(db.budgets)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (r == null) return null;
    return {
      'category_id': r.categoryId,
      'monthly_limit': Money(r.monthlyLimitCents).toApiString(),
      'alert_percent': r.alertPercent,
    };
  }

  @override
  Future<void> applyServerRecord(Map<String, dynamic> r) => db.into(db.budgets).insertOnConflictUpdate(
        BudgetsCompanion(
          id: Value(r['id'] as String),
          categoryId: Value(r['category_id'] as String),
          monthlyLimitCents: Value(Money.parse(r['monthly_limit'].toString()).cents),
          alertPercent: Value(r['alert_percent'] as int),
          updatedAt: Value(r['updated_at'] as String?),
          clientUpdatedAt: Value(r['client_updated_at'] as String),
          deletedAt: Value(r['deleted_at'] as String?),
        ),
      );

  @override
  Future<void> markSynced(String id, String updatedAt) =>
      (db.update(db.budgets)..where((t) => t.id.equals(id))).write(BudgetsCompanion(updatedAt: Value(updatedAt)));

  @override
  Future<void> removeLocal(String id) => (db.delete(db.budgets)..where((t) => t.id.equals(id))).go();
}

/// Todas las tablas sincronizables, en el orden de [syncEntities].
List<SyncTable> allSyncTables(AppDatabase db) => [
      CategoriesSync(db),
      AccountsSync(db),
      LoansSync(db),
      CreditCardsSync(db),
      TransactionsSync(db),
      SubscriptionsSync(db),
      LoanMovementsSync(db),
      CreditCardPaymentsSync(db),
      BudgetsSync(db),
    ];
