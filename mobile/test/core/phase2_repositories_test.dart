import 'package:finanzas_personales/core/data/validation_exception.dart';
import 'package:finanzas_personales/core/db/queries.dart';
import 'package:finanzas_personales/core/db/queries_fase2.dart';
import 'package:finanzas_personales/core/format/dates.dart';
import 'package:finanzas_personales/core/money/money.dart';
import 'package:finanzas_personales/features/accounts/data/accounts_repository.dart';
import 'package:finanzas_personales/features/cards/data/credit_cards_repository.dart';
import 'package:finanzas_personales/features/loans/data/loans_repository.dart';
import 'package:finanzas_personales/features/subscriptions/data/subscriptions_repository.dart';
import 'package:finanzas_personales/features/transactions/data/transactions_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/catalog.dart';
import '../sync/support.dart';

void main() {
  late Harness h;
  late LoansRepository loans;
  late CreditCardsRepository cards;
  late SubscriptionsRepository subs;
  late TransactionsRepository txs;
  final today = DateTime(2026, 10, 20);

  setUp(() async {
    h = Harness();
    await seedCatalog(h.db);
    await seedPhase2Categories(h.db);
    loans = LoansRepository(h.store, now: () => today);
    cards = CreditCardsRepository(h.store, now: () => today);
    subs = SubscriptionsRepository(h.store);
    txs = TransactionsRepository(h.store);
    await h.store.saveAccount(id: 'bbva', type: 'banco', bankId: Catalog.bbva, name: 'Nómina', initialBalance: Money.parse('1000'));
    await h.store.saveAccount(id: 'cash', type: 'efectivo', name: 'Efectivo', initialBalance: Money.parse('200'));
  });
  tearDown(() => h.close());

  Future<Money> balance(String accountId) async => (await h.db.watchAccounts().first).firstWhere((a) => a.id == accountId).balance;
  Future<LoanView> loan(String id) async => (await h.db.findLoan(id))!;
  Future<List<TransactionView>> allTx() => h.db.watchTransactions(const TransactionFilter()).first;
  Future<List<String>> outboxEntities() async => [for (final e in await h.outbox()) e.entity];

  group('préstamos', () {
    test('el pendiente se deriva: original + aumentos − abonos', () async {
      final id = await loans.create(personName: ' Luis Pérez ', direction: 'owed_to_me', principal: Money.parse('500'));
      var v = await loan(id);
      expect([v.personName, v.total.cents, v.remaining.cents, v.status], ['Luis Pérez', 50000, 50000, 'active']);

      await loans.addIncrease(id, amount: Money.parse('200'));
      await loans.addPayment(id, amount: Money.parse('300'), accountId: 'bbva');
      v = await loan(id);
      expect([v.principal.cents, v.increases.cents, v.payments.cents, v.total.cents, v.remaining.cents], [50000, 20000, 30000, 70000, 40000]);
      expect(v.isPaid, isFalse);
    });

    test('cobrar a quien te debe es un ingreso "Préstamo cobrado" con la persona, ligado al abono', () async {
      final id = await loans.create(personName: 'Luis Pérez', direction: 'owed_to_me', principal: Money.parse('500'));
      await loans.addPayment(id, amount: Money.parse('150'), accountId: 'bbva', occurredOn: '2026-10-18');

      final tx = (await allTx()).single;
      expect([tx.type, tx.amount.cents, tx.categoryId, tx.counterparty, tx.accountId, tx.occurredOn], ['income', 15000, Catalog.prestamoCobrado, 'Luis Pérez', 'bbva', '2026-10-18']);
      expect((await balance('bbva')).cents, 115000); // 1000 + 150
      final movement = (await h.db.watchLoanMovements(id).first).single;
      expect([movement.kind, movement.amount.cents, movement.transactionId, movement.accountName], ['payment', 15000, tx.id, 'Nómina']);
    });

    test('pagar lo que debes es un gasto "Pago de préstamo" y baja el saldo de la cuenta', () async {
      final id = await loans.create(personName: 'Banco de mi tío', direction: 'i_owe', principal: Money.parse('1000'));
      await loans.addPayment(id, amount: Money.parse('250'), accountId: 'cash');
      final tx = (await allTx()).single;
      expect([tx.type, tx.categoryId, tx.counterparty], ['expense', Catalog.pagoPrestamo, 'Banco de mi tío']);
      expect((await balance('cash')).cents, -5000); // 200 − 250
    });

    test('al llegar el pendiente a cero queda pagado; no admite abonos de más ni sobre un préstamo pagado', () async {
      final id = await loans.create(personName: 'Ana', direction: 'owed_to_me', principal: Money.parse('100'));
      await expectLater(loans.addPayment(id, amount: Money.parse('100.01'), accountId: 'bbva'), throwsA(isA<ValidationException>()));
      await loans.addPayment(id, amount: Money.parse('60'), accountId: 'bbva');
      expect((await loan(id)).isPaid, isFalse);
      await loans.addPayment(id, amount: Money.parse('40'), accountId: 'bbva');
      expect((await loan(id)).isPaid, isTrue);
      await expectLater(loans.addPayment(id, amount: Money.parse('1'), accountId: 'bbva'), throwsA(isA<ValidationException>()));
      expect((await balance('bbva')).cents, 110000);
    });

    test('un aumento reactiva un préstamo pagado y no mueve saldos', () async {
      final id = await loans.create(personName: 'Ana', direction: 'owed_to_me', principal: Money.parse('100'));
      await loans.addPayment(id, amount: Money.parse('100'), accountId: 'bbva');
      expect((await loan(id)).isPaid, isTrue);
      final before = (await balance('bbva')).cents;
      await loans.addIncrease(id, amount: Money.parse('50'));
      final v = await loan(id);
      expect([v.isPaid, v.remaining.cents], [false, 5000]);
      expect((await balance('bbva')).cents, before);
      expect((await allTx()).length, 1); // solo el cobro original
    });

    test('marcar como pagado con saldo pendiente registra un último abono en la cuenta elegida', () async {
      final id = await loans.create(personName: 'Ana', direction: 'owed_to_me', principal: Money.parse('300'));
      await loans.addPayment(id, amount: Money.parse('100'), accountId: 'bbva');
      await expectLater(loans.markPaid(id), throwsA(isA<ValidationException>())); // falta la cuenta
      await loans.markPaid(id, accountId: 'cash');
      final v = await loan(id);
      expect([v.isPaid, v.payments.cents, v.remaining.cents], [true, 30000, 0]);
      expect((await balance('cash')).cents, 40000); // 200 + 200 restantes
      expect((await allTx()).length, 2);
    });

    test('marcar como pagado sin pendiente (p. ej. ya liquidado) no pide cuenta ni crea movimientos', () async {
      final id = await loans.create(personName: 'Beto', direction: 'i_owe', principal: Money.parse('100'));
      await loans.addPayment(id, amount: Money.parse('100'), accountId: 'cash'); // queda pagado
      await loans.markPaid(id); // idempotente: no exige cuenta ni crea otro abono
      expect((await allTx()).length, 1);
      expect((await h.db.watchLoanMovements(id).first).length, 1);
    });

    test('deshacer un abono borra su movimiento y su transacción, devuelve el saldo y reactiva el préstamo', () async {
      final id = await loans.create(personName: 'Ana', direction: 'owed_to_me', principal: Money.parse('100'));
      await loans.addPayment(id, amount: Money.parse('100'), accountId: 'bbva');
      final movement = (await h.db.watchLoanMovements(id).first).single;
      await loans.deleteMovement(movement.id);
      expect(await allTx(), isEmpty);
      expect((await balance('bbva')).cents, 100000);
      final v = await loan(id);
      expect([v.isPaid, v.remaining.cents], [false, 10000]);
      expect(await h.db.watchLoanMovements(id).first, isEmpty);
    });

    test('eliminar un préstamo borra su historial pero conserva los ingresos/gastos ya registrados', () async {
      final id = await loans.create(personName: 'Ana', direction: 'owed_to_me', principal: Money.parse('100'));
      await loans.addPayment(id, amount: Money.parse('30'), accountId: 'bbva');
      await loans.delete(id);
      expect(await h.db.findLoan(id), isNull);
      expect(await h.db.watchLoans().first, isEmpty);
      expect((await allTx()).length, 1);
      expect((await balance('bbva')).cents, 103000);
      // el movimiento ya no ata a la transacción: ahora se puede editar/eliminar normalmente
      await txs.delete((await allTx()).single.id);
      expect((await balance('bbva')).cents, 100000);
    });

    test('la transacción de un abono no se edita ni se elimina desde Movimientos', () async {
      final id = await loans.create(personName: 'Ana', direction: 'owed_to_me', principal: Money.parse('100'));
      await loans.addPayment(id, amount: Money.parse('30'), accountId: 'bbva');
      final tx = (await allTx()).single;
      await expectLater(txs.delete(tx.id), throwsA(isA<ValidationException>()));
      await expectLater(
        txs.update(tx.id, type: 'income', amount: Money.parse('99'), accountId: 'bbva', categoryId: Catalog.prestamoCobrado, occurredOn: '2026-10-20'),
        throwsA(isA<ValidationException>().having((e) => e.message, 'message', contains('Préstamos'))),
      );
      expect((await balance('bbva')).cents, 103000);
    });

    test('sin la categoría de sistema (aún sin sincronizar) pide sincronizar y no deja nada a medias', () async {
      await h.db.customStatement("DELETE FROM categories WHERE id = '${Catalog.pagoPrestamo}'");
      final id = await loans.create(personName: 'Banco', direction: 'i_owe', principal: Money.parse('100'));
      await expectLater(
        loans.addPayment(id, amount: Money.parse('10'), accountId: 'cash'),
        throwsA(isA<ValidationException>().having((e) => e.message, 'message', contains('sincronizar'))),
      );
      expect(await allTx(), isEmpty);
      expect(await h.db.watchLoanMovements(id).first, isEmpty);
    });

    test('validaciones: nombre, monto, sentido, fecha, cuenta; el monto original no baja de lo ya abonado', () async {
      Future<void> bad(Future<void> f) => expectLater(f, throwsA(isA<ValidationException>()));
      await bad(loans.create(personName: '  ', direction: 'owed_to_me', principal: Money.parse('10')));
      await bad(loans.create(personName: 'X', direction: 'otro', principal: Money.parse('10')));
      await bad(loans.create(personName: 'X', direction: 'i_owe', principal: Money.zero));
      await bad(loans.create(personName: 'X', direction: 'i_owe', principal: Money.parse('10'), dueDate: '31/12/2026'));
      await bad(loans.create(personName: 'X' * 101, direction: 'i_owe', principal: Money.parse('10')));
      final id = await loans.create(personName: 'Ana', direction: 'owed_to_me', principal: Money.parse('100'), dueDate: '2026-12-31', notes: '  ');
      expect((await loan(id)).notes, isNull);
      await bad(loans.addPayment(id, amount: Money.parse('10'), accountId: 'no-existe'));
      await bad(loans.addPayment(id, amount: Money.zero, accountId: 'bbva'));
      await bad(loans.addPayment('no-existe', amount: Money.parse('10'), accountId: 'bbva'));
      await loans.addPayment(id, amount: Money.parse('80'), accountId: 'bbva');
      await bad(loans.update(id, personName: 'Ana', principal: Money.parse('70')));
      await loans.update(id, personName: 'Ana M.', principal: Money.parse('80'), dueDate: null, notes: 'ok');
      final v = await loan(id);
      expect([v.personName, v.total.cents, v.dueDate, v.notes], ['Ana M.', 8000, null, 'ok']);
      expect(v.direction, 'owed_to_me'); // el sentido no cambia
    });

    test('el listado ordena activos por plazo y deja los pagados al final; el resumen separa lo que te deben de lo que debes', () async {
      final a = await loans.create(personName: 'Zeta', direction: 'owed_to_me', principal: Money.parse('100'), dueDate: '2026-12-01');
      final b = await loans.create(personName: 'Beta', direction: 'i_owe', principal: Money.parse('50'));
      final c = await loans.create(personName: 'Alfa', direction: 'owed_to_me', principal: Money.parse('10'), dueDate: '2026-11-01');
      final d = await loans.create(personName: 'Pagado', direction: 'owed_to_me', principal: Money.parse('5'));
      await loans.addPayment(d, amount: Money.parse('5'), accountId: 'bbva');
      await loans.addPayment(a, amount: Money.parse('40'), accountId: 'bbva');
      expect([for (final l in await h.db.watchLoans().first) l.id], [c, a, b, d]);
      final s = await h.db.watchLoansSummary().first;
      expect([s.owedToMe.cents, s.iOwe.cents], [6000 + 1000, 5000]);
    });

    test('todo queda en la outbox en orden de dependencia para subirse', () async {
      final id = await loans.create(personName: 'Ana', direction: 'owed_to_me', principal: Money.parse('100'));
      await loans.addPayment(id, amount: Money.parse('100'), accountId: 'bbva');
      expect((await outboxEntities()).toSet(), {'accounts', 'loans', 'transactions', 'loan_movements'});
    });
  });

  group('tarjetas de crédito', () {
    test('un pago es un gasto "Pago de tarjeta", baja el saldo de la cuenta y el pendiente de la tarjeta', () async {
      final id = await cards.create(name: 'BBVA Azul', bankId: Catalog.bbva, pendingBalance: Money.parse('2500.50'), dueDate: '2026-11-10');
      await cards.addPayment(id, amount: Money.parse('500'), accountId: 'bbva', paidOn: '2026-10-19');
      final card = (await h.db.findCreditCard(id))!;
      expect([card.pendingBalance.cents, card.bankName, card.dueDate], [200050, 'BBVA México', '2026-11-10']);
      final tx = (await allTx()).single;
      expect([tx.type, tx.categoryId, tx.amount.cents, tx.description, tx.occurredOn], ['expense', Catalog.pagoTarjeta, 50000, 'Pago de tarjeta BBVA Azul', '2026-10-19']);
      expect((await balance('bbva')).cents, 50000);
      final payment = (await h.db.watchCardPayments(id).first).single;
      expect([payment.amount.cents, payment.transactionId, payment.accountName], [50000, tx.id, 'Nómina']);
    });

    test('un pago no puede exceder el saldo pendiente ni ser cero; deshacerlo restituye saldo y gasto', () async {
      final id = await cards.create(name: 'Nu', pendingBalance: Money.parse('100'));
      await expectLater(cards.addPayment(id, amount: Money.parse('100.01'), accountId: 'bbva'), throwsA(isA<ValidationException>()));
      await expectLater(cards.addPayment(id, amount: Money.zero, accountId: 'bbva'), throwsA(isA<ValidationException>()));
      await cards.addPayment(id, amount: Money.parse('100'), accountId: 'bbva');
      expect((await h.db.findCreditCard(id))!.pendingBalance.cents, 0);
      final payment = (await h.db.watchCardPayments(id).first).single;
      await cards.deletePayment(payment.id);
      expect((await h.db.findCreditCard(id))!.pendingBalance.cents, 10000);
      expect(await allTx(), isEmpty);
      expect((await balance('bbva')).cents, 100000);
    });

    test('el gasto de un pago no se edita desde Movimientos; eliminar la tarjeta lo conserva', () async {
      final id = await cards.create(name: 'Nu', pendingBalance: Money.parse('100'));
      await cards.addPayment(id, amount: Money.parse('40'), accountId: 'bbva');
      final tx = (await allTx()).single;
      await expectLater(txs.delete(tx.id), throwsA(isA<ValidationException>().having((e) => e.message, 'message', contains('tarjeta'))));
      await cards.delete(id);
      expect(await h.db.watchCreditCards().first, isEmpty);
      await txs.delete(tx.id); // ya sin pago que lo respalde
      expect(await allTx(), isEmpty);
    });

    test('validaciones y edición del saldo', () async {
      Future<void> bad(Future<void> f) => expectLater(f, throwsA(isA<ValidationException>()));
      await bad(cards.create(name: ''));
      await bad(cards.create(name: 'X', pendingBalance: Money.parse('-1')));
      await bad(cards.create(name: 'X', bankId: 'no-existe'));
      await bad(cards.create(name: 'X', dueDate: 'mañana'));
      final id = await cards.create(name: 'Citi', pendingBalance: Money.parse('10'));
      await cards.update(id, name: 'Citibanamex', bankId: 'bank-banamex', pendingBalance: Money.parse('999.99'), dueDate: '2026-12-01');
      final c = (await h.db.findCreditCard(id))!;
      expect([c.name, c.bankName, c.pendingBalance.cents, c.dueDate], ['Citibanamex', 'Banamex', 99999, '2026-12-01']);
    });
  });

  group('suscripciones', () {
    test('alta, edición, pausa y baja', () async {
      final id = await subs.create(name: ' Netflix ', amount: Money.parse('199'), renewalDate: '2026-11-01', accountId: 'bbva');
      var s = (await h.db.findSubscription(id))!;
      expect([s.name, s.amount.cents, s.period, s.active, s.accountName], ['Netflix', 19900, 'monthly', true, 'Nómina']);
      await subs.update(id, name: 'Netflix HD', amount: Money.parse('219'), renewalDate: '2026-11-05', period: 'monthly', accountId: null);
      await subs.setActive(id, false);
      s = (await h.db.findSubscription(id))!;
      expect([s.name, s.amount.cents, s.renewalDate, s.active, s.accountId], ['Netflix HD', 21900, '2026-11-05', false, null]);
      await subs.delete(id);
      expect(await h.db.watchSubscriptions().first, isEmpty);
    });

    test('validaciones', () async {
      Future<void> bad(Future<void> f) => expectLater(f, throwsA(isA<ValidationException>()));
      await bad(subs.create(name: '', amount: Money.parse('10'), renewalDate: '2026-11-01'));
      await bad(subs.create(name: 'X', amount: Money.zero, renewalDate: '2026-11-01'));
      await bad(subs.create(name: 'X', amount: Money.parse('10'), renewalDate: '01-11-2026'));
      await bad(subs.create(name: 'X', amount: Money.parse('10'), renewalDate: '2026-11-01', period: 'daily'));
      await bad(subs.create(name: 'X', amount: Money.parse('10'), renewalDate: '2026-11-01', accountId: 'no-existe'));
    });

    test('una cuenta usada por una suscripción no se elimina', () async {
      final accounts = AccountsRepository(h.store);
      await h.store.saveAccount(id: 'vacia', type: 'efectivo', name: 'Vacía');
      final id = await subs.create(name: 'Spotify', amount: Money.parse('129'), renewalDate: '2026-11-01', accountId: 'vacia');
      await expectLater(accounts.delete('vacia'), throwsA(isA<ValidationException>().having((e) => e.message, 'message', contains('suscripción'))));
      await subs.delete(id);
      await accounts.delete('vacia');
    });

    test('equivalente mensual: semanal × 52/12, anual / 12', () async {
      await subs.create(name: 'Sem', amount: Money.parse('100'), renewalDate: '2026-11-01', period: 'weekly');
      await subs.create(name: 'Anu', amount: Money.parse('1200'), renewalDate: '2026-11-01', period: 'yearly');
      await subs.create(name: 'Men', amount: Money.parse('50'), renewalDate: '2026-11-01');
      final byName = {for (final s in await h.db.watchSubscriptions().first) s.name: s.monthlyEquivalent.cents};
      expect(byName, {'Sem': 43333, 'Anu': 10000, 'Men': 5000});
    });
  });

  group('próxima renovación', () {
    String next(String base, String period, DateTime from) => isoDate(nextRenewal(base, period, from));

    test('fecha futura o de hoy se queda igual', () {
      expect(next('2026-10-25', 'monthly', DateTime(2026, 10, 20)), '2026-10-25');
      expect(next('2026-10-20', 'weekly', DateTime(2026, 10, 20)), '2026-10-20');
    });

    test('mensual: siguiente día del mes; conserva el día original aunque febrero lo acorte', () {
      expect(next('2026-01-15', 'monthly', DateTime(2026, 10, 20)), '2026-11-15');
      expect(next('2026-01-15', 'monthly', DateTime(2026, 10, 15)), '2026-10-15');
      expect(next('2026-01-31', 'monthly', DateTime(2026, 2, 1)), '2026-02-28');
      expect(next('2026-01-31', 'monthly', DateTime(2026, 3, 1)), '2026-03-31');
      expect(next('2024-01-31', 'monthly', DateTime(2024, 2, 10)), '2024-02-29'); // bisiesto
      expect(next('2026-12-20', 'monthly', DateTime(2027, 1, 1)), '2027-01-20');
    });

    test('semanal: múltiplos de 7 días desde la fecha original', () {
      expect(next('2026-10-01', 'weekly', DateTime(2026, 10, 20)), '2026-10-22');
      expect(next('2026-10-01', 'weekly', DateTime(2026, 10, 22)), '2026-10-22');
      expect(next('2026-03-01', 'weekly', DateTime(2026, 11, 2)), '2026-11-08'); // cruza cambios de horario
    });

    test('anual: mismo día y mes; 29 de febrero cae en 28 en años no bisiestos', () {
      expect(next('2025-11-30', 'yearly', DateTime(2026, 10, 20)), '2026-11-30');
      expect(next('2025-10-01', 'yearly', DateTime(2026, 10, 20)), '2027-10-01');
      expect(next('2024-02-29', 'yearly', DateTime(2025, 1, 1)), '2025-02-28');
    });
  });

  group('consultas', () {
    test('un préstamo eliminado en otro dispositivo (tombstone) desaparece de listados y sus movimientos no cuentan', () async {
      final id = await loans.create(personName: 'Ana', direction: 'owed_to_me', principal: Money.parse('100'));
      await loans.addPayment(id, amount: Money.parse('10'), accountId: 'bbva');
      await h.db.customStatement("UPDATE loans SET deleted_at = '2026-10-21T00:00:00.000000Z' WHERE id = '$id'");
      h.db.markTablesUpdated({h.db.loans});
      await Future<void>.delayed(Duration.zero);
      expect(await h.db.watchLoans().first, isEmpty);
      expect((await h.db.watchLoansSummary().first).owedToMe.cents, 0);
    });

    test('orden de pagos de tarjeta: del más reciente al más viejo', () async {
      final id = await cards.create(name: 'Nu', pendingBalance: Money.parse('100'));
      await cards.addPayment(id, amount: Money.parse('10'), accountId: 'bbva', paidOn: '2026-10-01');
      h.advance(const Duration(seconds: 1));
      await cards.addPayment(id, amount: Money.parse('20'), accountId: 'bbva', paidOn: '2026-10-15');
      expect([for (final p in await h.db.watchCardPayments(id).first) p.amount.cents], [2000, 1000]);
    });
  });
}
