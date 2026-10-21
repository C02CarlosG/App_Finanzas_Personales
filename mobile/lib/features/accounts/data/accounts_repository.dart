import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/data/validation_exception.dart';
import '../../../core/db/app_database.dart';
import '../../../core/db/local_store.dart';
import '../../../core/money/money.dart';

/// Altas, ediciones y bajas de cuentas (banco o efectivo). Las reglas espejan las del servidor
/// para que un cambio válido aquí casi nunca se rechace al sincronizar.
class AccountsRepository {
  AccountsRepository(this._store, {String Function()? newId}) : _newId = newId ?? (() => const Uuid().v4());

  final LocalStore _store;
  final String Function() _newId;
  AppDatabase get _db => _store.db;

  static const _maxCents = 99999999999999; // 12 enteros + 2 decimales, como NUMERIC(14,2)

  Future<String> createBankAccount({
    required String bankId,
    String? name,
    String? cardType,
    Money initialBalance = Money.zero,
  }) async {
    final bank = await (_db.select(_db.banks)..where((b) => b.id.equals(bankId) & b.deletedAt.isNull())).getSingleOrNull();
    if (bank == null) throw const ValidationException('Elige un banco de la lista');
    final id = _newId();
    await _store.saveAccount(
      id: id,
      type: 'banco',
      bankId: bankId,
      name: _validName(name, fallback: bank.name),
      cardType: _validCardType(cardType),
      initialBalance: _validBalance(initialBalance),
    );
    return id;
  }

  Future<String> createCashAccount({String? name, Money initialBalance = Money.zero}) async {
    final id = _newId();
    await _store.saveAccount(
      id: id,
      type: 'efectivo',
      name: _validName(name, fallback: 'Efectivo'),
      initialBalance: _validBalance(initialBalance),
    );
    return id;
  }

  /// El tipo (banco/efectivo) y el banco no cambian (el servidor los trata como inmutables).
  Future<void> update(String id, {required String name, String? cardType, required Money initialBalance}) async {
    final row = await _find(id);
    await _store.saveAccount(
      id: id,
      type: row.type,
      bankId: row.bankId,
      name: _validName(name),
      cardType: row.type == 'banco' ? _validCardType(cardType) : null,
      initialBalance: _validBalance(initialBalance),
    );
  }

  Future<void> delete(String id) async {
    await _find(id);
    final used = await (_db.select(_db.transactions)
          ..where((t) => t.accountId.equals(id) & t.deletedAt.isNull())
          ..limit(1))
        .get();
    if (used.isNotEmpty) {
      throw const ValidationException('Esta cuenta tiene movimientos. Elimínalos o muévelos a otra cuenta primero.');
    }
    await _store.delete('accounts', id);
  }

  Future<AccountRow> _find(String id) async {
    final row = await (_db.select(_db.accounts)..where((a) => a.id.equals(id) & a.deletedAt.isNull())).getSingleOrNull();
    if (row == null) throw const ValidationException('La cuenta ya no existe');
    return row;
  }

  String _validName(String? raw, {String? fallback}) {
    final name = (raw ?? '').trim();
    if (name.isEmpty) {
      if (fallback != null) return fallback;
      throw const ValidationException('Escribe un nombre');
    }
    if (name.length > 100) throw const ValidationException('El nombre es demasiado largo (máx. 100)');
    return name;
  }

  String? _validCardType(String? type) {
    if (type == null) return null;
    if (type != 'debito' && type != 'credito') throw const ValidationException('Tipo de tarjeta inválido');
    return type;
  }

  Money _validBalance(Money m) {
    if (m.cents.abs() > _maxCents) throw const ValidationException('El monto es demasiado grande');
    return m;
  }
}
