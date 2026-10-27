import 'dart:io';

import 'package:excel/excel.dart';
import 'package:finanzas_personales/core/data/validation_exception.dart';
import 'package:finanzas_personales/core/money/money.dart';
import 'package:finanzas_personales/features/export/data/export_models.dart';
import 'package:finanzas_personales/features/export/data/export_repository.dart';
import 'package:finanzas_personales/features/export/data/export_service.dart';
import 'package:finanzas_personales/features/export/data/file_sharer.dart';
import 'package:finanzas_personales/features/export/data/pdf_builder.dart';
import 'package:finanzas_personales/features/export/data/xlsx_builder.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/catalog.dart';
import '../sync/support.dart';

void main() {
  late Harness h;
  late ExportRepository repo;
  final now = DateTime(2026, 10, 27, 14, 5);

  setUp(() async {
    h = Harness();
    repo = ExportRepository(h.db);
    await seedCatalog(h.db);
    await h.store.saveAccount(id: 'cartera', type: 'efectivo', name: 'Cartera', initialBalance: Money.parse('500'));
    await h.store.saveAccount(id: 'bbva', type: 'banco', bankId: Catalog.bbva, name: 'BBVA Nómina', cardType: 'debito');
    Future<void> tx(String id, String type, String amount, String account, String category, String date, {String? description, String? who}) =>
        h.store.saveTransaction(
            id: id, type: type, amount: Money.parse(amount), accountId: account, categoryId: category, occurredOn: date, description: description, counterparty: who);
    await tx('t1', 'income', '15000', 'bbva', Catalog.salario, '2026-10-15', description: 'Quincena');
    await tx('t2', 'expense', '0.10', 'cartera', Catalog.comida, '2026-10-02', description: 'Dulce');
    await tx('t3', 'expense', '0.20', 'cartera', Catalog.comida, '2026-10-02', description: '=SUMA(A1:A9) Cafetería ñandú');
    await tx('t4', 'income', '800.50', 'cartera', Catalog.prestamoCobrado, '2026-10-31', who: 'Luis Pérez');
    await tx('t5', 'expense', '4500', 'bbva', Catalog.vivienda, '2026-10-01', description: 'Renta');
    await tx('fuera-antes', 'expense', '99', 'cartera', Catalog.comida, '2026-09-30');
    await tx('fuera-despues', 'expense', '77', 'cartera', Catalog.comida, '2026-11-01');
    await tx('borrado', 'expense', '55', 'cartera', Catalog.comida, '2026-10-10');
    await h.store.delete('transactions', 'borrado');
  });
  tearDown(() => h.close());

  Future<ExportData> load({String from = '2026-10-01', String to = '2026-11-01', String? type, String? account, String? category}) =>
      repo.load(ExportRequest(from: from, to: to, type: type, accountId: account, categoryId: category),
          userName: 'Ana López', userEmail: 'ana@example.com', now: now);

  group('ExportRepository', () {
    test('trae el periodo [desde, hasta) del más antiguo al más reciente, sin borrados ni otros meses', () async {
      final d = await load();
      expect(d.rows.map((r) => r.id), ['t5', 't2', 't3', 't1', 't4']);
      expect(d.lastDay, '2026-10-31');
      expect(d.count, 5);
      expect(d.baseFileName, 'finanzas_2026-10-01_a_2026-10-31');
    });

    test('totales en centavos exactos (0.10 + 0.20 es exactamente 0.30) y neto', () async {
      final d = await load(type: 'expense', category: Catalog.comida);
      expect(d.totals.expense.cents, 30);
      expect(d.totals.income.cents, 0);
      final all = await load();
      expect([all.totals.income.cents, all.totals.expense.cents, all.totals.net.cents], [1580050, 450030, 1130020]);
    });

    test('por categoría: ingresos primero, de mayor a menor, y el número de movimientos', () async {
      final d = await load();
      expect([for (final c in d.byCategory) (c.kind, c.name, c.total.cents, c.count)], [
        ('income', 'Salario / quincena', 1500000, 1),
        ('income', 'Préstamo cobrado', 80050, 1),
        ('expense', 'Vivienda', 450000, 1),
        ('expense', 'Alimentación', 30, 2),
      ]);
    });

    test('filtros de tipo, cuenta y categoría y su descripción para el encabezado', () async {
      expect((await load(type: 'income')).rows.map((r) => r.id), ['t1', 't4']);
      expect((await load(account: 'cartera')).rows.map((r) => r.id), ['t2', 't3', 't4']);
      final d = await load(type: 'expense', account: 'bbva', category: Catalog.vivienda);
      expect(d.rows.map((r) => r.id), ['t5']);
      expect(d.filtersDescription, 'Solo gastos · Cuenta: BBVA Nómina · Categoría: Vivienda');
      expect((await load()).filtersDescription, 'Todos los movimientos');
    });

    test('una categoría borrada aparece como «Sin categoría»', () async {
      await h.store.saveTransaction(
          id: 'huerfano', type: 'expense', amount: Money.parse('10'), accountId: 'cartera', categoryId: 'no-existe', occurredOn: '2026-10-20');
      final d = await load();
      expect(d.byCategory.map((c) => c.name), contains('Sin categoría'));
    });

    test('un periodo vacío o invertido no es válido; sin movimientos todo queda en cero', () async {
      await expectLater(load(from: '2026-10-31', to: '2026-10-31'), throwsA(isA<ValidationException>()));
      await expectLater(load(from: '2026-11-01', to: '2026-10-01'), throwsA(isA<ValidationException>()));
      final d = await load(from: '2027-01-01', to: '2027-02-01');
      expect([d.count, d.totals.net.cents, d.byCategory.length], [0, 0, 0]);
    });
  });

  group('Excel', () {
    num numOf(CellValue? v) => switch (v) { DoubleCellValue(:final value) => value, IntCellValue(:final value) => value, _ => fail('no es número: $v') };
    String textOf(CellValue? v) => v is TextCellValue ? v.value.toString() : fail('no es texto: $v');

    test('hoja «Movimientos»: fechas reales, importes numéricos, columnas Ingreso/Gasto y totales exactos', () async {
      final bytes = buildXlsx(await load());
      final book = Excel.decodeBytes(bytes);
      expect(book.tables.keys, containsAll(['Resumen', 'Movimientos']));
      expect(book.tables.keys, isNot(contains('Sheet1')));
      final rows = book['Movimientos'].rows;

      expect(rows.first.map((c) => textOf(c?.value)).toList(), ['Fecha', 'Tipo', 'Categoría', 'Cuenta', 'Descripción', 'Persona', 'Ingreso', 'Gasto']);
      // t5 (1 oct, renta): gasto en la columna Gasto, Ingreso vacío
      final renta = rows[1];
      expect(renta[0]?.value, isA<DateCellValue>().having((d) => (d.year, d.month, d.day), 'fecha', (2026, 10, 1)));
      expect([textOf(renta[1]?.value), textOf(renta[2]?.value), textOf(renta[3]?.value), textOf(renta[4]?.value)], ['Gasto', 'Vivienda', 'BBVA Nómina', 'Renta']);
      expect(renta[6]?.value, isNull);
      expect(numOf(renta[7]?.value), 4500);
      // 0.10 y 0.20 llegan como números y suman 0.30 en la fila de totales
      expect([numOf(rows[2][7]?.value), numOf(rows[3][7]?.value)], [0.1, 0.2]);
      final totals = rows.last;
      expect(textOf(totals[0]?.value), 'Totales');
      expect([numOf(totals[6]?.value), numOf(totals[7]?.value)], [15800.5, 4500.3]);
      // el préstamo cobrado lleva a la persona en su columna
      expect(textOf(rows[5][5]?.value), 'Luis Pérez');
      expect(numOf(rows[5][6]?.value), 800.5);
    });

    test('un texto que parece fórmula se guarda como texto, no se evalúa', () async {
      final book = Excel.decodeBytes(buildXlsx(await load()));
      final cell = book['Movimientos'].rows[3][4]?.value;
      expect(cell, isA<TextCellValue>());
      expect(textOf(cell), '=SUMA(A1:A9) Cafetería ñandú');
    });

    test('hoja «Resumen»: periodo, filtros, totales y categorías', () async {
      final book = Excel.decodeBytes(buildXlsx(await load(type: 'expense')));
      final rows = book['Resumen'].rows;
      String cell(int r, int c) => rows[r][c]?.value?.toString() ?? '';
      expect(cell(0, 0), contains('Reporte de movimientos'));
      final byLabel = {for (final r in rows) if (r.isNotEmpty && r[0]?.value != null) r[0]!.value.toString(): r};
      expect(byLabel['Periodo']![1]?.value.toString(), '1 oct 2026 al 31 oct 2026');
      expect(byLabel['Filtros']![1]?.value.toString(), 'Solo gastos');
      expect(byLabel['Preparado para']![1]?.value.toString(), 'Ana López (ana@example.com)');
      expect(numOf(byLabel['Gastos']![1]?.value), 4500.3);
      expect(numOf(byLabel['Ingresos']![1]?.value), 0);
      expect(numOf(byLabel['Movimientos']![1]?.value), 3);
    });
  });

  group('PDF', () {
    test('genera un PDF válido de varias páginas cuando hay muchos movimientos', () async {
      for (var i = 0; i < 120; i++) {
        await h.store.saveTransaction(
            id: 'm$i', type: 'expense', amount: Money.parse('${i + 1}.50'), accountId: 'cartera', categoryId: Catalog.comida,
            occurredOn: '2026-10-${(i % 28 + 1).toString().padLeft(2, '0')}', description: 'Compra número $i con descripción larga para ocupar espacio');
      }
      final bytes = await buildPdf(await load());
      expect(String.fromCharCodes(bytes.sublist(0, 5)), '%PDF-');
      final pages = int.parse(RegExp(r'/Type/Pages/Kids\[[^\]]*\]/Count (\d+)').firstMatch(String.fromCharCodes(bytes))!.group(1)!);
      expect(pages, greaterThan(2), reason: 'la tabla se parte en páginas');
      expect(bytes.length, greaterThan(5000));
    });

    test('caracteres que Helvetica no tiene (emojis, comillas tipográficas) no rompen la generación', () async {
      await h.store.saveTransaction(
          id: 'raro', type: 'expense', amount: Money.parse('10'), accountId: 'cartera', categoryId: Catalog.comida,
          occurredOn: '2026-10-20', description: '🍕 Pizza “con comillas” – guión 日本');
      final bytes = await buildPdf(await load());
      expect(String.fromCharCodes(bytes.sublist(0, 5)), '%PDF-');
      final book = Excel.decodeBytes(buildXlsx(await load()));
      expect(book['Movimientos'].rows.any((r) => r[4]?.value.toString().contains('🍕 Pizza') ?? false), isTrue, reason: 'el Excel sí conserva todo el texto');
    });

    test('pdfSafe: pasa a ASCII las comillas y guiones tipográficos, conserva acentos y marca lo que no cabe', () {
      expect(pdfSafe('Cafetería ñandú Ü ¿Qué?'), 'Cafetería ñandú Ü ¿Qué?');
      expect(pdfSafe('“Hola” – ‘tía’… —'), '"Hola" - \'tía\'... -');
      expect(pdfSafe('Pizza 🍕🍕 日本 👨‍👩‍👧'), 'Pizza ? ? ?');
      expect(pdfSafe('a\nb\tc\u0000d'), 'a b cd');
      expect(pdfSafe(''), '');
    });

    test('sin movimientos también genera el PDF, con el aviso', () async {
      final bytes = await buildPdf(await load(from: '2027-01-01', to: '2027-02-01'));
      expect(String.fromCharCodes(bytes.sublist(0, 5)), '%PDF-');
    });

    test('escribe el PDF de muestra para revisarlo a mano (acentos y ñ)', () async {
      final dir = Platform.environment['EXPORT_SAMPLE_DIR'];
      if (dir == null) return;
      final data = await load();
      File('$dir/${data.baseFileName}.pdf').writeAsBytesSync(await buildPdf(data));
      File('$dir/${data.baseFileName}.xlsx').writeAsBytesSync(buildXlsx(data));
    });
  });

  group('ExportService', () {
    test('genera el nombre y el tipo MIME según el formato y entrega el archivo al sharer', () async {
      final sharer = _FakeSharer();
      final service = ExportService(repository: repo, sharer: sharer);
      final data = await load();

      final xlsx = await service.exportAndShare(data, ExportFormat.excel);
      final pdf = await service.exportAndShare(data, ExportFormat.pdf);
      expect(sharer.files.map((f) => f.name), ['finanzas_2026-10-01_a_2026-10-31.xlsx', 'finanzas_2026-10-01_a_2026-10-31.pdf']);
      expect(sharer.files.map((f) => f.mimeType), [
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        'application/pdf',
      ]);
      expect(xlsx.bytes.sublist(0, 2), [0x50, 0x4B], reason: 'un .xlsx es un zip');
      expect(String.fromCharCodes(pdf.bytes.sublist(0, 4)), '%PDF');
    });
  });
}

class _FakeSharer implements FileSharer {
  final files = <ExportFile>[];
  @override
  Future<void> share(ExportFile file) async => files.add(file);
}
