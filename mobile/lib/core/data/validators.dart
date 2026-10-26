import '../money/money.dart';
import 'validation_exception.dart';

/// Validaciones comunes de los repositorios (espejo de las del servidor, para que un cambio válido aquí
/// casi nunca se rechace al sincronizar).

/// 12 enteros + 2 decimales, como `NUMERIC(14,2)` del servidor.
const maxCents = 99999999999999;

/// Monto > 0 y dentro de rango.
Money positiveMoney(Money m) {
  if (m.cents <= 0) throw const ValidationException('El monto debe ser mayor a 0');
  if (m.cents > maxCents) throw const ValidationException('El monto es demasiado grande');
  return m;
}

/// Nombre no vacío (sin espacios sobrantes) de a lo más [max] caracteres.
String requiredName(String raw, {required String emptyMessage, int max = 100}) {
  final name = raw.trim();
  if (name.isEmpty) throw ValidationException(emptyMessage);
  if (name.length > max) throw ValidationException('El nombre es demasiado largo (máx. $max)');
  return name;
}

/// `YYYY-MM-DD` de una fecha real (rechaza 2026-02-30 o el mes 13, que el servidor también rechazaría).
String validIsoDate(String iso) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(iso);
  if (m == null) throw const ValidationException('Fecha inválida');
  final y = int.parse(m.group(1)!);
  final mo = int.parse(m.group(2)!);
  final d = int.parse(m.group(3)!);
  final parsed = DateTime.utc(y, mo, d);
  if (parsed.year != y || parsed.month != mo || parsed.day != d) throw const ValidationException('Fecha inválida');
  return iso;
}

String? validOptionalIsoDate(String? iso) => (iso == null || iso.isEmpty) ? null : validIsoDate(iso);
