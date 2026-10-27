import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/format/dates.dart';
import '../../../core/money/money.dart';
import 'export_models.dart';
import 'xlsx_builder.dart' show generatedLabel, typeLabel;

const _ink = PdfColor.fromInt(0xFF1B1F23);
const _muted = PdfColor.fromInt(0xFF5B6770);
const _accent = PdfColor.fromInt(0xFF1F6F50);
const _headerFill = PdfColor.fromInt(0xFFE3EDE6);
const _line = PdfColor.fromInt(0xFFC9D1D6);

const _typographic = {
  '\u2018': "'", '\u2019': "'", '\u201A': "'", '\u201B': "'",
  '\u201C': '"', '\u201D': '"', '\u201E': '"',
  '\u2013': '-', '\u2014': '-', '\u2212': '-',
  '\u2026': '...', '\u2022': '-', '\u00A0': ' ', '\u20AC': 'EUR',
};

/// Texto que Helvetica (la tipografía incluida en el PDF) sí puede dibujar: solo Latin-1. Las comillas y guiones
/// «tipográficos» que escriben los teclados de los teléfonos se pasan a su equivalente simple; lo que no tiene
/// equivalente (emojis, otros alfabetos) se sustituye por «?» para que se note que faltaba algo en vez de desaparecer.
String pdfSafe(String text) {
  final out = StringBuffer();
  var lastWasSubstitute = false; // varios caracteres seguidos sin equivalente se muestran con un solo «?»
  void write(String s) {
    out.write(s);
    lastWasSubstitute = false;
  }

  for (final rune in text.runes) {
    final ch = String.fromCharCode(rune);
    final mapped = _typographic[ch];
    if (mapped != null) {
      write(mapped);
    } else if (rune == 0x0A || rune == 0x0D || rune == 0x09) {
      write(' ');
    } else if (rune < 0x20 || (rune >= 0x7F && rune < 0xA0)) {
      continue;
    } else if (rune <= 0xFF) {
      write(ch);
    } else if (rune == 0x200D || (rune >= 0xFE00 && rune <= 0xFE0F)) {
      continue; // unión y selectores de variación de los emojis compuestos
    } else if (!lastWasSubstitute) {
      out.write('?');
      lastWasSubstitute = true;
    }
  }
  return out.toString();
}

