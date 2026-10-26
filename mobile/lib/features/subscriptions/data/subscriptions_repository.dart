import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/data/validation_exception.dart';
import '../../../core/data/validators.dart';
import '../../../core/db/app_database.dart';
import '../../../core/db/local_store.dart';
import '../../../core/money/money.dart';

/// Servicios recurrentes (spec 4.4): solo el registro para no olvidar qué se tiene contratado;
/// no genera gastos por sí sola.
class SubscriptionsRepository {
  SubscriptionsRepository(this._store, {String Function()? newId}) : _newId = newId ?? (() => const Uuid().v4());

  final LocalStore _store;
  final String Function() _newId;
  AppDatabase get _db => _store.db;

  static const periods = ['weekly', 'monthly', 'yearly'];

  Future<String> create({
    required String name,
    required Money amount,
    required String renewalDate,
    String period = 'monthly',
    String? accountId,
  }) async {
    final id = _newId();
    await _store.saveSubscription(
      id: id,
      name: _validName(name),
      amount: positiveMoney(amount),
      renewalDate: validIsoDate(renewalDate),
      period: _validPeriod(period),
      accountId: await _validAccount(accountId),
    );
    return id;
  }

  Future<void> update(
    String id, {
    required String name,
    required Money amount,
    required String renewalDate,
    required String period,
    String? accountId,
    bool? active,
  }) async {
    final row = await _find(id);
    await _store.saveSubscription(
      id: id,
      name: _validName(name),
      amount: positiveMoney(amount),
      renewalDate: validIsoDate(renewalDate),
      period: _validPeriod(period),
      // Conservar la cuenta que ya tenía no exige que siga viva (el servidor tampoco lo pide si no cambia).
      accountId: accountId == row.accountId ? accountId : await _validAccount(accountId),
      active: active ?? row.active,
    );
  }

  /// Pausar / cancelar sin perder el registro.
  Future<void> setActive(String id, bool active) async {
    final row = await _find(id);
    await _store.saveSubscription(
      id: id,
      name: row.name,
      amount: Money(row.amountCents),
      renewalDate: row.renewalDate,
      period: row.period,
      accountId: row.accountId,
      active: active,
    );
  }

  Future<void> delete(String id) async {
    await _find(id);
    await _store.delete('subscriptions', id);
  }

  Future<SubscriptionRow> _find(String id) async {
    final row = await (_db.select(_db.subscriptions)..where((s) => s.id.equals(id) & s.deletedAt.isNull())).getSingleOrNull();
    if (row == null) throw const ValidationException('La suscripción ya no existe');
    return row;
  }

  String _validName(String raw) => requiredName(raw, emptyMessage: 'Escribe el nombre del servicio');

  String _validPeriod(String p) {
    if (!periods.contains(p)) throw const ValidationException('Periodicidad inválida');
    return p;
  }

  Future<String?> _validAccount(String? accountId) async {
    if (accountId == null) return null;
    final a = await (_db.select(_db.accounts)..where((x) => x.id.equals(accountId) & x.deletedAt.isNull())).getSingleOrNull();
    if (a == null) throw const ValidationException('La cuenta elegida ya no existe');
    return accountId;
  }
}
