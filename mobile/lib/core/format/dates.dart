/// Fechas en español de México sin depender de `intl` (formatos simples y fijos).
const _monthsShort = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];
const _monthsLong = [
  'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
  'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
];

String _two(int n) => n.toString().padLeft(2, '0');

/// `2026-10-19` (formato que guarda el servidor y la base local).
String isoDate(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';

DateTime parseIsoDate(String iso) {
  final p = iso.split('-');
  return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
}

/// `19 oct 2026`
String formatDate(String iso) {
  final d = parseIsoDate(iso);
  return '${d.day} ${_monthsShort[d.month - 1]} ${d.year}';
}

/// `19 oct` (sin año, para listas del año en curso)
String formatDateShort(String iso) {
  final d = parseIsoDate(iso);
  return '${d.day} ${_monthsShort[d.month - 1]}';
}

/// `octubre 2026`
String monthLabel(int year, int month) => '${_monthsLong[month - 1]} $year';

/// Primer día del mes y primer día del mes siguiente (rango `[from, to)`).
({String from, String to}) monthRange(int year, int month) {
  final next = month == 12 ? DateTime(year + 1, 1, 1) : DateTime(year, month + 1, 1);
  return (from: isoDate(DateTime(year, month, 1)), to: isoDate(next));
}

({int year, int month}) previousMonth(int year, int month) =>
    month == 1 ? (year: year - 1, month: 12) : (year: year, month: month - 1);

({int year, int month}) nextMonth(int year, int month) =>
    month == 12 ? (year: year + 1, month: 1) : (year: year, month: month + 1);