/// PDF legible e imprimible (A4) del mismo contenido que el Excel: encabezado con periodo y filtros, resumen,
/// total por categoría y el detalle de movimientos (la tabla se parte en varias páginas y repite su encabezado).
///
/// Usa la tipografía Helvetica incluida en el PDF (cubre el español: acentos y ñ); evita símbolos fuera de Latin-1.
Future<Uint8List> buildPdf(ExportData data) async {
  final doc = pw.Document(
    title: 'Finanzas Personales - ${formatDate(data.from)} al ${formatDate(data.lastDay)}',
    author: 'Finanzas Personales',
    creator: 'Finanzas Personales',
  );
  final base = pw.Font.helvetica();
  final bold = pw.Font.helveticaBold();
  final small = pw.TextStyle(fontSize: 9, color: _ink);
  final smallBold = small.copyWith(fontWeight: pw.FontWeight.bold);
  String money(Money m) => m.format();

  final safe = pdfSafe;

  pw.Widget kv(String k, String v) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 2),
        child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.SizedBox(width: 90, child: pw.Text(k, style: pw.TextStyle(fontSize: 10, color: _muted))),
          pw.Expanded(child: pw.Text(safe(v), style: const pw.TextStyle(fontSize: 10, color: _ink))),
        ]),
      );

  pw.Widget total(String label, Money value, {PdfColor color = _ink}) => pw.Expanded(
        child: pw.Container(
          padding: const pw.EdgeInsets.all(8),
          decoration: pw.BoxDecoration(border: pw.Border.all(color: _line), borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4))),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text(label, style: pw.TextStyle(fontSize: 9, color: _muted)),
            pw.SizedBox(height: 2),
            pw.Text(money(value), style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold, color: color)),
          ]),
        ),
      );

  pw.Widget table(List<String> headers, List<List<String>> rows, {Map<int, pw.TableColumnWidth>? widths, Set<int> right = const {}}) =>
      pw.TableHelper.fromTextArray(
        headers: headers,
        data: [for (final r in rows) [for (final c in r) safe(c)]],
        headerStyle: smallBold,
        cellStyle: small,
        headerDecoration: const pw.BoxDecoration(color: _headerFill),
        border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: _line, width: 0.4), bottom: pw.BorderSide(color: _line, width: 0.4)),
        cellPadding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        columnWidths: widths,
        headerAlignments: {for (final i in right) i: pw.Alignment.centerRight},
        cellAlignments: {for (final i in right) i: pw.Alignment.centerRight},
        cellAlignment: pw.Alignment.centerLeft,
        headerAlignment: pw.Alignment.centerLeft,
      );

  doc.addPage(pw.MultiPage(
    // El paquete corta en 20 páginas por defecto (unas 800 filas); un año de movimientos pasa de eso.
    maxPages: 5000,
    pageTheme: pw.PageTheme(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(36, 36, 36, 40),
      theme: pw.ThemeData.withFont(base: base, bold: bold),
    ),
    footer: (ctx) => pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
      pw.Text(safe('Finanzas Personales - ${data.userName}'), style: pw.TextStyle(fontSize: 8, color: _muted)),
      pw.Text('Página ${ctx.pageNumber} de ${ctx.pagesCount}', style: pw.TextStyle(fontSize: 8, color: _muted)),
    ]),
    build: (ctx) => [
      pw.Text('Reporte de movimientos', style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold, color: _accent)),
      pw.SizedBox(height: 8),
      kv('Periodo', '${formatDate(data.from)} al ${formatDate(data.lastDay)}'),
      kv('Filtros', data.filtersDescription),
      kv('Preparado para', '${data.userName} (${data.userEmail})'),
      kv('Generado', generatedLabel(data.generatedAt)),
      kv('Moneda', 'Peso mexicano (MXN)'),
      pw.SizedBox(height: 12),
      pw.Row(children: [
        total('Ingresos', data.totals.income, color: _accent),
        pw.SizedBox(width: 8),
        total('Gastos', data.totals.expense),
        pw.SizedBox(width: 8),
        total('Neto', data.totals.net),
        pw.SizedBox(width: 8),
        pw.Expanded(
          child: pw.Container(
            padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(border: pw.Border.all(color: _line), borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4))),
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text('Movimientos', style: pw.TextStyle(fontSize: 9, color: _muted)),
              pw.SizedBox(height: 2),
              pw.Text('${data.count}', style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold, color: _ink)),
            ]),
          ),
        ),
      ]),
      if (data.byCategory.isNotEmpty) ...[
        pw.SizedBox(height: 16),
        pw.Text('Por categoría', style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold, color: _ink)),
        pw.SizedBox(height: 4),
        table(
          ['Tipo', 'Categoría', 'Mov.', 'Total'],
          [for (final c in data.byCategory) [typeLabel(c.kind), c.name, '${c.count}', money(c.total)]],
          widths: {0: const pw.FixedColumnWidth(60), 1: const pw.FlexColumnWidth(), 2: const pw.FixedColumnWidth(40), 3: const pw.FixedColumnWidth(90)},
          right: {2, 3},
        ),
      ],
      pw.SizedBox(height: 16),
      pw.Text('Detalle de movimientos', style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold, color: _ink)),
      pw.SizedBox(height: 4),
      if (data.rows.isEmpty)
        pw.Text('No hay movimientos con estos criterios.', style: pw.TextStyle(fontSize: 10, color: _muted))
      else
        table(
          ['Fecha', 'Tipo', 'Categoría', 'Cuenta', 'Descripción', 'Importe'],
          [
            for (final t in data.rows)
              [
                formatDate(t.occurredOn),
                typeLabel(t.type),
                t.categoryName ?? 'Sin categoría',
                t.accountName ?? 'Cuenta eliminada',
                [if ((t.description ?? '').isNotEmpty) t.description!, if ((t.counterparty ?? '').isNotEmpty) '(${t.counterparty})'].join(' '),
                t.isIncome ? money(t.amount) : '-${money(t.amount)}',
              ],
          ],
          widths: {
            0: const pw.FixedColumnWidth(58),
            1: const pw.FixedColumnWidth(44),
            2: const pw.FlexColumnWidth(2),
            3: const pw.FlexColumnWidth(2),
            4: const pw.FlexColumnWidth(3),
            5: const pw.FixedColumnWidth(70),
          },
          right: {5},
        ),
    ],
  ));
  return doc.save();
}
