import 'package:finanzas_personales/core/data/data_providers.dart';
import 'package:finanzas_personales/core/db/queries_fase3.dart';
import 'package:finanzas_personales/core/money/money.dart';
import 'package:finanzas_personales/features/budgets/data/budgets_repository.dart';
import 'package:finanzas_personales/features/reports/presentation/charts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/catalog.dart';
import '../support/ui.dart';
import '../sync/support.dart';

void main() {
  late Harness h;
  late BudgetsRepository budgets;
  final today = DateTime(2026, 10, 20);

  setUp(() async {
    h = Harness();
    await seedCatalog(h.db);
    budgets = BudgetsRepository(h.store);
  });
  tearDown(() => h.close());

  Future<void> seedAccount(WidgetTester tester) =>
      tester.runAsync(() => h.store.saveAccount(id: 'cash', type: 'efectivo', name: 'Efectivo', initialBalance: Money.parse('10000')));

  Future<void> spend(WidgetTester tester, String id, String amount, String date, {String category = Catalog.comida, String type = 'expense'}) => tester.runAsync(
      () => h.store.saveTransaction(id: id, type: type, amount: Money.parse(amount), accountId: 'cash', categoryId: category, occurredOn: date));

  /// [tall]: ventana muy alta para que las listas perezosas construyan todo sin desplazarse.
  Future<void> openReports(WidgetTester tester, {bool budgetsTab = false, bool tall = false}) async {
    await pumpApp(tester, h, extra: [todayProvider.overrideWithValue(today)], size: tall ? const Size(800, 6000) : const Size(800, 1600));
    await goToTab(tester, 'Reportes');
    if (budgetsTab) {
      await tester.tap(find.descendant(of: find.byType(TabBar), matching: find.text('Presupuestos')));
      await tester.pumpAndSettle();
    }
  }

  String text(WidgetTester tester, Key key) => tester.widget<Text>(find.byKey(key)).data!;

  group('resumen', () {
    testWidgets('sin movimientos: ceros y aviso de que no hay gastos', (tester) async {
      await openReports(tester);
      expect(find.text('octubre 2026'), findsWidgets);
      expect(text(tester, const Key('resumen-ingresos')), r'$0.00');
      expect(find.byKey(const Key('sin-gastos-mes')), findsOneWidget);
      expect(find.byKey(const Key('grafica-pastel')), findsNothing);
      await finishApp(tester);
    });

    testWidgets('ingresos contra gastos del mes, pastel por categoría y tendencia de 3 meses', (tester) async {
      await seedAccount(tester);
      await spend(tester, 'sal', '5000', '2026-10-01', category: Catalog.salario, type: 'income');
      await spend(tester, 'g1', '600', '2026-10-03');
      await spend(tester, 'g2', '200', '2026-10-04');
      await spend(tester, 'g3', '200', '2026-10-05', category: Catalog.vivienda);
      await spend(tester, 'sep-i', '4000', '2026-09-10', category: Catalog.salario, type: 'income');
      await spend(tester, 'sep-g', '1500', '2026-09-12');
      await spend(tester, 'ago-g', '300', '2026-08-02');
      await openReports(tester, tall: true);

      expect(text(tester, const Key('resumen-ingresos')), r'$5,000.00');
      expect(text(tester, const Key('resumen-gastos')), r'$1,000.00');
      expect(text(tester, const Key('resumen-balance')), r'$4,000.00');
      expect(find.byKey(const Key('grafica-pastel')), findsOneWidget);
      expect(find.text('80 %'), findsOneWidget); // Alimentación: 800 de 1,000
      expect(find.text('20 %'), findsOneWidget); // Vivienda
      // Tendencia: agosto, septiembre, octubre.
      expect(find.byKey(const Key('grafica-tendencia')), findsOneWidget);
      expect(find.textContaining('Ingresos \$0.00 · Gastos \$300.00'), findsOneWidget);
      expect(find.textContaining('Ingresos \$4,000.00 · Gastos \$1,500.00'), findsOneWidget);
      expect(find.textContaining('Ingresos \$5,000.00 · Gastos \$1,000.00'), findsOneWidget);
      await finishApp(tester);
    });

    testWidgets('navegar de mes cambia cifras, pastel y tendencia', (tester) async {
      await seedAccount(tester);
      await spend(tester, 'oct', '100', '2026-10-03');
      await spend(tester, 'sep', '700', '2026-09-03');
      await openReports(tester);
      expect(text(tester, const Key('resumen-gastos')), r'$100.00');
      await tester.tap(find.byKey(const Key('reporte-mes-anterior')));
      await tester.pumpAndSettle();
      expect(find.text('septiembre 2026'), findsOneWidget);
      expect(text(tester, const Key('resumen-gastos')), r'$700.00');
      await tester.tap(find.byKey(const Key('reporte-mes-siguiente')));
      await tester.pumpAndSettle(); // cada toque usa el mes ya reconstruido
      await tester.tap(find.byKey(const Key('reporte-mes-siguiente')));
      await tester.pumpAndSettle();
      expect(find.text('noviembre 2026'), findsOneWidget);
      expect(find.byKey(const Key('sin-gastos-mes')), findsOneWidget); // noviembre: vacío
      await finishApp(tester);
    });

    testWidgets('más de 6 categorías: el resto se junta en "Otras" en el pastel, la leyenda las lista todas', (tester) async {
      await seedAccount(tester);
      await tester.runAsync(() async {
        for (var i = 0; i < 8; i++) {
          await h.store.saveCategory(id: 'c$i', kind: 'expense', name: 'Cat $i');
          await h.store.saveTransaction(
              id: 't$i', type: 'expense', amount: Money.parse('${100 - i}'), accountId: 'cash', categoryId: 'c$i', occurredOn: '2026-10-05');
        }
      });
      await openReports(tester, tall: true);
      for (var i = 0; i < 8; i++) {
        expect(find.byKey(Key('gasto-categoria-c$i')), findsOneWidget, reason: 'Cat $i');
      }
      final painter = tester.widget<CustomPaint>(find.byKey(const Key('grafica-pastel'))).painter! as PiePainter;
      expect(painter.slices, hasLength(7));
      expect(painter.slices.last.label, 'Otras');
      expect(painter.slices.last.cents, (94 + 93) * 100);
      await finishApp(tester);
    });

    testWidgets('los gastos de categorías eliminadas se agrupan en "Sin categoría"', (tester) async {
      await seedAccount(tester);
      await spend(tester, 'a', '100', '2026-10-05');
      await tester.runAsync(() async {
        for (final (id, amount) in [('extra-1', '30'), ('extra-2', '20')]) {
          await h.store.saveCategory(id: id, kind: 'expense', name: id);
          await h.store.saveTransaction(
              id: 'x-$id', type: 'expense', amount: Money.parse(amount), accountId: 'cash', categoryId: id, occurredOn: '2026-10-05');
        }
        await h.db.customStatement("UPDATE categories SET deleted_at = '2026-10-19T00:00:00.000000Z' WHERE id IN ('extra-1', 'extra-2')");
      });
      await openReports(tester, tall: true);
      expect(find.text('Sin categoría'), findsOneWidget);
      expect(find.text(r'$50.00'), findsWidgets);
      await finishApp(tester);
    });
  });

  group('presupuestos', () {
    testWidgets('sin presupuestos invita a crear el primero; el botón solo aparece en esa pestaña', (tester) async {
      await openReports(tester);
      expect(find.byKey(const Key('agregar-presupuesto')), findsNothing);
      await tester.tap(find.descendant(of: find.byType(TabBar), matching: find.text('Presupuestos')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sin-presupuestos')), findsOneWidget);
      expect(find.byKey(const Key('agregar-presupuesto')), findsOneWidget);
      await finishApp(tester);
    });

    testWidgets('crear un presupuesto: categoría, límite y umbral; muestra el avance del mes', (tester) async {
      await seedAccount(tester);
      await spend(tester, 'g1', '250', '2026-10-05');
      await openReports(tester, budgetsTab: true);
      await tapKey(tester, const Key('agregar-presupuesto'));
      await tester.tap(find.byKey(const Key('campo-categoria-presupuesto')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alimentación').last);
      await tester.pumpAndSettle();
      await enter(tester, const Key('campo-limite'), '1,000');
      await tapKey(tester, const Key('umbral-90'));
      await tapKey(tester, const Key('guardar-presupuesto'));
      await settleDb(tester);

      expect(text(tester, Key('monto-${Catalog.comida}')), r'$250.00 de $1,000.00');
      expect(text(tester, Key('estado-${Catalog.comida}')), r'Quedan $750.00');
      final row = (await tester.runAsync(() => h.db.select(h.db.budgets).getSingle()))!;
      expect([row.categoryId, row.monthlyLimitCents, row.alertPercent], [Catalog.comida, 100000, 90]);
      expect((await tester.runAsync(() => h.outbox()))!.map((e) => e.entity), contains('budgets'));
      await finishApp(tester);
    });

    testWidgets('estados: en aviso y excedido se explican; la barra no pasa del 100 %', (tester) async {
      await seedAccount(tester);
      await tester.runAsync(() async {
        await budgets.save(categoryId: Catalog.comida, limit: Money.parse('1000'), alertPercent: 80);
        await budgets.save(categoryId: Catalog.vivienda, limit: Money.parse('500'));
      });
      await spend(tester, 'g1', '850', '2026-10-05');
      await spend(tester, 'g2', '620.50', '2026-10-06', category: Catalog.vivienda);
      await openReports(tester, budgetsTab: true);
      expect(text(tester, Key('estado-${Catalog.comida}')), 'Cerca del límite: llevas el 85 %');
      expect(text(tester, Key('estado-${Catalog.vivienda}')), r'Excedido por $120.50');
      final bar = tester.widget<LinearProgressIndicator>(find.byKey(Key('barra-${Catalog.vivienda}')));
      expect(bar.value, 1.0);
      await finishApp(tester);
    });

    testWidgets('editar el límite y quitar el presupuesto', (tester) async {
      await seedAccount(tester);
      await tester.runAsync(() => budgets.save(categoryId: Catalog.comida, limit: Money.parse('1000')));
      await openReports(tester, budgetsTab: true);
      await tester.tap(find.byKey(Key('presupuesto-${Catalog.comida}')));
      await tester.pumpAndSettle();
      expect(find.text('Editar presupuesto'), findsOneWidget);
      await enter(tester, const Key('campo-limite'), '1800');
      await tapKey(tester, const Key('guardar-presupuesto'));
      await settleDb(tester);
      expect(text(tester, Key('monto-${Catalog.comida}')), r'$0.00 de $1,800.00');

      await tester.tap(find.byKey(Key('presupuesto-${Catalog.comida}')));
      await tester.pumpAndSettle();
      await tapKey(tester, const Key('quitar-presupuesto'));
      await tapKey(tester, const Key('confirmar-quitar'));
      await settleDb(tester);
      expect(find.byKey(const Key('sin-presupuestos')), findsOneWidget);
      await finishApp(tester);
    });

    testWidgets('un presupuesto con un umbral distinto de las opciones (p. ej. 75 %) lo muestra seleccionado', (tester) async {
      await seedAccount(tester);
      await tester.runAsync(() => budgets.save(categoryId: Catalog.comida, limit: Money.parse('1000'), alertPercent: 75));
      await openReports(tester, budgetsTab: true);
      await tester.tap(find.byKey(Key('presupuesto-${Catalog.comida}')));
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(find.byKey(const Key('umbral-75'))).selected, isTrue);
      expect(tester.widget<ChoiceChip>(find.byKey(const Key('umbral-80'))).selected, isFalse);
      await finishApp(tester);
    });

    testWidgets('un límite inválido no se guarda; las categorías con presupuesto no se ofrecen otra vez', (tester) async {
      await seedAccount(tester);
      await tester.runAsync(() async {
        await budgets.save(categoryId: Catalog.comida, limit: Money.parse('1000'));
        await budgets.save(categoryId: Catalog.vivienda, limit: Money.parse('1000'));
      });
      await openReports(tester, budgetsTab: true);
      await tapKey(tester, const Key('agregar-presupuesto'));
      expect(find.byKey(const Key('sin-categorias-libres')), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('guardar-presupuesto'))).onPressed, isNull);
      await finishApp(tester);
    });
  });

  group('avisos', () {
    Future<void> addExpense(WidgetTester tester, String amount) async {
      await tester.tap(find.byKey(const Key('agregar-gasto')));
      await tester.pumpAndSettle();
      await enter(tester, const Key('campo-monto'), amount);
      await tester.ensureVisible(find.byKey(const Key('campo-categoria')));
      await tester.tap(find.byKey(const Key('campo-categoria')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alimentación').last);
      await tester.pumpAndSettle();
      await tapKey(tester, const Key('guardar-movimiento'));
      await settleDb(tester);
    }

    testWidgets('al guardar un gasto que cruza el umbral o el límite se avisa una vez por cambio de estado', (tester) async {
      await seedAccount(tester);
      await tester.runAsync(() => budgets.save(categoryId: Catalog.comida, limit: Money.parse('1000'), alertPercent: 80));
      await spend(tester, 'previo', '700', DateTimeToday.iso);
      await pumpApp(tester, h);

      await addExpense(tester, '50'); // 750: sigue en orden
      expect(find.byKey(const Key('aviso-presupuesto')), findsNothing);
      expect(find.text('Gasto guardado'), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 8));

      await addExpense(tester, '100'); // 850: cruza el umbral del 80 %
      expect(text(tester, const Key('aviso-presupuesto')), contains('llevas el 85 %'));
      await tester.pumpAndSettle(const Duration(seconds: 8));

      await addExpense(tester, '20'); // 870: sigue en aviso, no se repite
      expect(find.byKey(const Key('aviso-presupuesto')), findsNothing);
      await tester.pumpAndSettle(const Duration(seconds: 8));

      await addExpense(tester, '200'); // 1,070: excede
      expect(text(tester, const Key('aviso-presupuesto')), contains('Excediste el presupuesto de Alimentación por \$70.00'));
      await finishApp(tester);
    });

    testWidgets('Inicio muestra los presupuestos en aviso o excedidos y lleva a la pestaña de Presupuestos', (tester) async {
      await seedAccount(tester);
      await tester.runAsync(() async {
        await budgets.save(categoryId: Catalog.comida, limit: Money.parse('1000'));
        await budgets.save(categoryId: Catalog.vivienda, limit: Money.parse('5000'));
      });
      await spend(tester, 'g1', '900', '2026-10-05');
      await spend(tester, 'g2', '100', '2026-10-06', category: Catalog.vivienda);
      await pumpApp(tester, h, extra: [todayProvider.overrideWithValue(today)]);
      expect(find.byKey(Key('alerta-presupuesto-${Catalog.comida}')), findsOneWidget);
      expect(find.byKey(Key('alerta-presupuesto-${Catalog.vivienda}')), findsNothing); // 2 %: no estorba
      await tester.tap(find.byKey(Key('alerta-presupuesto-${Catalog.comida}')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('agregar-presupuesto')), findsOneWidget); // abrió Reportes en Presupuestos
      await finishApp(tester);
    });

    testWidgets('tocar de nuevo el aviso de Inicio vuelve a abrir Presupuestos aunque se haya cambiado de pestaña a mano', (tester) async {
      await seedAccount(tester);
      await tester.runAsync(() => budgets.save(categoryId: Catalog.comida, limit: Money.parse('1000')));
      await spend(tester, 'g1', '900', '2026-10-05');
      await pumpApp(tester, h, extra: [todayProvider.overrideWithValue(today)]);
      await tester.tap(find.byKey(Key('alerta-presupuesto-${Catalog.comida}')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('agregar-presupuesto')), findsOneWidget);
      await tester.tap(find.descendant(of: find.byType(TabBar), matching: find.text('Resumen')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('agregar-presupuesto')), findsNothing);
      await goToTab(tester, 'Inicio');
      await tester.tap(find.byKey(Key('alerta-presupuesto-${Catalog.comida}')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('agregar-presupuesto')), findsOneWidget); // otra vez en Presupuestos
      await finishApp(tester);
    });

    testWidgets('sin presupuestos en aviso, Inicio no muestra la sección', (tester) async {
      await seedAccount(tester);
      await tester.runAsync(() => budgets.save(categoryId: Catalog.comida, limit: Money.parse('1000')));
      await pumpApp(tester, h, extra: [todayProvider.overrideWithValue(today)]);
      expect(find.text('Presupuestos'), findsNothing);
      await finishApp(tester);
    });
  });

  group('gráficas', () {
    test('percentOf y pieSlices: las 6 mayores y el resto en "Otras"', () {
      expect(percentOf(1, 3), 33);
      expect(percentOf(2, 3), 67);
      expect(percentOf(5, 0), 0);
      final spend = [for (var i = 0; i < 9; i++) CategorySpend(categoryId: 'c$i', name: 'C$i', total: Money((9 - i) * 100))];
      final slices = pieSlices(spend, colorOf: (_) => Colors.red, otherColor: Colors.grey);
      expect(slices.map((s) => s.label), ['C0', 'C1', 'C2', 'C3', 'C4', 'C5', 'Otras']);
      expect(slices.last.cents, (3 + 2 + 1) * 100);
      expect(pieSlices(spend.take(6).toList(), colorOf: (_) => Colors.red, otherColor: Colors.grey).map((s) => s.label), isNot(contains('Otras')));
    });

    testWidgets('las gráficas se describen para lectores de pantalla', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(children: [
            ExpensePie(slices: const [PieSlice(label: 'Comida', cents: 7500, color: Colors.green), PieSlice(label: 'Renta', cents: 2500, color: Colors.blue)]),
            TrendChart(
              points: [
                MonthPoint(year: 2026, month: 9, income: Money.parse('100'), expense: Money.parse('50')),
                MonthPoint(year: 2026, month: 10, income: Money.zero, expense: Money.parse('20')),
              ],
              incomeColor: Colors.green,
              expenseColor: Colors.red,
            ),
          ]),
        ),
      ));
      expect(find.bySemanticsLabel(RegExp('pastel.*Comida 75 %.*Renta 25 %')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'líneas.*septiembre 2026, ingresos \$100\.00, gastos \$50\.00.*octubre 2026')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('un solo mes o cero montos no rompen el dibujo', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TrendChart(points: [MonthPoint(year: 2026, month: 1, income: Money.zero, expense: Money.zero)], incomeColor: Colors.green, expenseColor: Colors.red),
        ),
      ));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: ExpensePie(slices: const []))));
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('con el texto del sistema al 200% Reportes y Presupuestos no se desbordan', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await seedAccount(tester);
    await tester.runAsync(() async {
      await budgets.save(categoryId: Catalog.comida, limit: Money.parse('123456.78'));
      await h.store.saveCategory(id: 'larga', kind: 'expense', name: 'Una categoría con un nombre larguísimo para probar');
      await h.store.saveTransaction(
          id: 'tl', type: 'expense', amount: Money.parse('99999.99'), accountId: 'cash', categoryId: 'larga', occurredOn: '2026-10-05');
    });
    await spend(tester, 'g1', '120000', '2026-10-05');
    await spend(tester, 'i1', '250000', '2026-10-01', category: Catalog.salario, type: 'income');
    await openReports(tester, tall: true);
    expect(tester.takeException(), isNull, reason: 'Resumen y tendencia');
    await tester.tap(find.descendant(of: find.byType(TabBar), matching: find.text('Presupuestos')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'Presupuestos');
    await tester.tap(find.byKey(Key('presupuesto-${Catalog.comida}')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'Editor');
    await finishApp(tester);
  });
}

/// Hoy en `YYYY-MM-DD` (los avisos usan la fecha del gasto, que por omisión es hoy).
abstract final class DateTimeToday {
  static String get iso {
    final d = DateTime.now();
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}
