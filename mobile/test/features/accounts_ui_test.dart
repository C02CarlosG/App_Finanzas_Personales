import 'package:finanzas_personales/core/money/money.dart';
import 'package:finanzas_personales/features/accounts/presentation/bank_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/catalog.dart';
import '../support/ui.dart';
import '../sync/support.dart';

void main() {
  late Harness h;
  setUp(() async {
    h = Harness();
    await seedCatalog(h.db);
  });
  tearDown(() => h.close());

  Future<void> openBancos(WidgetTester tester) async {
    await pumpApp(tester, h);
    await goToTab(tester, 'Bancos');
  }

  Future<void> addAccountViaUi(WidgetTester tester, {required String bankKey, String? name, String balance = '0', String? card}) async {
    await tapKey(tester, const Key('agregar-cuenta'));
    await tapKey(tester, Key('banco-$bankKey'));
    if (name != null) await enter(tester, const Key('campo-nombre-cuenta'), name);
    if (card != null) await tapKey(tester, Key('tipo-$card'));
    await enter(tester, const Key('campo-saldo-inicial'), balance);
    await tapKey(tester, const Key('guardar-cuenta'));
    await settleDb(tester);
  }

  testWidgets('sin cuentas: estado vacío con acceso a agregar', (tester) async {
    await openBancos(tester);
    expect(find.byKey(const Key('sin-cuentas')), findsOneWidget);
    expect(find.text('Aún no tienes cuentas'), findsOneWidget);
    await finishApp(tester);
  });

  testWidgets('agregar una cuenta de banco con el selector visual, saldo inicial y tipo', (tester) async {
    await openBancos(tester);
    await addAccountViaUi(tester, bankKey: 'bbva', balance: r'$1,500.50', card: 'credito');

    expect(find.byKey(const Key('sin-cuentas')), findsNothing);
    expect(find.text('BBVA México'), findsWidgets);
    expect(find.text('BBVA México · Crédito'), findsOneWidget);
    expect(find.text(r'$1,500.50'), findsWidgets);

    final row = (await tester.runAsync(() => h.db.select(h.db.accounts).getSingle()))!;
    expect([row.type, row.bankId, row.cardType, row.initialBalanceCents], ['banco', Catalog.bbva, 'credito', 150050]);
    expect((await tester.runAsync(() => h.outbox()))!.single.entity, 'accounts');
    await finishApp(tester);
  });

  testWidgets('sin elegir banco no se guarda y explica por qué', (tester) async {
    await openBancos(tester);
    await tapKey(tester, const Key('agregar-cuenta'));
    await tapKey(tester, const Key('guardar-cuenta'));
    expect(find.text('Elige un banco de la lista'), findsOneWidget);
    expect((await tester.runAsync(() => h.db.select(h.db.accounts).get()))!, isEmpty);
    await finishApp(tester);
  });

  testWidgets('monto inválido se rechaza en el formulario', (tester) async {
    await openBancos(tester);
    await tapKey(tester, const Key('agregar-cuenta'));
    await tapKey(tester, const Key('banco-santander'));
    await enter(tester, const Key('campo-saldo-inicial'), '12.345');
    await tapKey(tester, const Key('guardar-cuenta'));
    expect(find.textContaining('Monto inválido'), findsOneWidget);
    expect((await tester.runAsync(() => h.db.select(h.db.accounts).get()))!, isEmpty);
    await finishApp(tester);
  });

  testWidgets('efectivo: nombre por defecto y saldo negativo permitido', (tester) async {
    await openBancos(tester);
    await tapKey(tester, const Key('agregar-cuenta'));
    await tester.tap(find.text('Efectivo'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('banco-bbva')), findsNothing); // en efectivo no hay selector de bancos
    await enter(tester, const Key('campo-saldo-inicial'), '-200');
    await tapKey(tester, const Key('guardar-cuenta'));
    await settleDb(tester);

    expect(find.text('Efectivo'), findsWidgets);
    expect(find.text(r'-$200.00'), findsWidgets);
    final row = (await tester.runAsync(() => h.db.select(h.db.accounts).getSingle()))!;
    expect([row.type, row.name, row.bankId, row.initialBalanceCents], ['efectivo', 'Efectivo', null, -20000]);
    await finishApp(tester);
  });

  testWidgets('el total suma todas las cuentas y refleja los movimientos', (tester) async {
    await tester.runAsync(() async {
      await h.store.saveAccount(id: 'a1', type: 'banco', bankId: Catalog.bbva, name: 'Nómina', initialBalance: Money.parse('1000'));
      await h.store.saveAccount(id: 'a2', type: 'efectivo', name: 'Cartera', initialBalance: Money.parse('200.50'));
      await h.store.saveTransaction(
          id: 't1', type: 'expense', amount: Money.parse('50.50'), accountId: 'a2', categoryId: Catalog.comida, occurredOn: '2026-10-19');
    });
    await openBancos(tester);
    expect(tester.widget<Text>(find.byKey(const Key('bancos-saldo-total'))).data, r'$1,150.00');
    expect(find.byKey(const Key('cuenta-a1')), findsOneWidget);
    expect(find.byKey(const Key('cuenta-a2')), findsOneWidget);
    expect(find.text(r'$150.00'), findsOneWidget); // saldo de la cartera: 200.50 − 50.50
    await finishApp(tester);
  });

  testWidgets('editar: cambia nombre y saldo inicial y se ve en la lista', (tester) async {
    await tester.runAsync(() => h.store.saveAccount(id: 'a1', type: 'efectivo', name: 'Cartera', initialBalance: Money.parse('100')));
    await openBancos(tester);
    await tester.tap(find.byKey(const Key('cuenta-a1')));
    await tester.pumpAndSettle();
    expect(find.text('Editar cuenta'), findsOneWidget);

    await enter(tester, const Key('campo-nombre-cuenta'), 'Caja chica');
    await enter(tester, const Key('campo-saldo-inicial'), '350');
    await tapKey(tester, const Key('guardar-cuenta'));
    await settleDb(tester);

    expect(find.text('Caja chica'), findsOneWidget);
    expect(find.text(r'$350.00'), findsWidgets);
    await finishApp(tester);
  });

  testWidgets('no deja eliminar una cuenta con movimientos y lo explica', (tester) async {
    await tester.runAsync(() async {
      await h.store.saveAccount(id: 'a1', type: 'efectivo', name: 'Cartera');
      await h.store.saveTransaction(
          id: 't1', type: 'expense', amount: Money.parse('10'), accountId: 'a1', categoryId: Catalog.comida, occurredOn: '2026-10-19');
    });
    await openBancos(tester);
    await tester.tap(find.byKey(const Key('cuenta-a1')));
    await tester.pumpAndSettle();
    await tapKey(tester, const Key('eliminar-cuenta'));
    await tapKey(tester, const Key('confirmar-eliminar'));
    await settleDb(tester);
    expect(find.textContaining('tiene movimientos'), findsOneWidget);
    await finishApp(tester);
  });

  testWidgets('eliminar una cuenta sin movimientos la quita y vuelve al estado vacío', (tester) async {
    await tester.runAsync(() => h.store.saveAccount(id: 'a1', type: 'efectivo', name: 'Cartera'));
    await openBancos(tester);
    await tester.tap(find.byKey(const Key('cuenta-a1')));
    await tester.pumpAndSettle();
    await tapKey(tester, const Key('eliminar-cuenta'));
    await tapKey(tester, const Key('confirmar-eliminar'));
    await settleDb(tester);
    expect(find.byKey(const Key('sin-cuentas')), findsOneWidget);
    await finishApp(tester);
  });

  testWidgets('sin catálogo de bancos (aún sin sincronizar) lo avisa en lugar de mostrar una lista vacía', (tester) async {
    final empty = Harness();
    addTearDown(empty.close);
    await pumpApp(tester, empty);
    await goToTab(tester, 'Bancos');
    await tapKey(tester, const Key('agregar-cuenta'));
    expect(find.byKey(const Key('sin-catalogo-bancos')), findsOneWidget);
    await finishApp(tester);
  });

  group('BankAvatar', () {
    test('iniciales legibles', () {
      expect(bankInitials('BBVA México'), 'BBVA');
      expect(bankInitials('HSBC'), 'HSBC');
      expect(bankInitials('Santander'), 'Sa');
      expect(bankInitials('Nu México'), 'Nu');
      expect(bankInitials('Banco Azteca'), 'Ba');
    });

    test('color de marca conocido y de reserva para claves nuevas', () {
      expect(bankColor('bbva'), const Color(0xFF004481));
      expect(bankColor('banco-nuevo'), const Color(0xFF607D8B));
      expect(bankColor(null), const Color(0xFF607D8B));
    });
  });
}
