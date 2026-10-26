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

/// Días del mes (febrero con año bisiesto).
int daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

/// Suma [months] meses conservando el día; si el mes destino es más corto, usa su último día
/// (31 ene + 1 mes = 28/29 feb).
DateTime addMonths(DateTime d, int months) {
  final total = d.year * 12 + (d.month - 1) + months;
  final year = total ~/ 12;
  final month = total % 12 + 1;
  final day = d.day > daysInMonth(year, month) ? daysInMonth(year, month) : d.day;
  return DateTime(year, month, day);
}

/// Próxima renovación en o después de [today], a partir de una renovación conocida [renewalIso] y su
/// periodicidad (`weekly` | `monthly` | `yearly`). Siempre se cuenta desde la fecha original: un cobro del
/// día 31 vuelve al 31 en los meses que lo tienen aunque febrero lo haya acortado.
DateTime nextRenewal(String renewalIso, String period, DateTime today) {
  final base = parseIsoDate(renewalIso);
  final start = DateTime(today.year, today.month, today.day);
  if (!base.isBefore(start)) return base;
  switch (period) {
    case 'weekly':
      final weeks = (daysBetween(base, start) + 6) ~/ 7; // redondeo hacia arriba, en días civiles (sin horario de verano)
      return DateTime(base.year, base.month, base.day + weeks * 7);
    case 'yearly':
      var years = start.year - base.year;
      var candidate = addMonths(base, years * 12);
      if (candidate.isBefore(start)) {
        years += 1;
        candidate = addMonths(base, years * 12);
      }
      return candidate;
    default: // monthly
      var months = (start.year - base.year) * 12 + (start.month - base.month);
      var candidate = addMonths(base, months);
      if (candidate.isBefore(start)) {
        months += 1;
        candidate = addMonths(base, months);
      }
      return candidate;
  }
}

/// Días desde [from] hasta [to] contando días civiles (no horas).
int daysBetween(DateTime from, DateTime to) =>
    DateTime.utc(to.year, to.month, to.day).difference(DateTime.utc(from.year, from.month, from.day)).inDays;
