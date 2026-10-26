import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/data/system_categories.dart';
import '../../../core/data/validation_exception.dart';
import '../../../core/db/app_database.dart';
import '../../../core/db/local_store.dart';
import '../../../core/format/dates.dart';
import '../../../core/money/money.dart';

/// Tarjetas de crédito (spec 4.4): saldo pendiente, vencimiento y registro de pagos. El saldo pendiente
/// lo captura el usuario (según su estado de cuenta); cada pago lo reduce y borrarlo lo restituye.
/// Un pago mueve dinero: crea el gasto "Pago de tarjeta" en la cuenta elegida.
class CreditCardsRepository {
  CreditCardsRepository(this._store, {String Function()? newId, DateTime Function()? now})
      : _newId = newId ?? (() => const Uuid().v4()),
        _now = now ?? DateTime.now;

  final LocalStore _store;
  final String Function() _newId;
  final DateTime Function() _now;
  AppDatabase get _db => _store.db;

  static const _maxCents = 99999999999999;

  Future<String> create({required String name, String? bankId, Money pendingBalance = Money.zero, String? dueDate}) async {
    final id = _newId();
    await _store.saveCreditCard(
      id: id,
      bankId: await _validBank(bankId),
      name: _validName(name),
      pendingBalance: _validBalance(pendingBalance),
      dueDate: _validOptionalDate(dueDate),
    );
    return id;
  }

  /// Corrige el saldo pendiente (p. ej. al llegar el estado de cuenta) o cualquier otro dato.
  Future<void> update(String id, {required String name, String? bankId, required Money pendingBalance, String? dueDate}) async {
    final row = await _find(id);
    await _store.saveCreditCard(
      id: id,
      bankId: bankId == row.bankId ? bankId : await _validBank(bankId),
      name: _validName(name),
      pendingBalance: _validBalance(pendingBalance),
      dueDate: _validOptionalDate(dueDate),
    );
  }

  /// Registra un pago: gasto en [accountId], pago en el historial y saldo pendiente menor.
  /// No puede exceder el saldo pendiente (si cambió, primero se actualiza el saldo de la tarjeta).
  Future<void> addPayment(String cardId, {required Money amount, required String accountId, String? paidOn}) async {
    final card = await _find(cardId);
    final paid = amount;
    if (paid.cents <= 0) throw const ValidationException('El monto debe ser mayor a 0');
    if (paid.cents > card.pendingBalanceCents) {
      throw ValidationException('El pago excede el saldo pendiente (${Money(card.pendingBalanceCents).format()}). '
          'Si el saldo cambió, actualízalo primero en la tarjeta.');
    }
    final date = _validDate(paidOn ?? isoDate(_now()));
    final account = await (_db.select(_db.accounts)..where((a) => a.id.equals(accountId) & a.deletedAt.isNull())).getSingleOrNull();
    if (account == null) throw const ValidationException('Elige la cuenta desde la que pagas');
    final categoryId = await SystemCategory.idOf(_db, SystemCategory.cardPayment);

    await _db.transaction(() async {
      final txId = _newId();
      await _store.saveTransaction(
        id: txId,
        type: 'expense',
        amount: paid,
        accountId: accountId,
        categoryId: categoryId,
        occurredOn: date,
        description: 'Pago de tarjeta ${card.name}',
      );
      await _store.saveCreditCardPayment(
        id: _newId(),
        creditCardId: cardId,
        accountId: accountId,
        transactionId: txId,
        amount: paid,
        paidOn: date,
      );
      await _saveBalance(card, Money(card.pendingBalanceCents - paid.cents));
    });
  }

  /// Deshace un pago: lo quita, borra su gasto y devuelve el monto al saldo pendiente.
  Future<void> deletePayment(String paymentId) async {
    final payment = await (_db.select(_db.creditCardPayments)..where((p) => p.id.equals(paymentId) & p.deletedAt.isNull())).getSingleOrNull();
    if (payment == null) throw const ValidationException('El pago ya no existe');
    final card = await _find(payment.creditCardId);
    await _db.transaction(() async {
      await _store.delete('credit_card_payments', paymentId); // primero el hijo (ver LoansRepository.deleteMovement)
      if (payment.transactionId != null) await _store.delete('transactions', payment.transactionId!);
      await _saveBalance(card, Money(card.pendingBalanceCents + payment.amountCents));
    });
  }

  /// Elimina la tarjeta y su historial de pagos. Los gastos que ya movieron dinero se conservan.
  Future<void> delete(String cardId) async {
    await _find(cardId);
    final payments = await (_db.select(_db.creditCardPayments)..where((p) => p.creditCardId.equals(cardId) & p.deletedAt.isNull())).get();
    await _db.transaction(() async {
      for (final p in payments) {
        await _store.delete('credit_card_payments', p.id);
      }
      await _store.delete('credit_cards', cardId);
    });
  }

  Future<CreditCardRow> _find(String id) async {
    final row = await (_db.select(_db.creditCards)..where((c) => c.id.equals(id) & c.deletedAt.isNull())).getSingleOrNull();
    if (row == null) throw const ValidationException('La tarjeta ya no existe');
    return row;
  }

  Future<void> _saveBalance(CreditCardRow card, Money balance) => _store.saveCreditCard(
        id: card.id,
        bankId: card.bankId,
        name: card.name,
        pendingBalance: balance,
        dueDate: card.dueDate,
      );

  String _validName(String raw) {
    final name = raw.trim();
    if (name.isEmpty) throw const ValidationException('Escribe el nombre de la tarjeta');
    if (name.length > 100) throw const ValidationException('El nombre es demasiado largo (máx. 100)');
    return name;
  }

  Money _validBalance(Money m) {
    if (m.cents < 0) throw const ValidationException('El saldo pendiente no puede ser negativo');
    if (m.cents > _maxCents) throw const ValidationException('El monto es demasiado grande');
    return m;
  }

  String _validDate(String iso) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(iso)) throw const ValidationException('Fecha inválida');
    return iso;
  }

  String? _validOptionalDate(String? iso) => (iso == null || iso.isEmpty) ? null : _validDate(iso);

  Future<String?> _validBank(String? bankId) async {
    if (bankId == null) return null;
    final bank = await (_db.select(_db.banks)..where((b) => b.id.equals(bankId) & b.deletedAt.isNull())).getSingleOrNull();
    if (bank == null) throw const ValidationException('Elige un banco de la lista');
    return bankId;
  }
}
