import 'dart:async';

import 'package:finanzas_personales/core/data/data_providers.dart';
import 'package:finanzas_personales/core/money/money.dart';
import 'package:finanzas_personales/features/export/data/file_sharer.dart';
import 'package:finanzas_personales/features/export/export_providers.dart';
import 'package:finanzas_personales/features/export/presentation/export_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/catalog.dart';
import '../support/ui.dart';
import '../sync/support.dart';

class _FakeSharer implements FileSharer {
  final files = <ExportFile>[];
  Completer<void>? gate;
  Object? error;

  @override
  Future<void> share(ExportFile file) async {
    await gate?.future;
    if (error != null) throw error!;
    files.add(file);
  }
}

void main() {
  late Harness h;
  late _FakeSharer sharer;
  final today = DateTime(2026, 10, 27);

  setUp(() {
    h = Harness();
    sharer = _FakeSharer();
  });
  tearDown(() => h.close());

  // Se siembra ANTES de montar la app: con la interfaz ya escuchando la base, una escritura desde runAsync
  // puede quedar esperando un temporizador del reloj simulado que nadie avanza.
  Future<void> seedMovements(WidgetTester tester) => tester.runAsync(() async {
        await seedCatalog(h.db);
        await h.store.saveAccount(id: 'cartera', type: 'efectivo', name: 'Cartera', initialBalance: Money.parse('500'));
        await h.store.saveAccount(id: 'bbva', type: 'banco', bankId: Catalog.bbva, name: 'BBVA Nómina', cardType: 'debito');
        Future<void> tx(String id, String type, String amount, String account, String category, String date) => h.store.saveTransaction(
            id: id, type: type, amount: Money.parse(amount), accountId: account, categoryId: category, occurredOn: date);
        await tx('i1', 'income', '15000', 'bbva', Catalog.salario, '2026-10-15');
        await tx('g1', 'expense', '4500', 'bbva', Catalog.vivienda, '2026-10-01');
        await tx('g2', 'expense', '320.50', 'cartera', Catalog.comida, '2026-10-20');
        await tx('sep', 'expense', '100', 'cartera', Catalog.comida, '2026-09-10');
        await tx('ago', 'income', '700', 'cartera', Catalog.salario, '2026-08-20');
        await tx('ene', 'expense', '50', 'cartera', Catalog.comida, '2026-01-05');
      });

  /// Abre Exportar desde Perfil, con la base sembrada y «hoy» fijo.
  // Ventana alta: las filas de la lista se construyen al vuelo y la vista previa queda debajo de los filtros.
  Future<void> openExport(WidgetTester tester, {Size size = const Size(800, 3200), double textScale = 1}) async {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await seedMovements(tester);
    await pumpApp(tester, h, size: size, extra: [
      fileSharerProvider.overrideWithValue(sharer),
      todayProvider.overrideWithValue(today),
    ]);
    await goToTab(tester, 'Perfil');
    await tester.ensureVisible(find.byKey(const Key('exportar-datos')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('exportar-datos')));
    await settleDb(tester);
  }

  String textOf(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(Key(key))).data!;

  Future<void> choose(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(Key(key)));
    await tester.pump();
    await tester.tap(find.byKey(Key(key)));
    await settleDb(tester);
  }

  group('periodos', () {
    test('cada preset y las fechas elegidas dan el rango [desde, hasta)', () {
      ({String from, String to}) r(ExportPeriod p, DateTime d, {String? f, String? t}) => exportRange(p, d, customFrom: f, customTo: t);
      expect(r(ExportPeriod.thisMonth, DateTime(2026, 10, 27)), (from: '2026-10-01', to: '2026-11-01'));
      expect(r(ExportPeriod.thisMonth, DateTime(2026, 12, 31)), (from: '2026-12-01', to: '2027-01-01'));
      expect(r(ExportPeriod.lastMonth, DateTime(2026, 10, 27)), (from: '2026-09-01', to: '2026-10-01'));
      expect(r(ExportPeriod.lastMonth, DateTime(2026, 1, 5)), (from: '2025-12-01', to: '2026-01-01'));
      expect(r(ExportPeriod.last3Months, DateTime(2026, 10, 27)), (from: '2026-08-01', to: '2026-11-01'));
      expect(r(ExportPeriod.last3Months, DateTime(2026, 2, 28)), (from: '2025-12-01', to: '2026-03-01'));
      expect(r(ExportPeriod.thisYear, DateTime(2026, 10, 27)), (from: '2026-01-01', to: '2027-01-01'));
      expect(r(ExportPeriod.custom, today, f: '2026-02-01', t: '2026-02-28'), (from: '2026-02-01', to: '2026-03-01'));
      expect(r(ExportPeriod.custom, today, f: '2026-12-31', t: '2026-12-31'), (from: '2026-12-31', to: '2027-01-01'));
      final inverted = r(ExportPeriod.custom, today, f: '2026-03-10', t: '2026-03-01');
      expect(inverted.from.compareTo(inverted.to), greaterThanOrEqualTo(0), reason: 'un rango invertido queda detectable');
    });
  });

  testWidgets('desde Perfil: «Este mes» por defecto, con la vista previa del periodo', (tester) async {
    await openExport(tester);
    expect(find.text('Exportar'), findsWidgets);
    expect(textOf(tester, 'periodo-elegido'), 'Del 1 oct 2026 al 31 oct 2026');
    expect(textOf(tester, 'vista-previa-cuenta'), '3 movimientos');
    expect(textOf(tester, 'vista-previa-ingresos'), r'Ingresos $15,000.00');
    expect(textOf(tester, 'vista-previa-gastos'), r'Gastos $4,820.50');
    expect(textOf(tester, 'vista-previa-neto'), r'Neto $10,179.50');
    await finishApp(tester);
  });

  testWidgets('genera el Excel del periodo y lo entrega a la hoja de compartir', (tester) async {
    await openExport(tester);
    await choose(tester, 'exportar-boton');
    expect(sharer.files, hasLength(1));
    final file = sharer.files.single;
    expect(file.name, 'finanzas_2026-10-01_a_2026-10-31.xlsx');
    expect(file.mimeType, 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
    expect(file.bytes.sublist(0, 2), [0x50, 0x4B]);
    expect(find.text('Listo: finanzas_2026-10-01_a_2026-10-31.xlsx'), findsOneWidget);
    await finishApp(tester);
  });

  testWidgets('genera el PDF con el formato elegido', (tester) async {
    await openExport(tester);
    await choose(tester, 'formato-pdf');
    await choose(tester, 'exportar-boton');
    final file = sharer.files.single;
    expect(file.name, 'finanzas_2026-10-01_a_2026-10-31.pdf');
    expect(file.mimeType, 'application/pdf');
    expect(String.fromCharCodes(file.bytes.sublist(0, 5)), '%PDF-');
    await finishApp(tester);
  });

  testWidgets('cambiar el periodo cambia la vista previa y el nombre del archivo', (tester) async {
    await openExport(tester);
    await choose(tester, 'periodo-lastMonth');
    expect(textOf(tester, 'periodo-elegido'), 'Del 1 sep 2026 al 30 sep 2026');
    expect(textOf(tester, 'vista-previa-cuenta'), '1 movimiento');
    await choose(tester, 'periodo-last3Months');
    expect(textOf(tester, 'periodo-elegido'), 'Del 1 ago 2026 al 31 oct 2026');
    expect(textOf(tester, 'vista-previa-cuenta'), '5 movimientos');
    await choose(tester, 'periodo-thisYear');
    expect(textOf(tester, 'periodo-elegido'), 'Del 1 ene 2026 al 31 dic 2026');
    expect(textOf(tester, 'vista-previa-cuenta'), '6 movimientos');
    await choose(tester, 'exportar-boton');
    expect(sharer.files.single.name, 'finanzas_2026-01-01_a_2026-12-31.xlsx');
    await finishApp(tester);
  });

  testWidgets('filtros: solo gastos, por cuenta y por categoría; cambiar el tipo reinicia la categoría', (tester) async {
    await openExport(tester);
    await choose(tester, 'tipo-gastos');
    expect(textOf(tester, 'vista-previa-cuenta'), '2 movimientos');
    expect(find.byKey(const Key('vista-previa-ingresos')), findsOneWidget);
    expect(textOf(tester, 'vista-previa-ingresos'), r'Ingresos $0.00');

    // El primer selector es el de cuenta y el segundo el de categoría (al elegir algo, cambia el texto que muestran).
    final accountDropdown = find.byType(DropdownButtonFormField<String?>).first;
    final categoryDropdown = find.byType(DropdownButtonFormField<String?>).last;

    // cuenta
    await tester.tap(accountDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('BBVA Nómina').last);
    await settleDb(tester);
    expect(textOf(tester, 'vista-previa-cuenta'), '1 movimiento');
    expect(textOf(tester, 'vista-previa-gastos'), r'Gastos $4,500.00');

    // otra vez «todas las cuentas», y ahora una categoría
    await tester.tap(accountDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Todas las cuentas').last);
    await settleDb(tester);
    await tester.tap(categoryDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alimentación').last);
    await settleDb(tester);
    expect(textOf(tester, 'vista-previa-cuenta'), '1 movimiento');
    expect(textOf(tester, 'vista-previa-gastos'), r'Gastos $320.50');

    // al cambiar a ingresos, la categoría de gasto ya no aplica
    await choose(tester, 'tipo-ingresos');
    expect(textOf(tester, 'vista-previa-cuenta'), '1 movimiento');
    expect(textOf(tester, 'vista-previa-ingresos'), r'Ingresos $15,000.00');
    await choose(tester, 'exportar-boton');
    expect(sharer.files, hasLength(1));
    await finishApp(tester);
  });

  testWidgets('sin movimientos en el periodo avisa y no deja exportar', (tester) async {
    await openExport(tester);
    await choose(tester, 'tipo-ingresos');
    await choose(tester, 'periodo-lastMonth');
    expect(find.byKey(const Key('vista-previa-vacia')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('exportar-boton'))).onPressed, isNull);
    expect(sharer.files, isEmpty);
    await finishApp(tester);
  });

  testWidgets('fechas elegidas: un rango invertido se avisa y no deja exportar', (tester) async {
    await openExport(tester);
    await choose(tester, 'periodo-custom');
    expect(textOf(tester, 'periodo-elegido'), 'Del 1 oct 2026 al 27 oct 2026');
    // «Desde» al 28: queda después de «Hasta» (27)
    await tester.tap(find.byKey(const Key('fecha-desde')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('28'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ACEPTAR'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('periodo-invalido')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('exportar-boton'))).onPressed, isNull);
    await finishApp(tester);
  });

  testWidgets('mientras genera, el botón se bloquea; al terminar se libera', (tester) async {
    sharer.gate = Completer<void>();
    await openExport(tester);
    await tester.ensureVisible(find.byKey(const Key('exportar-boton')));
    await tester.pump();
    // Dos toques antes de que la interfaz alcance a deshabilitar el botón: solo debe salir un archivo.
    final press = tester.widget<FilledButton>(find.byKey(const Key('exportar-boton'))).onPressed!;
    press();
    press();
    // El indicador de progreso anima sin parar: no se puede usar pumpAndSettle mientras se muestra.
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.descendant(of: find.byKey(const Key('exportar-boton')), matching: find.byType(CircularProgressIndicator)), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('exportar-boton'))).onPressed, isNull);
    sharer.gate!.complete();
    await settleDb(tester);
    expect(sharer.files, hasLength(1), reason: 'un solo archivo aunque se haya vuelto a tocar');
    expect(tester.widget<FilledButton>(find.byKey(const Key('exportar-boton'))).onPressed, isNotNull);
    await finishApp(tester);
  });

  testWidgets('si compartir falla, se explica y se puede reintentar', (tester) async {
    sharer.error = StateError('sin app para compartir');
    await openExport(tester);
    await choose(tester, 'exportar-boton');
    expect(find.byKey(const Key('error-exportacion')), findsOneWidget);
    expect(find.textContaining('No se pudo generar o compartir'), findsOneWidget);
    sharer.error = null;
    await choose(tester, 'exportar-boton');
    expect(find.byKey(const Key('error-exportacion')), findsNothing);
    expect(sharer.files, hasLength(1));
    await finishApp(tester);
  });

  testWidgets('también se llega desde Reportes y desde Movimientos', (tester) async {
    await pumpApp(tester, h, size: const Size(800, 3200), extra: [fileSharerProvider.overrideWithValue(sharer), todayProvider.overrideWithValue(today)]);
    await goToTab(tester, 'Reportes');
    await tester.tap(find.byKey(const Key('exportar-reportes')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('exportar-boton')), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    await goToTab(tester, 'Inicio');
    await tester.tap(find.byKey(const Key('ver-todos')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('exportar-movimientos')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('exportar-boton')), findsOneWidget);
    await finishApp(tester);
  });

  testWidgets('letra al 200 % en pantalla angosta: sin desbordes y todo alcanzable', (tester) async {
    await openExport(tester, size: const Size(360 * 2, 3000 * 2), textScale: 2);
    expect(tester.takeException(), isNull);
    await choose(tester, 'periodo-custom');
    expect(tester.takeException(), isNull);
    await choose(tester, 'formato-pdf');
    await choose(tester, 'exportar-boton');
    expect(sharer.files, hasLength(1));
    expect(tester.takeException(), isNull);
    await finishApp(tester);
  });
}
