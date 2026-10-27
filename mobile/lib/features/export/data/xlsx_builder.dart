import 'dart:typed_data';

import 'package:excel/excel.dart';

import '../../../core/format/dates.dart';
import '../../../core/money/money.dart';
import 'export_models.dart';

/// Los importes se escriben como **números** (no como texto) para que Excel pueda sumarlos y filtrarlos; se
/// derivan de centavos enteros, así que nunca hay un acumulado en coma flotante.
double _amount(Money m) => m.cents / 100;

final _money = NumFormat.custom(formatCode: '#,##0.00');
final _date = NumFormat.custom(formatCode: 'dd/mm/yyyy');
final _bold = CellStyle(bold: true);
final _header = CellStyle(bold: true, backgroundColorHex: ExcelColor.fromHexString('#E3EDE6'));

String generatedLabel(DateTime d) =>
    '${formatDate(isoDate(d))} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

String typeLabel(String type) => type == 'income' ? 'Ingreso' : 'Gasto';

/// Libro de Excel con dos hojas: «Resumen» (periodo, totales y total por categoría) y «Movimientos» (el detalle,
/// del más antiguo al más reciente, con una fila de totales al final).
Uint8List buildXlsx(ExportData data) {
  final excel = Excel.createExcel();
  final summary = excel['Resumen'];
  final moves = excel['Movimientos'];
  excel.delete('Sheet1');
  excel.setDefaultSheet('Resumen');

  void put(Sheet sheet, int col, int row, CellValue value, {CellStyle? style}) =>
      sheet.updateCell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row), value, cellStyle: style);

  // ---- Resumen
  put(summary, 0, 0, TextCellValue('Finanzas Personales - Reporte de movimientos'), style: CellStyle(bold: true, fontSize: 14));
  final info = [
    ('Periodo', '${formatDate(data.from)} al ${formatDate(data.lastDay)}'),
    ('Filtros', data.filtersDescription),
    ('Preparado para', '${data.userName} (${data.userEmail})'),
    ('Generado', generatedLabel(data.generatedAt)),
    ('Moneda', 'Peso mexicano (MXN)'),
  ];
  for (var i = 0; i < info.length; i++) {
    put(summary, 0, 2 + i, TextCellValue(info[i].$1), style: _bold);
    put(summary, 1, 2 + i, TextCellValue(info[i].$2));
  }
  var row = 2 + info.length + 1;
  for (final (label, value) in [('Ingresos', data.totals.income), ('Gastos', data.totals.expense), ('Neto (ingresos - gastos)', data.totals.net)]) {
    put(summary, 0, row, TextCellValue(label), style: _bold);
    put(summary, 1, row, DoubleCellValue(_amount(value)), style: CellStyle(bold: true, numberFormat: _money));
    row += 1;
  }
  put(summary, 0, row, TextCellValue('Movimientos'), style: _bold);
  put(summary, 1, row, IntCellValue(data.count), style: CellStyle(bold: true, numberFormat: NumFormat.standard_1));
  row += 2;
  put(summary, 0, row, TextCellValue('Por categoría'), style: CellStyle(bold: true, fontSize: 12));
  row += 1;
  for (final (i, h) in ['Tipo', 'Categoría', 'Movimientos', 'Total'].indexed) {
    put(summary, i, row, TextCellValue(h), style: _header);
  }
  for (final c in data.byCategory) {
    row += 1;
    put(summary, 0, row, TextCellValue(typeLabel(c.kind)));
    put(summary, 1, row, TextCellValue(c.name));
    put(summary, 2, row, IntCellValue(c.count), style: CellStyle(numberFormat: NumFormat.standard_1));
    put(summary, 3, row, DoubleCellValue(_amount(c.total)), style: CellStyle(numberFormat: _money));
  }
  summary
    ..setColumnWidth(0, 26)
    ..setColumnWidth(1, 38)
    ..setColumnWidth(2, 14)
    ..setColumnWidth(3, 16);

  // ---- Movimientos
  const headers = ['Fecha', 'Tipo', 'Categoría', 'Cuenta', 'Descripción', 'Persona', 'Ingreso', 'Gasto'];
  for (final (i, h) in headers.indexed) {
    put(moves, i, 0, TextCellValue(h), style: _header);
  }
  for (final (i, t) in data.rows.indexed) {
    final r = i + 1;
    final d = parseIsoDate(t.occurredOn);
    put(moves, 0, r, DateCellValue(year: d.year, month: d.month, day: d.day), style: CellStyle(numberFormat: _date, horizontalAlign: HorizontalAlign.Left));
    put(moves, 1, r, TextCellValue(typeLabel(t.type)));
    put(moves, 2, r, TextCellValue(t.categoryName ?? 'Sin categoría'));
    put(moves, 3, r, TextCellValue(t.accountName ?? 'Cuenta eliminada'));
    put(moves, 4, r, TextCellValue(t.description ?? ''));
    put(moves, 5, r, TextCellValue(t.counterparty ?? ''));
    put(moves, t.isIncome ? 6 : 7, r, DoubleCellValue(_amount(t.amount)), style: CellStyle(numberFormat: _money));
  }
  final totalRow = data.rows.length + 2;
  put(moves, 0, totalRow, TextCellValue('Totales'), style: _bold);
  put(moves, 6, totalRow, DoubleCellValue(_amount(data.totals.income)), style: CellStyle(bold: true, numberFormat: _money));
  put(moves, 7, totalRow, DoubleCellValue(_amount(data.totals.expense)), style: CellStyle(bold: true, numberFormat: _money));
  for (final (i, w) in [12.0, 10.0, 24.0, 24.0, 40.0, 22.0, 15.0, 15.0].indexed) {
    moves.setColumnWidth(i, w);
  }

  return Uint8List.fromList(excel.encode()!);
}
