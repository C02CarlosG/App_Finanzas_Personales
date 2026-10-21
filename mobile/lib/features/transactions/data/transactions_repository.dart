import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/data/validation_exception.dart';
import '../../../core/db/app_database.dart';
import '../../../core/db/local_store.dart';
import '../../../core/money/money.dart';

/// Altas, ediciones y bajas de ingresos y gastos.
class TransactionsRepository {
  TransactionsRepository(this._store, {String Function()? newId}) : _newId = newId ?? (() => const Uuid().v4());

  final LocalStore _store;
  final String Function() _newId;
  AppDatabase get _db => _store.db;

  static const _maxCents = 99999999999999;

  Future<String> add({
    required String type,
    required Money amount,
    required String accountId,
    required String categoryId,
    required String occurredOn,
    String? description,
    String? counterparty,
  }) async {
    final id = _newId();
    await _save(
      id: id,
      type: type,
      amount: amount,
      accountId: accountId,
      categoryId: categoryId,
      occurredOn: occurredOn,
      description: description,
      counterparty: counterparty,
    );
    return id;
  }

  Future<void> update(
    String id, {
    required String type,
    required Money amount,
    required String accountId,
    required String categoryId,
    required String occurredOn,
    String? description,
    String? counterparty,
  }) async {
    final exists = await (_db.select(_db.transactions)..where((t) => t.id.equals(id) & t.deletedAt.isNull())).getSingleOrNull();
    if (exists == null) throw const ValidationException('El movimiento ya no existe');
    await _save(
      id: id,
      type: type,
      amount: amount,
      accountId: accountId,
      categoryId: categoryId,
      occurredOn: occurredOn,
      description: description,
      counterparty: counterparty,
    );
  }

  Future<void> delete(String id) => _store.delete('transactions', id);

  Future<void> _save({
    required String id,
    required String type,
    required Money amount,
    required String accountId,
    required String categoryId,
    required String occurredOn,
    String? description,
    String? counterparty,
  }) async {
    if (type != 'income' && type != 'expense') throw const ValidationException('Tipo de movimiento inválido');
    if (amount.cents <= 0) throw const ValidationException('El monto debe ser mayor a 0');
    if (amount.cents > _maxCents) throw const ValidationException('El monto es demasiado grande');
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(occurredOn)) throw const ValidationException('Fecha inválida');

    final account = await (_db.select(_db.accounts)..where((a) => a.id.equals(accountId) & a.deletedAt.isNull())).getSingleOrNull();
    if (account == null) throw const ValidationException('Elige una cuenta');
    final category = await (_db.select(_db.categories)..where((c) => c.id.equals(categoryId) & c.deletedAt.isNull())).getSingleOrNull();
    if (category == null) throw const ValidationException('Elige una categoría');
    if (category.kind != type) throw const ValidationException('La categoría no corresponde al tipo de movimiento');

    final desc = description?.trim();
    final who = counterparty?.trim();
    if (desc != null && desc.length > 500) throw const ValidationException('La descripción es demasiado larga (máx. 500)');
    if (who != null && who.length > 100) throw const ValidationException('El nombre es demasiado largo (máx. 100)');

    await _store.saveTransaction(
      id: id,
      type: type,
      amount: amount,
      accountId: accountId,
      categoryId: categoryId,
      occurredOn: occurredOn,
      description: (desc == null || desc.isEmpty) ? null : desc,
      counterparty: (who == null || who.isEmpty) ? null : who,
    );
  }
}
