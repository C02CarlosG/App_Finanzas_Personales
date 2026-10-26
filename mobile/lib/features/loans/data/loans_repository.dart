import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/data/system_categories.dart';
import '../../../core/data/validation_exception.dart';
import '../../../core/db/app_database.dart';
import '../../../core/db/local_store.dart';
import '../../../core/db/queries_fase2.dart';
import '../../../core/format/dates.dart';
import '../../../core/money/money.dart';

/// Préstamos y deudas (spec 4.5). El saldo se deriva de los movimientos; un abono que mueve dinero
/// crea además su ingreso (cobro) o su gasto (pago) en la cuenta elegida, todo en una transacción local.
class LoansRepository {
  LoansRepository(this._store, {String Function()? newId, DateTime Function()? now})
      : _newId = newId ?? (() => const Uuid().v4()),
        _now = now ?? DateTime.now;

  final LocalStore _store;
  final String Function() _newId;
  final DateTime Function() _now;
  AppDatabase get _db => _store.db;

  static const _maxCents = 99999999999999;

  Future<String> create({
    required String personName,
    required String direction,
    required Money principal,
    String? dueDate,
    String? notes,
  }) async {
    _validDirection(direction);
    final id = _newId();
    await _store.saveLoan(
      id: id,
      personName: _validName(personName),
      direction: direction,
      principal: _validAmount(principal),
      dueDate: _validOptionalDate(dueDate),
      notes: _validNotes(notes),
    );
    return id;
  }

  /// El sentido (le debo / me debe) no cambia: invertiría los abonos ya registrados.
  Future<void> update(String id, {required String personName, required Money principal, String? dueDate, String? notes}) async {
    final loan = await _findRow(id);
    final amount = _validAmount(principal);
    final view = await _view(id);
    final floor = view.payments.cents - view.increases.cents;
    if (amount.cents < floor) {
      throw ValidationException('El monto original no puede ser menor a lo ya abonado (${Money(floor).format()} sin contar aumentos)');
    }
    await _store.saveLoan(
      id: id,
      personName: _validName(personName),
      direction: loan.direction,
      principal: amount,
      dueDate: _validOptionalDate(dueDate),
      status: loan.status,
      notes: _validNotes(notes),
    );
  }

  /// Registra un abono. Si el préstamo es "me debe", es un cobro (ingreso "Préstamo cobrado" con la
  /// persona); si es "le debo", es un pago (gasto "Pago de préstamo"). Mueve el saldo de [accountId].
  /// Al llegar el pendiente a cero el préstamo queda pagado.
  Future<void> addPayment(String loanId, {required Money amount, required String accountId, String? occurredOn}) async {
    final loan = await _findRow(loanId);
    final view = await _view(loanId);
    final paid = _validAmount(amount);
    if (loan.status == 'paid') throw const ValidationException('Este préstamo ya está pagado');
    if (paid.cents > view.remaining.cents) {
      throw ValidationException('El abono excede lo pendiente (${view.remaining.format()})');
    }
    final date = _validDate(occurredOn ?? isoDate(_now()));
    final account = await (_db.select(_db.accounts)..where((a) => a.id.equals(accountId) & a.deletedAt.isNull())).getSingleOrNull();
    if (account == null) throw const ValidationException('Elige la cuenta del abono');

    final collected = !view.iOwe;
    final categoryId = await SystemCategory.idOf(_db, collected ? SystemCategory.loanCollected : SystemCategory.loanPayment);
    await _db.transaction(() async {
      final txId = _newId();
      await _store.saveTransaction(
        id: txId,
        type: collected ? 'income' : 'expense',
        amount: paid,
        accountId: accountId,
        categoryId: categoryId,
        occurredOn: date,
        counterparty: loan.personName,
      );
      await _store.saveLoanMovement(id: _newId(), loanId: loanId, kind: 'payment', amount: paid, occurredOn: date, transactionId: txId);
      if (paid.cents == view.remaining.cents) await _setStatus(loan, 'paid');
    });
  }

