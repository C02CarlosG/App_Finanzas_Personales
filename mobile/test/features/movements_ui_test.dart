import 'package:drift/drift.dart' show Value;
import 'package:finanzas_personales/core/db/app_database.dart';
import 'package:finanzas_personales/core/format/dates.dart';
import 'package:finanzas_personales/core/money/money.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/catalog.dart';
import '../support/ui.dart';
import '../sync/support.dart';

/// Fecha dentro del mes `offset` meses antes del actual (0 = este mes). Día 1..28, nunca en el futuro del mes actual.
String monthDate(int offset, int day) {
  final now = DateTime.now();
  final d = DateTime(now.year, now.month - offset, day);
  return isoDate(d);
}

void main() {
  late Harness h;
  setUp(() async {
    h = Harness();
    await seedCatalog(h.db);
  });
  tearDown(() => h.close());

  Future<void> seed(WidgetTester tester) => tester.runAsync(() async {
        await h.store.saveAccount(id: 'bbva', type: 'banco', bankId: Catalog.bbva, name: 'Nómina', initialBalance: Money.parse('10000'));
        await h.store.saveAccount(id: 'cash', type: 'efectivo', name: 'Cartera', initialBalance: Money.parse('500'));
        Future<void> tx(String id, String type, String amount, String acc, String cat, String date, String desc, {String? who}) =>
            h.store.saveTransaction(
                id: id, type: type, amount: Money.parse(amount), accountId: acc, categoryId: cat, occurredOn: date, description: desc, counterparty: who);
        // Este mes
        await tx('g1', 'expense', '100', 'bbva', Catalog.comida, monthDate(0, 1), 'Tacos al pastor');
        await tx('g2', 'expense', '50', 'cash', Catalog.comida, monthDate(0, 1), 'Café');
        await tx('g3', 'expense', '900', 'bbva', Catalog.vivienda, monthDate(0, 1), 'Renta');
        await tx('i1', 'income', '3000', 'bbva', Catalog.salario, monthDate(0, 1), 'Quincena');
        await tx('i2', 'income', '500', 'cash', Catalog.prestamoCobrado, monthDate(0, 1), 'Pago parcial', who: 'Luis Pérez');
        // Mes anterior y hace dos meses
        await tx('g4', 'expense', '70', 'bbva', Catalog.comida, monthDate(1, 15), 'Súper del mes pasado');
        await tx('g5', 'expense', '30', 'cash', Catalog.comida, monthDate(2, 10), 'Antepasado');
      });

  Future<void> openMovements(WidgetTester tester) async {
    await pumpApp(tester, h);
    await tester.tap(find.byKey(const Key('ver-todos')));
    await tester.pumpAndSettle();
  }

  Future<void> pickFromDropdown(WidgetTester tester, int index, String option) async {
    final dropdown = find.byType(DropdownButtonFormField<String?>).at(index);
    await tester.ensureVisible(dropdown);
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text(option).last);
    await tester.pumpAndSettle();
  }

  String totalText(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('total-movimientos'))).data!;

  testWidgets('"Ver todos" abre Movimientos en Gastos con el mes actual y su total', (tester) async {
    await seed(tester);
    await openMovements(tester);
    final now = DateTime.now();
    expect(find.text('Movimientos'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('etiqueta-mes'))).data, monthLabel(now.year, now.month));
    expect(find.byKey(const Key('movimiento-g1')), findsOneWidget);
    expect(find.byKey(const Key('movimiento-g3')), findsOneWidget);
    expect(find.byKey(const Key('movimiento-i1')), findsNothing); // los ingresos están en su pestaña
    expect(find.byKey(const Key('movimiento-g4')), findsNothing); // mes anterior
    expect(totalText(tester), r'$1,050.00'); // 100 + 50 + 900
    expect(find.text('Total del mes'), findsOneWidget);
    await finishApp(tester);
  });

  testWidgets('la pestaña Ingresos muestra solo ingresos y su total', (tester) async {
    await seed(tester);
    await openMovements(tester);
    await tester.tap(find.descendant(of: find.byType(TabBar), matching: find.text('Ingresos')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('movimiento-i1')), findsOneWidget);
    expect(find.byKey(const Key('movimiento-g1')), findsNothing);
    expect(totalText(tester), r'$3,500.00');
    expect(find.textContaining('Luis Pérez'), findsOneWidget); // préstamo cobrado + nombre de la persona
    await finishApp(tester);
  });

  testWidgets('navegar entre meses cambia la lista y el total; "todo el historial" las junta con el año', (tester) async {
    await seed(tester);
    await openMovements(tester);
    await tester.tap(find.byKey(const Key('mes-anterior')));
    await tester.pumpAndSettle();
    final prev = DateTime(DateTime.now().year, DateTime.now().month - 1);
    expect(tester.widget<Text>(find.byKey(const Key('etiqueta-mes'))).data, monthLabel(prev.year, prev.month));
    expect(find.byKey(const Key('movimiento-g4')), findsOneWidget);
    expect(find.byKey(const Key('movimiento-g1')), findsNothing);
    expect(totalText(tester), r'$70.00');

    await tester.tap(find.byKey(const Key('mes-siguiente')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('movimiento-g1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('todo-historial')));
    await tester.pumpAndSettle();
    expect(find.text('Todo el historial'), findsOneWidget);
    for (final id in ['g1', 'g4']) {
      expect(find.byKey(Key('movimiento-$id')), findsOneWidget, reason: id);
    }
    // La lista es perezosa: el movimiento más antiguo se construye al desplazarse hasta él.
    await tester.drag(find.byKey(const Key('movimiento-g4')), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('movimiento-g5')), findsOneWidget, reason: 'g5');
    expect(totalText(tester), r'$1,150.00'); // 1050 + 70 + 30
    expect(tester.widget<IconButton>(find.byKey(const Key('mes-anterior'))).onPressed, isNull); // sin navegar en "todo"
    await finishApp(tester);
  });

  testWidgets('filtrar por categoría y por cuenta (cada filtro acota la lista y el total)', (tester) async {
    await seed(tester);
    await openMovements(tester);
    await pickFromDropdown(tester, 0, 'Alimentación');
    expect(find.byKey(const Key('movimiento-g3')), findsNothing); // Renta es Vivienda
    expect(find.byKey(const Key('movimiento-g1')), findsOneWidget);
    expect(totalText(tester), r'$150.00');
    expect(find.text('Total (con filtros)'), findsOneWidget);

    await pickFromDropdown(tester, 1, 'Cartera');
    expect(find.byKey(const Key('movimiento-g1')), findsNothing); // g1 es de Nómina
    expect(find.byKey(const Key('movimiento-g2')), findsOneWidget);
    expect(totalText(tester), r'$50.00');

    await pickFromDropdown(tester, 0, 'Todas');
    await pickFromDropdown(tester, 1, 'Todas');
    expect(totalText(tester), r'$1,050.00');
    await finishApp(tester);
  });

  testWidgets('buscar por descripción y por nombre de la persona; sin coincidencias se puede limpiar', (tester) async {
    await seed(tester);
    await openMovements(tester);
    await enter(tester, const Key('buscar-movimientos'), 'tacos');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('movimiento-g1')), findsOneWidget);
    expect(find.byKey(const Key('movimiento-g2')), findsNothing);
    expect(totalText(tester), r'$100.00');

    await enter(tester, const Key('buscar-movimientos'), 'zzz');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sin-resultados')), findsOneWidget);
    expect(find.text('Ningún movimiento coincide con los filtros'), findsOneWidget);
    await tester.tap(find.byKey(const Key('limpiar-filtros')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('movimiento-g1')), findsOneWidget);

    await tester.tap(find.descendant(of: find.byType(TabBar), matching: find.text('Ingresos')));
    await tester.pumpAndSettle();
    await enter(tester, const Key('buscar-movimientos'), 'Luis');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('movimiento-i2')), findsOneWidget);
    expect(find.byKey(const Key('movimiento-i1')), findsNothing);
    await finishApp(tester);
  });

  testWidgets('sin movimientos en el mes muestra el estado vacío', (tester) async {
    await tester.runAsync(() => h.store.saveAccount(id: 'cash', type: 'efectivo', name: 'Cartera'));
    await openMovements(tester);
    expect(find.text('Sin gastos en este periodo'), findsOneWidget);
    expect(totalText(tester), r'$0.00');
    await finishApp(tester);
  });

  testWidgets('tocar un movimiento lo abre para editarlo y al volver el listado se actualiza', (tester) async {
    await seed(tester);
    await openMovements(tester);
    await tester.tap(find.byKey(const Key('movimiento-g2')));
    await tester.pumpAndSettle();
    expect(find.text('Editar gasto'), findsOneWidget);
    await enter(tester, const Key('campo-monto'), '75');
    await tapKey(tester, const Key('guardar-movimiento'));
    await settleDb(tester);
    expect(find.text('Movimientos'), findsOneWidget);
    expect(totalText(tester), r'$1,075.00'); // 100 + 75 + 900
    await finishApp(tester);
  });

  testWidgets('el botón Agregar crea del tipo de la pestaña activa', (tester) async {
    await seed(tester);
    await openMovements(tester);
    await tester.tap(find.byKey(const Key('agregar-movimiento')));
    await tester.pumpAndSettle();
    expect(find.text('Nuevo gasto'), findsOneWidget);
    await finishApp(tester);
  });

  testWidgets('problemas de sync: "Editar" una transacción huérfana y elegir otra cuenta la desbloquea', (tester) async {
    await tester.runAsync(() async {
      await h.store.saveAccount(id: 'cash', type: 'efectivo', name: 'Cartera');
      await h.store.saveTransaction(
          id: 'orf', type: 'expense', amount: Money.parse('40'), accountId: 'cuenta-borrada', categoryId: Catalog.comida, occurredOn: monthDate(0, 1), description: 'Huérfano');
      await (h.db.update(h.db.syncOutbox)..where((o) => o.recordId.equals('orf')))
          .write(const SyncOutboxCompanion(lastError: Value('invalid_reference'), attempts: Value(3)));
    });
    await pumpApp(tester, h);
    await tester.tap(find.text('Revisar'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('editar-orf')));
    await tester.pumpAndSettle();
    expect(find.text('Editar gasto'), findsOneWidget);

    await tester.ensureVisible(find.byType(DropdownButtonFormField<String>).at(1));
    await tester.tap(find.byType(DropdownButtonFormField<String>).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Cartera').last);
    await tester.pumpAndSettle();
    await tapKey(tester, const Key('guardar-movimiento'));
    await settleDb(tester);

    final entry = (await tester.runAsync(() => h.outbox()))!.firstWhere((e) => e.recordId == 'orf');
    expect([entry.lastError, entry.attempts, entry.blocked], [null, 0, false]); // vuelve a la cola limpia
    final row = (await tester.runAsync(() => (h.db.select(h.db.transactions)..where((t) => t.id.equals('orf'))).getSingle()))!;
    expect(row.accountId, 'cash');
    await finishApp(tester);
  });

  testWidgets('un movimiento cuya cuenta se eliminó en otro dispositivo se marca con advertencia en la lista', (tester) async {
    await seed(tester);
    await tester.runAsync(() => h.db.customStatement("UPDATE accounts SET deleted_at = '2026-10-05T00:00:00.000000Z' WHERE id = 'cash'"));
    await openMovements(tester);
    // g2 ('Café') estaba en la cuenta eliminada; g1 no.
    expect(find.descendant(of: find.byKey(const Key('movimiento-g2')), matching: find.byIcon(Icons.warning_amber_rounded)), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('movimiento-g1')), matching: find.byIcon(Icons.warning_amber_rounded)), findsNothing);
    await finishApp(tester);
  });

  testWidgets('con el texto del sistema al 200% las pantallas principales no se desbordan', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await seed(tester);
    await pumpApp(tester, h);
    expect(tester.takeException(), isNull, reason: 'Inicio');
    for (final tab in ['Bancos', 'Categorías', 'Reportes', 'Perfil', 'Inicio']) {
      await goToTab(tester, tab);
      expect(tester.takeException(), isNull, reason: tab);
    }
    await tester.ensureVisible(find.byKey(const Key('ver-todos')));
    await tester.pumpAndSettle(); // la geometría se actualiza en el siguiente cuadro
    await tester.tap(find.byKey(const Key('ver-todos')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'Movimientos');
    await tester.tap(find.byKey(const Key('agregar-movimiento')));
    await tester.pumpAndSettle();
    expect(find.text('Nuevo gasto'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'Formulario');
    await finishApp(tester);
  });
}
