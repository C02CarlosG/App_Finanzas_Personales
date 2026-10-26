import 'package:finanzas_personales/core/data/data_providers.dart';
import 'package:finanzas_personales/core/db/queries.dart';
import 'package:finanzas_personales/core/db/queries_fase2.dart';
import 'package:finanzas_personales/core/money/money.dart';
import 'package:finanzas_personales/features/cards/data/credit_cards_repository.dart';
import 'package:finanzas_personales/features/dashboard/presentation/upcoming_payments.dart';
import 'package:finanzas_personales/features/loans/data/loans_repository.dart';
import 'package:finanzas_personales/features/subscriptions/data/subscriptions_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/catalog.dart';
import '../support/ui.dart';
import '../sync/support.dart';

void main() {
  late Harness h;
  late LoansRepository loans;
  late CreditCardsRepository cards;
  late SubscriptionsRepository subs;
  final today = DateTime(2026, 10, 20);

  setUp(() async {
    h = Harness();
    await seedCatalog(h.db);
    await seedPhase2Categories(h.db);
    loans = LoansRepository(h.store, now: () => today);
    cards = CreditCardsRepository(h.store, now: () => today);
    subs = SubscriptionsRepository(h.store);
  });
  tearDown(() => h.close());

  Future<void> oneAccount(WidgetTester tester, {String balance = '1000'}) =>
      tester.runAsync(() => h.store.saveAccount(id: 'acc-1', type: 'banco', bankId: Catalog.bbva, name: 'Nómina', initialBalance: Money.parse(balance)));

  Future<void> open(WidgetTester tester) => pumpApp(tester, h, extra: [todayProvider.overrideWithValue(today)]);

  Future<void> tapTab(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(of: find.byType(TabBar), matching: find.text(label)));
    await tester.pumpAndSettle();
  }

  Future<void> openLoansTab(WidgetTester tester) async {
    await open(tester);
    await goToTab(tester, 'Bancos');
    await tapTab(tester, 'Préstamos');
  }

  Future<void> openExpenseSection(WidgetTester tester, String chipKey) async {
    await open(tester);
    await tester.ensureVisible(find.byKey(const Key('ver-todos')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ver-todos')));
    await tester.pumpAndSettle();
    await tapKey(tester, Key(chipKey));
  }

  Future<String> seedLoan(WidgetTester tester, {String direction = 'owed_to_me', String principal = '500', String? dueDate}) async =>
      (await tester.runAsync(() => loans.create(personName: 'Luis Pérez', direction: direction, principal: Money.parse(principal), dueDate: dueDate)))!;

  Future<Money> balanceOf(WidgetTester tester, String id) async =>
      (await tester.runAsync(() => h.db.watchAccounts().first))!.firstWhere((a) => a.id == id).balance;

  String text(WidgetTester tester, Key key) => tester.widget<Text>(find.byKey(key)).data!;

  group('préstamos', () {
    testWidgets('Bancos tiene pestañas Cuentas | Préstamos; sin préstamos invita a agregar el primero', (tester) async {
      await openLoansTab(tester);
      expect(find.byKey(const Key('sin-prestamos')), findsOneWidget);
      expect(find.byKey(const Key('agregar-prestamo')), findsOneWidget);
      await tapTab(tester, 'Cuentas');
      expect(find.byKey(const Key('agregar-cuenta')), findsOneWidget); // el botón sigue a la pestaña
      await finishApp(tester);
    });

    testWidgets('agregar un préstamo "me debe": aparece en la lista y en el resumen', (tester) async {
      await openLoansTab(tester);
      await tapKey(tester, const Key('agregar-prestamo'));
      expect(find.text('Nuevo préstamo'), findsOneWidget);
      await enter(tester, const Key('campo-persona-prestamo'), '  Luis Pérez ');
      await enter(tester, const Key('campo-monto-prestamo'), r'$1,500.50');
      await tapKey(tester, const Key('guardar-prestamo'));
      await settleDb(tester);

      expect(find.text('Luis Pérez'), findsOneWidget);
      expect(find.textContaining('Te debe'), findsWidgets);
      expect(text(tester, const Key('resumen-te-deben')), r'$1,500.50');
      expect(text(tester, const Key('resumen-debes')), r'$0.00');
      final loan = (await tester.runAsync(() => h.db.watchLoans().first))!.single;
      expect([loan.personName, loan.principal.cents, loan.direction, loan.dueDate], ['Luis Pérez', 150050, 'owed_to_me', null]);
      await finishApp(tester);
    });

    testWidgets('el formulario valida: persona y monto obligatorios', (tester) async {
      await openLoansTab(tester);
      await tapKey(tester, const Key('agregar-prestamo'));
      await tapKey(tester, const Key('guardar-prestamo'));
      expect(find.text('Escribe el nombre de la persona'), findsOneWidget);
      expect(find.text('Escribe un monto'), findsOneWidget);
      expect((await tester.runAsync(() => h.db.watchLoans().first))!, isEmpty);
      await finishApp(tester);
    });

    testWidgets('cobrar un abono: baja lo pendiente, sube el saldo de la cuenta y queda en el historial', (tester) async {
      await oneAccount(tester);
      final id = await seedLoan(tester);
      await openLoansTab(tester);
      await tester.tap(find.byKey(Key('prestamo-$id')));
      await tester.pumpAndSettle();
      expect(text(tester, const Key('saldo-prestamo')), r'$500.00');

      await tapKey(tester, const Key('abonar'));
      await enter(tester, const Key('campo-monto-movimiento'), '200');
      await tapKey(tester, const Key('confirmar-movimiento-prestamo'));
      await settleDb(tester);

      expect(text(tester, const Key('saldo-prestamo')), r'$300.00');
      expect(find.text('Cobro'), findsOneWidget);
      expect(find.textContaining('Nómina'), findsWidgets);
      expect((await balanceOf(tester, 'acc-1')).cents, 120000);
      final tx = (await tester.runAsync(() => h.db.watchTransactions(const TransactionFilter()).first))!.single;
      expect([tx.type, tx.categoryId, tx.counterparty], ['income', Catalog.prestamoCobrado, 'Luis Pérez']);
      await finishApp(tester);
    });

    testWidgets('un abono mayor a lo pendiente se rechaza con un mensaje y no registra nada', (tester) async {
      await oneAccount(tester);
      final id = await seedLoan(tester);
      await openLoansTab(tester);
      await tester.tap(find.byKey(Key('prestamo-$id')));
      await tester.pumpAndSettle();
      await tapKey(tester, const Key('abonar'));
      await enter(tester, const Key('campo-monto-movimiento'), '600');
      await tapKey(tester, const Key('confirmar-movimiento-prestamo'));
      await settleDb(tester);
      expect(find.byKey(const Key('error-movimiento-prestamo')), findsOneWidget);
      expect(find.textContaining('excede'), findsOneWidget);
      expect((await tester.runAsync(() => h.db.watchTransactions(const TransactionFilter()).first))!, isEmpty);
      await finishApp(tester);
    });

    testWidgets('pagar lo que debes registra un gasto; marcar como pagado liquida el resto en la cuenta elegida', (tester) async {
      await oneAccount(tester);
      final id = await seedLoan(tester, direction: 'i_owe', principal: '300');
      await openLoansTab(tester);
      await tester.tap(find.byKey(Key('prestamo-$id')));
      await tester.pumpAndSettle();
      expect(find.text('Registrar pago'), findsWidgets);

      await tapKey(tester, const Key('abonar'));
      await enter(tester, const Key('campo-monto-movimiento'), '100');
      await tapKey(tester, const Key('confirmar-movimiento-prestamo'));
      await settleDb(tester);
      expect(text(tester, const Key('saldo-prestamo')), r'$200.00');
      expect((await balanceOf(tester, 'acc-1')).cents, 90000);

      await tapKey(tester, const Key('marcar-pagado'));
      expect(find.textContaining('Quedan \$200.00'), findsOneWidget);
      await tapKey(tester, const Key('confirmar-movimiento-prestamo'));
      await settleDb(tester);
      expect(text(tester, const Key('estado-prestamo')), 'Pagado');
      expect(find.byKey(const Key('abonar')), findsNothing);
      expect((await balanceOf(tester, 'acc-1')).cents, 70000); // 1000 − 100 − 200
      await finishApp(tester);
    });

    testWidgets('aumentar el monto no mueve saldos; deshacer un abono lo devuelve todo', (tester) async {
      await oneAccount(tester);
      final id = await seedLoan(tester);
      await openLoansTab(tester);
      await tester.tap(find.byKey(Key('prestamo-$id')));
      await tester.pumpAndSettle();

      await tapKey(tester, const Key('aumentar'));
      await enter(tester, const Key('campo-monto-movimiento'), '100');
      await tapKey(tester, const Key('confirmar-movimiento-prestamo'));
      await settleDb(tester);
      expect(text(tester, const Key('saldo-prestamo')), r'$600.00');
      expect(find.text('Aumento'), findsOneWidget);
      expect((await balanceOf(tester, 'acc-1')).cents, 100000);

      await tapKey(tester, const Key('abonar'));
      await enter(tester, const Key('campo-monto-movimiento'), '250');
      await tapKey(tester, const Key('confirmar-movimiento-prestamo'));
      await settleDb(tester);
      expect(text(tester, const Key('saldo-prestamo')), r'$350.00');

      final movement = (await tester.runAsync(() => h.db.watchLoanMovements(id).first))!.firstWhere((m) => m.isPayment);
      await tapKey(tester, Key('deshacer-${movement.id}'));
      await tapKey(tester, const Key('confirmar-deshacer'));
      await settleDb(tester);
      expect(text(tester, const Key('saldo-prestamo')), r'$600.00');
      expect((await balanceOf(tester, 'acc-1')).cents, 100000);
      expect((await tester.runAsync(() => h.db.watchTransactions(const TransactionFilter()).first))!, isEmpty);
      await finishApp(tester);
    });

    testWidgets('eliminar el préstamo vuelve a la lista y conserva el ingreso ya registrado', (tester) async {
      await oneAccount(tester);
      final id = await seedLoan(tester);
      await tester.runAsync(() => loans.addPayment(id, amount: Money.parse('100'), accountId: 'acc-1'));
      await openLoansTab(tester);
      await tester.tap(find.byKey(Key('prestamo-$id')));
      await tester.pumpAndSettle();
      await tapKey(tester, const Key('eliminar-prestamo'));
      expect(find.textContaining('se conservan'), findsOneWidget);
      await tapKey(tester, const Key('confirmar-eliminar'));
      await settleDb(tester);
      expect(find.byKey(const Key('sin-prestamos')), findsOneWidget);
      expect((await tester.runAsync(() => h.db.watchTransactions(const TransactionFilter()).first))!, hasLength(1));
      expect((await balanceOf(tester, 'acc-1')).cents, 110000);
      await finishApp(tester);
    });

    testWidgets('el plazo vencido se marca y el sentido no se puede cambiar al editar', (tester) async {
      final id = await seedLoan(tester, dueDate: '2026-10-01');
      await openLoansTab(tester);
      expect(find.textContaining('Vencido el 1 oct 2026'), findsOneWidget);
      await tester.tap(find.byKey(Key('prestamo-$id')));
      await tester.pumpAndSettle();
      await tapKey(tester, const Key('editar-prestamo'));
      expect(find.text('Editar préstamo'), findsOneWidget);
      final chip = tester.widget<ChoiceChip>(find.byKey(const Key('sentido-le-debo')));
      expect(chip.onSelected, isNull);
      await finishApp(tester);
    });

    testWidgets('un movimiento que viene de un abono no se edita desde Movimientos', (tester) async {
      await oneAccount(tester);
      final id = await seedLoan(tester);
      await tester.runAsync(() => loans.addPayment(id, amount: Money.parse('100'), accountId: 'acc-1'));
      final tx = (await tester.runAsync(() => h.db.watchTransactions(const TransactionFilter()).first))!.single;
      await open(tester);
      await tester.tap(find.byKey(Key('movimiento-${tx.id}')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('movimiento-ligado')), findsOneWidget);
      expect(find.byKey(const Key('guardar-movimiento')), findsNothing);
      expect(find.byKey(const Key('eliminar-movimiento')), findsNothing);
      await finishApp(tester);
    });
  });

  group('suscripciones', () {
    testWidgets('Gastos tiene la sección Suscripciones; alta, edición, pausa y baja', (tester) async {
      await open(tester);
      await tester.ensureVisible(find.byKey(const Key('ver-todos')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ver-todos')));
      await tester.pumpAndSettle();
      await tapKey(tester, const Key('seccion-suscripciones'));
      expect(find.byKey(const Key('sin-suscripciones')), findsOneWidget);

      await tapKey(tester, const Key('agregar-movimiento')); // con la sección activa, agrega una suscripción
      expect(find.text('Nueva suscripción'), findsOneWidget);
      await enter(tester, const Key('campo-nombre-suscripcion'), 'Netflix');
      await enter(tester, const Key('campo-monto-suscripcion'), '199');
      await tapKey(tester, const Key('guardar-suscripcion'));
      await settleDb(tester);

      expect(find.text('Netflix'), findsOneWidget);
      expect(find.textContaining('Mensual'), findsOneWidget);
      expect(find.textContaining('20 oct · hoy'), findsOneWidget); // la fecha por omisión es hoy
      expect(text(tester, const Key('total-suscripciones')), r'$199.00');

      final sub = (await tester.runAsync(() => h.db.watchSubscriptions().first))!.single;
      await tester.tap(find.byKey(Key('suscripcion-${sub.id}')));
      await tester.pumpAndSettle();
      expect(find.text('Editar suscripción'), findsOneWidget);
      await tapKey(tester, const Key('suscripcion-activa'));
      await tapKey(tester, const Key('guardar-suscripcion'));
      await settleDb(tester);
      expect(find.textContaining('Pausada'), findsOneWidget);
      expect(text(tester, const Key('total-suscripciones')), r'$0.00');

      await tester.tap(find.byKey(Key('suscripcion-${sub.id}')));
      await tester.pumpAndSettle();
      await tapKey(tester, const Key('eliminar-suscripcion'));
      await tapKey(tester, const Key('confirmar-eliminar'));
      await settleDb(tester);
      expect(find.byKey(const Key('sin-suscripciones')), findsOneWidget);
      await finishApp(tester);
    });

    testWidgets('las activas se ordenan por la renovación más próxima y el total suma el equivalente mensual', (tester) async {
      await tester.runAsync(() async {
        await subs.create(name: 'Anual', amount: Money.parse('1200'), renewalDate: '2026-12-01', period: 'yearly');
        await subs.create(name: 'Pronto', amount: Money.parse('100'), renewalDate: '2026-10-22');
        await subs.create(name: 'Semanal', amount: Money.parse('50'), renewalDate: '2026-10-25', period: 'weekly');
      });
      await openExpenseSection(tester, 'seccion-suscripciones');
      final names = [for (final t in tester.widgetList<ListTile>(find.byType(ListTile))) (t.title as Text?)?.data].whereType<String>().toList();
      expect(names.where((n) => ['Pronto', 'Semanal', 'Anual'].contains(n)), ['Pronto', 'Semanal', 'Anual']);
      // 100 + 50×52/12 (216.67) + 1200/12 (100)
      expect(text(tester, const Key('total-suscripciones')), r'$416.67');
      await finishApp(tester);
    });
  });

  group('tarjetas de crédito', () {
    testWidgets('alta de tarjeta, pago, rechazo de pago excesivo y deshacer', (tester) async {
      await oneAccount(tester);
      await openExpenseSection(tester, 'seccion-tarjetas');
      expect(find.byKey(const Key('sin-tarjetas')), findsOneWidget);

      await tapKey(tester, const Key('agregar-movimiento'));
      expect(find.text('Nueva tarjeta'), findsOneWidget);
      await enter(tester, const Key('campo-nombre-tarjeta'), 'BBVA Azul');
      await enter(tester, const Key('campo-saldo-tarjeta'), '1000');
      await tapKey(tester, const Key('guardar-tarjeta'));
      await settleDb(tester);
      expect(text(tester, const Key('total-tarjetas')), r'$1,000.00');
      expect(find.textContaining('Sin fecha de vencimiento'), findsOneWidget);

      final card = (await tester.runAsync(() => h.db.watchCreditCards().first))!.single;
      await tester.tap(find.byKey(Key('tarjeta-${card.id}')));
      await tester.pumpAndSettle();
      expect(text(tester, const Key('saldo-tarjeta')), r'$1,000.00');

      await tapKey(tester, const Key('pagar-tarjeta'));
      await enter(tester, const Key('campo-monto-pago'), '1500');
      await tapKey(tester, const Key('confirmar-pago-tarjeta'));
      await settleDb(tester);
      expect(find.textContaining('excede el saldo pendiente'), findsOneWidget);

      await enter(tester, const Key('campo-monto-pago'), '400');
      await tapKey(tester, const Key('confirmar-pago-tarjeta'));
      await settleDb(tester);
      expect(text(tester, const Key('saldo-tarjeta')), r'$600.00');
      expect((await balanceOf(tester, 'acc-1')).cents, 60000);
      final tx = (await tester.runAsync(() => h.db.watchTransactions(const TransactionFilter()).first))!.single;
      expect([tx.type, tx.categoryId, tx.description], ['expense', Catalog.pagoTarjeta, 'Pago de tarjeta BBVA Azul']);

      final payment = (await tester.runAsync(() => h.db.watchCardPayments(card.id).first))!.single;
      await tapKey(tester, Key('deshacer-${payment.id}'));
      await tapKey(tester, const Key('confirmar-deshacer'));
      await settleDb(tester);
      expect(text(tester, const Key('saldo-tarjeta')), r'$1,000.00');
      expect((await balanceOf(tester, 'acc-1')).cents, 100000);
      await finishApp(tester);
    });

    testWidgets('el vencimiento se explica en días y actualizar el saldo desde el lápiz habilita el pago', (tester) async {
      final id = (await tester.runAsync(() => cards.create(name: 'Nu', pendingBalance: Money.zero, dueDate: '2026-10-23')))!;
      await oneAccount(tester);
      await openExpenseSection(tester, 'seccion-tarjetas');
      expect(find.textContaining('Vence 23 oct · en 3 días'), findsOneWidget);
      await tester.tap(find.byKey(Key('tarjeta-$id')));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(find.byKey(const Key('pagar-tarjeta'))).onPressed, isNull); // sin saldo no hay qué pagar
      await tapKey(tester, const Key('editar-tarjeta'));
      await enter(tester, const Key('campo-saldo-tarjeta'), '750.25');
      await tapKey(tester, const Key('guardar-tarjeta'));
      await settleDb(tester);
      expect(text(tester, const Key('saldo-tarjeta')), r'$750.25');
      expect(tester.widget<FilledButton>(find.byKey(const Key('pagar-tarjeta'))).onPressed, isNotNull);
      await finishApp(tester);
    });
  });

  group('próximos pagos en Inicio', () {
    testWidgets('lista suscripciones, tarjetas y préstamos por urgencia; ignora pausadas, sin saldo y pagados', (tester) async {
      await oneAccount(tester);
      await tester.runAsync(() async {
        final s = await subs.create(name: 'Netflix', amount: Money.parse('199'), renewalDate: '2026-10-23');
        final paused = await subs.create(name: 'Pausada', amount: Money.parse('50'), renewalDate: '2026-10-21');
        await subs.setActive(paused, false);
        await cards.create(name: 'Azul', pendingBalance: Money.parse('900'), dueDate: '2026-10-21');
        await cards.create(name: 'Sin saldo', pendingBalance: Money.zero, dueDate: '2026-10-21');
        await loans.create(personName: 'Luis', direction: 'owed_to_me', principal: Money.parse('300'), dueDate: '2026-10-30');
        final paid = await loans.create(personName: 'Pagado', direction: 'owed_to_me', principal: Money.parse('10'), dueDate: '2026-10-22');
        await loans.addPayment(paid, amount: Money.parse('10'), accountId: 'acc-1');
        expect(s, isNotEmpty);
      });
      await open(tester);
      expect(find.byKey(const Key('sin-proximos')), findsNothing);
      final titles = [for (final t in tester.widgetList<ListTile>(find.byType(ListTile))) (t.title as Text?)?.data].whereType<String>().toList();
      final upcoming = titles.where((t) => ['Pago de Azul', 'Netflix', 'Cobrar a Luis'].contains(t)).toList();
      expect(upcoming, ['Pago de Azul', 'Netflix', 'Cobrar a Luis']);
      expect(titles, isNot(contains('Pausada')));
      expect(titles, isNot(contains('Pago de Sin saldo')));
      expect(titles, isNot(contains('Cobrar a Pagado')));
      expect(find.textContaining('mañana'), findsOneWidget); // la tarjeta vence mañana
      await finishApp(tester);
    });

    testWidgets('sin nada próximo dice "Nada pendiente"', (tester) async {
      await open(tester);
      expect(find.byKey(const Key('sin-proximos')), findsOneWidget);
      await finishApp(tester);
    });
  });

  group('buildUpcoming', () {
    SubscriptionView sub(String id, String date, {String period = 'monthly', bool active = true}) => SubscriptionView(
        id: id, name: id, amount: Money.parse('10'), renewalDate: date, period: period, active: active, pending: false);
    CreditCardView card(String id, String? due, String pending) =>
        CreditCardView(id: id, name: id, pendingBalance: Money.parse(pending), dueDate: due, pending: false);
    LoanView loan(String id, String? due, {String direction = 'owed_to_me', String status = 'active'}) => LoanView(
        id: id, personName: id, direction: direction, principal: Money.parse('100'), increases: Money.zero, payments: Money.zero, status: status, dueDate: due, pending: false);

    test('incluye vencidos y lo que cae dentro de 30 días; deja fuera lo lejano; respeta el límite', () {
      final items = buildUpcoming(
        subscriptions: [sub('hoy', '2026-10-20'), sub('lejos', '2026-12-31', period: 'yearly')],
        cards: [card('vencida', '2026-10-15', '10'), card('en-30', '2026-11-19', '10'), card('en-31', '2026-11-20', '10')],
        loans: [loan('debo', '2026-10-25', direction: 'i_owe'), loan('pagado', '2026-10-21', status: 'paid'), loan('sin-plazo', null)],
        today: today,
      );
      expect([for (final i in items) i.id], ['vencida', 'hoy', 'debo', 'en-30']);
      expect(items.first.overdue, isTrue);
      expect(items[2].title, 'Pagar a debo');
      final limited = buildUpcoming(
        subscriptions: [for (var i = 0; i < 8; i++) sub('s$i', '2026-10-2$i')],
        cards: const [],
        loans: const [],
        today: today,
        limit: 3,
      );
      expect(limited, hasLength(3));
    });

    test('una suscripción mensual cuyo día ya pasó aparece en su siguiente renovación', () {
      final items = buildUpcoming(subscriptions: [sub('s', '2026-01-25')], cards: const [], loans: const [], today: today);
      expect(items.single.days, 5); // 25 de octubre
    });
  });

  testWidgets('con el texto del sistema al 200% las pantallas de Fase 2 no se desbordan', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await oneAccount(tester);
    final loanId = await seedLoan(tester, dueDate: '2026-10-01');
    final cardId = (await tester.runAsync(() => cards.create(name: 'Tarjeta con un nombre bastante largo', pendingBalance: Money.parse('123456.78'), dueDate: '2026-10-21')))!;
    await tester.runAsync(() async {
      await subs.create(name: 'Servicio de streaming con nombre largo', amount: Money.parse('1999.99'), renewalDate: '2026-10-22');
      await loans.addPayment(loanId, amount: Money.parse('100'), accountId: 'acc-1');
    });
    await open(tester);
    expect(tester.takeException(), isNull, reason: 'Inicio');
    await goToTab(tester, 'Bancos');
    await tapTab(tester, 'Préstamos');
    expect(tester.takeException(), isNull, reason: 'Préstamos');
    await tester.tap(find.byKey(Key('prestamo-$loanId')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'Detalle de préstamo');
    await tester.ensureVisible(find.byKey(const Key('abonar')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('abonar')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'Hoja de abono');
    await tester.tapAt(const Offset(10, 10)); // cierra la hoja
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await goToTab(tester, 'Inicio');
    await tester.ensureVisible(find.byKey(const Key('ver-todos')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ver-todos')));
    await tester.pumpAndSettle();
    await tapKey(tester, const Key('seccion-suscripciones'));
    expect(tester.takeException(), isNull, reason: 'Suscripciones');
    await tapKey(tester, const Key('seccion-tarjetas'));
    expect(tester.takeException(), isNull, reason: 'Tarjetas');
    await tester.tap(find.byKey(Key('tarjeta-$cardId')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'Detalle de tarjeta');
    await finishApp(tester);
  });
}
