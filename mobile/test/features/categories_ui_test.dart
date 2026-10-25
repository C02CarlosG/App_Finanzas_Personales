import 'package:finanzas_personales/core/money/money.dart';
import 'package:finanzas_personales/features/categories/presentation/category_editor.dart';
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

  Future<void> openCategorias(WidgetTester tester) async {
    await pumpApp(tester, h);
    await goToTab(tester, 'Categorías');
  }

  Future<void> tapTab(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(of: find.byType(TabBar), matching: find.text(label)));
    await tester.pumpAndSettle();
  }

  testWidgets('muestra ingresos y gastos en pestañas; las del sistema llevan etiqueta', (tester) async {
    await openCategorias(tester);
    expect(find.text('Salario / quincena'), findsOneWidget);
    expect(find.text('Préstamo cobrado'), findsOneWidget);
    expect(find.text('Sistema'), findsOneWidget);
    expect(find.text('Vivienda'), findsNothing); // es de gastos
    await tapTab(tester, 'Gastos');
    expect(find.text('Vivienda'), findsOneWidget);
    expect(find.text('Alimentación'), findsOneWidget);
    await finishApp(tester);
  });

  testWidgets('agregar una categoría de gastos con color desde la pestaña activa', (tester) async {
    await openCategorias(tester);
    await tapTab(tester, 'Gastos');
    await tapKey(tester, const Key('agregar-categoria'));
    expect(find.text('Nueva categoría de gastos'), findsOneWidget);
    await enter(tester, const Key('campo-nombre-categoria'), '  Mascotas ');
    await tapKey(tester, const Key('color-#C62828'));
    await tapKey(tester, const Key('guardar-categoria'));
    await settleDb(tester);

    expect(find.text('Mascotas'), findsOneWidget);
    final row = (await tester.runAsync(() => (h.db.select(h.db.categories)..where((c) => c.name.equals('Mascotas'))).getSingle()))!;
    expect([row.kind, row.color, row.isSystem], ['expense', '#C62828', false]);
    expect((await tester.runAsync(() => h.outbox()))!.single.entity, 'categories');
    await finishApp(tester);
  });

  testWidgets('un nombre repetido (sin distinguir mayúsculas) se rechaza con un mensaje', (tester) async {
    await openCategorias(tester);
    await tapKey(tester, const Key('agregar-categoria')); // pestaña Ingresos
    await enter(tester, const Key('campo-nombre-categoria'), 'salario / QUINCENA');
    await tapKey(tester, const Key('guardar-categoria'));
    await settleDb(tester);
    expect(find.text('Ya existe una categoría con ese nombre'), findsOneWidget);
    expect((await tester.runAsync(() => h.db.select(h.db.categories).get()))!.length, 4); // sin cambios
    await finishApp(tester);
  });

  testWidgets('editar renombra y cambia el color', (tester) async {
    await openCategorias(tester);
    await tester.tap(find.byKey(const Key('categoria-${Catalog.salario}')));
    await tester.pumpAndSettle();
    await enter(tester, const Key('campo-nombre-categoria'), 'Quincena');
    await tapKey(tester, const Key('color-#1565C0'));
    await tapKey(tester, const Key('guardar-categoria'));
    await settleDb(tester);
    expect(find.text('Quincena'), findsOneWidget);
    final row = (await tester.runAsync(() => (h.db.select(h.db.categories)..where((c) => c.id.equals(Catalog.salario))).getSingle()))!;
    expect([row.name, row.color], ['Quincena', '#1565C0']);
    await finishApp(tester);
  });

  testWidgets('la categoría del sistema solo permite cambiar el color y no se puede eliminar', (tester) async {
    await openCategorias(tester);
    await tester.tap(find.byKey(const Key('categoria-${Catalog.prestamoCobrado}')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const Key('campo-nombre-categoria'))).enabled, isFalse);
    expect(find.byKey(const Key('eliminar-categoria')), findsNothing);
    expect(find.textContaining('solo puedes cambiar su color'), findsOneWidget);
    await tapKey(tester, const Key('color-#AD1457'));
    await tapKey(tester, const Key('guardar-categoria'));
    await settleDb(tester);
    final row = (await tester.runAsync(() => (h.db.select(h.db.categories)..where((c) => c.id.equals(Catalog.prestamoCobrado))).getSingle()))!;
    expect([row.name, row.color], ['Préstamo cobrado', '#AD1457']);
    await finishApp(tester);
  });

  testWidgets('eliminar: con movimientos se explica; sin movimientos se quita', (tester) async {
    await tester.runAsync(() async {
      await h.store.saveAccount(id: 'a1', type: 'efectivo', name: 'Cartera');
      await h.store.saveTransaction(
          id: 't1', type: 'expense', amount: Money.parse('10'), accountId: 'a1', categoryId: Catalog.comida, occurredOn: '2026-10-19');
    });
    await openCategorias(tester);
    await tapTab(tester, 'Gastos');

    await tester.tap(find.byKey(const Key('categoria-${Catalog.comida}')));
    await tester.pumpAndSettle();
    await tapKey(tester, const Key('eliminar-categoria'));
    await settleDb(tester);
    expect(find.textContaining('tiene movimientos'), findsOneWidget);
    await tester.tap(find.byKey(const Key('guardar-categoria'))); // cierra la hoja guardando sin cambios
    await settleDb(tester);

    await tester.tap(find.byKey(const Key('categoria-${Catalog.vivienda}')));
    await tester.pumpAndSettle();
    await tapKey(tester, const Key('eliminar-categoria'));
    await settleDb(tester);
    expect(find.text('Vivienda'), findsNothing);
    await finishApp(tester);
  });

  test('categoryDisplayColor: usa el color propio y, si falta o es inválido, uno estable de la paleta (nunca gris)', () {
    expect(categoryDisplayColor('#C62828', 'Comida'), const Color(0xFFC62828));
    final fallback = categoryDisplayColor(null, 'Alimentación');
    expect(fallback, isNot(Colors.grey));
    expect(categoryDisplayColor(null, 'Alimentación'), fallback); // estable
    expect(categoryDisplayColor('no-es-color', 'Alimentación'), fallback);
    expect(categoryDisplayColor('#12345', 'Alimentación'), fallback);
    expect(categoryDisplayColor(null, null), isNot(Colors.grey));
    expect({for (final n in ['Alimentación', 'Vivienda', 'Salud', 'Transporte', 'Ocio']) categoryDisplayColor(null, n)}.length, greaterThan(1));
  });
}
