import '../../../core/format/dates.dart';

String periodLabel(String period) => switch (period) {
      'weekly' => 'Semanal',
      'yearly' => 'Anual',
      _ => 'Mensual',
    };

/// "hoy", "mañana", "en 5 días" (días civiles).
String relativeDays(int days) {
  if (days < 0) return 'hace ${-days} ${days == -1 ? 'día' : 'días'}';
  if (days == 0) return 'hoy';
  if (days == 1) return 'mañana';
  return 'en $days días';
}

/// "5 nov · en 3 días" para la próxima renovación de una suscripción.
String renewalText(String renewalDate, String period, DateTime today) {
  final next = nextRenewal(renewalDate, period, today);
  return '${formatDateShort(isoDate(next))} · ${relativeDays(daysBetween(today, next))}';
}