  /// Aumenta el monto (la persona presta más). Es un hecho ya ocurrido: no mueve saldos. Reactiva un préstamo pagado.
  Future<void> addIncrease(String loanId, {required Money amount, String? occurredOn}) async {
    final loan = await _findRow(loanId);
    final more = _validAmount(amount);
    final date = _validDate(occurredOn ?? isoDate(_now()));
    await _db.transaction(() async {
      await _store.saveLoanMovement(id: _newId(), loanId: loanId, kind: 'increase', amount: more, occurredOn: date);
      if (loan.status == 'paid') await _setStatus(loan, 'active');
    });
  }

  /// Marca el préstamo como pagado. Si aún queda pendiente se registra por ese saldo un último abono
  /// (así los saldos de las cuentas cuadran), por lo que entonces [accountId] es obligatoria.
  Future<void> markPaid(String loanId, {String? accountId, String? occurredOn}) async {
    final loan = await _findRow(loanId);
    final view = await _view(loanId);
    if (loan.status == 'paid') return;
    if (view.remaining.cents > 0) {
      if (accountId == null) throw const ValidationException('Elige la cuenta del último abono');
      await addPayment(loanId, amount: view.remaining, accountId: accountId, occurredOn: occurredOn);
    } else {
      await _setStatus(loan, 'paid');
    }
  }

  /// Deshace un movimiento (y el ingreso/gasto que generó). Un préstamo pagado que vuelve a tener pendiente se reactiva.
  Future<void> deleteMovement(String movementId) async {
    final movement = await (_db.select(_db.loanMovements)..where((m) => m.id.equals(movementId) & m.deletedAt.isNull())).getSingleOrNull();
    if (movement == null) throw const ValidationException('El movimiento ya no existe');
    final loan = await _findRow(movement.loanId);
    await _db.transaction(() async {
      await _store.delete('loan_movements', movementId); // primero el hijo: el servidor no borra una transacción con movimiento vivo
      if (movement.transactionId != null) await _store.delete('transactions', movement.transactionId!);
      final after = await _view(movement.loanId);
      if (loan.status == 'paid' && after.remaining.cents > 0) await _setStatus(loan, 'active');
    });
  }

  /// Elimina el préstamo y su historial. Los ingresos/gastos que ya movieron dinero se conservan.
  Future<void> delete(String loanId) async {
    await _findRow(loanId);
    final movements = await (_db.select(_db.loanMovements)..where((m) => m.loanId.equals(loanId) & m.deletedAt.isNull())).get();
    await _db.transaction(() async {
      for (final m in movements) {
        await _store.delete('loan_movements', m.id);
      }
      await _store.delete('loans', loanId);
    });
  }

  // ------------------------------------------------------------ helpers

  Future<LoanRow> _findRow(String id) async {
    final row = await (_db.select(_db.loans)..where((l) => l.id.equals(id) & l.deletedAt.isNull())).getSingleOrNull();
    if (row == null) throw const ValidationException('El préstamo ya no existe');
    return row;
  }

  Future<LoanView> _view(String id) async {
    final v = await _db.findLoan(id);
    if (v == null) throw const ValidationException('El préstamo ya no existe');
    return v;
  }

  Future<void> _setStatus(LoanRow loan, String status) => _store.saveLoan(
        id: loan.id,
        personName: loan.personName,
        direction: loan.direction,
        principal: Money(loan.principalCents),
        dueDate: loan.dueDate,
        status: status,
        notes: loan.notes,
      );

  void _validDirection(String d) {
    if (d != 'i_owe' && d != 'owed_to_me') throw const ValidationException('Indica si le debes o te debe');
  }

  String _validName(String raw) {
    final name = raw.trim();
    if (name.isEmpty) throw const ValidationException('Escribe el nombre de la persona');
    if (name.length > 100) throw const ValidationException('El nombre es demasiado largo (máx. 100)');
    return name;
  }

  Money _validAmount(Money m) {
    if (m.cents <= 0) throw const ValidationException('El monto debe ser mayor a 0');
    if (m.cents > _maxCents) throw const ValidationException('El monto es demasiado grande');
    return m;
  }

  String _validDate(String iso) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(iso)) throw const ValidationException('Fecha inválida');
    return iso;
  }

  String? _validOptionalDate(String? iso) => (iso == null || iso.isEmpty) ? null : _validDate(iso);

  String? _validNotes(String? raw) {
    final notes = raw?.trim();
    if (notes == null || notes.isEmpty) return null;
    if (notes.length > 500) throw const ValidationException('Las notas son demasiado largas (máx. 500)');
    return notes;
  }
}
