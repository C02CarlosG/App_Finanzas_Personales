import 'package:finanzas_personales/core/db/queries.dart';
import 'package:finanzas_personales/core/money/money.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/catalog.dart';
import '../sync/support.dart';

void main() {
  late Harness h;
  setUp(() async {
    h = Harness();
    await seedCatalog(h.db);
  });
  tearDown(() => h.close());

  Future<void> tx(String id, String type, String amount, String account, String cat, String date, {String? desc, String? who}) =>
      h.store.saveTransaction(
          id: id, type: type, amount: Money.parse(amount), accountId: account, categoryId: cat, occurredOn: date, description: desc, counterparty: who);

  Future<void> basics() async {
    await h.store.saveAccount(id: 'acc-bbva', type: 'banco', bankId: Catalog.bbva, name: 'BBVA México', cardType: 'debito', initialBalance: Money.parse('1000'));
    await h.store.saveAccount(id: 'acc-cash', type: 'efectivo', name: 'Efectivo', initialBalance: Money.parse('200.50'));
  }

  test('saldo de cuenta = inicial + ingresos − gastos; el total suma todas las cuentas', () async {
    await basics();
    await tx('t1', 'income', '3000', 'acc-bbva', Catalog.salario, '2026-10-01');
    await tx('t2', 'expense', '450.75', 'acc-bbva', Catalog.comida, '2026-10-02');
    await tx('t3', 'expense', '100', 'acc-cash', Catalog.comida, '2026-10-03');
    final accounts = await h.db.watchAccounts().first;
    final byId = {for (final a in accounts) a.id: a};
    expect(byId['acc-bbva']!.balance.toApiString(), '3549.25'); // 1000+3000-450.75
    expect(byId['acc-cash']!.balance.toApiString(), '100.50'); // 200.50-100
    expect(byId['acc-bbva']!.bankName, 'BBVA México');
    expect(byId['acc-bbva']!.logoKey, 'bbva');
    expect(byId['acc-cash']!.isCash, isTrue);
    expect((await h.db.watchTotalBalance().first).toApiString(), '3649.75');
  });

  test('los movimientos eliminados no cuentan en saldos ni listados', () async {
    await basics();
    await tx('t1', 'expense', '100', 'acc-cash', Catalog.comida, '2026-10-03');
    await h.db.watchTotalBalance().first;
    await h.store.delete('transactions', 't1');
    expect((await h.db.watchTotalBalance().first).toApiString(), '1200.50');
    expect(await h.db.watchTransactions(const TransactionFilter()).first, isEmpty);
  });

  test('la lista se ordena por fecha descendente y trae categoría, cuenta y banco', () async {
    await basics();
    await tx('t1', 'expense', '10', 'acc-bbva', Catalog.comida, '2026-10-01', desc: 'Antes');
    await tx('t2', 'expense', '20', 'acc-bbva', Catalog.vivienda, '2026-10-05', desc: 'Después');
    final list = await h.db.watchTransactions(const TransactionFilter()).first;
    expect(list.map((t) => t.description), ['Después', 'Antes']);
    expect(list.first.categoryName, 'Vivienda');
    expect(list.first.accountName, 'BBVA México');
    expect(list.first.bankName, 'BBVA México');
    expect(list.first.logoKey, 'bbva');
    expect(list.first.signedAmount.cents, -2000);
    expect(list.first.pending, isTrue); // aún en la outbox
  });

  test('filtros: tipo, categoría, cuenta, banco, rango de fechas y búsqueda', () async {
    await basics();
    await tx('t1', 'expense', '100', 'acc-bbva', Catalog.comida, '2026-10-03', desc: 'Tacos 100% buenos');
    await tx('t2', 'expense', '50', 'acc-cash', Catalog.comida, '2026-10-05', desc: 'Café');
    await tx('t3', 'expense', '900', 'acc-bbva', Catalog.vivienda, '2026-09-01', desc: 'Renta');
    await tx('t4', 'income', '3000', 'acc-bbva', Catalog.salario, '2026-10-01', desc: 'Quincena');
    await tx('t5', 'income', '500', 'acc-cash', Catalog.prestamoCobrado, '2026-10-02', who: 'Luis Pérez');
    Future<List<String>> ids(TransactionFilter f) async => (await h.db.watchTransactions(f).first).map((t) => t.id).toList()..sort();

    expect(await ids(const TransactionFilter(type: 'expense')), ['t1', 't2', 't3']);
    expect(await ids(const TransactionFilter(type: 'expense', categoryId: Catalog.comida)), ['t1', 't2']);
    expect(await ids(const TransactionFilter(accountId: 'acc-cash')), ['t2', 't5']);
    expect(await ids(const TransactionFilter(bankId: Catalog.bbva)), ['t1', 't3', 't4']);
    expect(await ids(const TransactionFilter(from: '2026-10-01', to: '2026-11-01')), ['t1', 't2', 't4', 't5']);
    expect(await ids(const TransactionFilter(query: 'café')), ['t2']); // sin distinguir mayúsculas (ASCII)
    expect(await ids(const TransactionFilter(query: '100%')), ['t1']); // % se busca literal
    expect(await ids(const TransactionFilter(query: 'Luis')), ['t5']); // también por nombre de la persona
    expect(await ids(const TransactionFilter(query: '_')), isEmpty); // _ no es comodín
    expect(await h.db.watchTransactions(const TransactionFilter(limit: 2)).first, hasLength(2));
  });

  test('totales del filtro (resumen del mes)', () async {
    await basics();
    await tx('t1', 'expense', '100', 'acc-bbva', Catalog.comida, '2026-10-03');
    await tx('t2', 'income', '3000', 'acc-bbva', Catalog.salario, '2026-10-01');
    await tx('t3', 'expense', '900', 'acc-bbva', Catalog.vivienda, '2026-09-01');
    final oct = await h.db.watchTotals(const TransactionFilter(from: '2026-10-01', to: '2026-11-01')).first;
    expect([oct.income.toApiString(), oct.expense.toApiString(), oct.net.toApiString()], ['3000.00', '100.00', '2900.00']);
    final none = await h.db.watchTotals(const TransactionFilter(from: '2027-01-01', to: '2027-02-01')).first;
    expect(none.income, Money.zero);
  });

  test('una transacción huérfana (sin cuenta o categoría) se marca y no rompe la lista', () async {
    await basics();
    await tx('t1', 'expense', '10', 'acc-cash', Catalog.comida, '2026-10-03');
    await h.store.saveTransaction(
        id: 't2', type: 'expense', amount: Money.parse('5'), accountId: 'no-existe', categoryId: Catalog.comida, occurredOn: '2026-10-04');
    final list = await h.db.watchTransactions(const TransactionFilter()).first;
    expect(list.firstWhere((t) => t.id == 't2').isOrphan, isTrue);
    expect(list.firstWhere((t) => t.id == 't1').isOrphan, isFalse);
  });

  test('las consultas son reactivas: emiten de nuevo al escribir', () async {
    await basics();
    final emissions = <int>[];
    final sub = h.db.watchTransactions(const TransactionFilter()).listen((l) => emissions.add(l.length));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await tx('t1', 'expense', '10', 'acc-cash', Catalog.comida, '2026-10-03');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await sub.cancel();
    expect(emissions.first, 0);
    expect(emissions.last, 1);
  });

  test('categorías por tipo (las del sistema al final) y bancos por nombre', () async {
    final income = await h.db.watchCategories(kind: 'income').first;
    expect(income.map((c) => c.name), ['Salario / quincena', 'Préstamo cobrado']);
    expect((await h.db.watchCategories(kind: 'expense').first).map((c) => c.name), ['Alimentación', 'Vivienda']);
    expect((await h.db.watchBanks().first).map((b) => b.name), ['Banamex', 'BBVA México', 'Santander']);
  });

  test('pendientes y problemas de la outbox', () async {
    await basics();
    expect(await h.db.watchPendingCount().first, 2);
    expect(await h.db.watchOutboxProblems().first, isEmpty);
    h.api.onPush = (changes) async => pushResponse([
          for (final c in changes) result(c, 'invalid', code: 'validation_error', extra: {'message': 'x'}),
        ]);
    await h.engine.run();
    final problems = await h.db.watchOutboxProblems().first;
    expect(problems, hasLength(2));
    expect(await h.db.describeOutboxEntry(problems.first), startsWith('Cuenta: '));
  });
}
