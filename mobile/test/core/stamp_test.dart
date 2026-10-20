import 'package:finanzas_personales/core/sync/stamp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formatStamp usa UTC con 6 decimales', () {
    expect(formatStamp(DateTime.utc(2026, 10, 20, 15, 4, 5, 123)), '2026-10-20T15:04:05.123000Z');
    expect(formatStamp(DateTime.utc(2026, 1, 2, 3, 4, 5)), '2026-01-02T03:04:05.000000Z');
  });

  test('comparar strings equivale a comparar fechas', () {
    final a = formatStamp(DateTime.utc(2026, 10, 20, 15, 4, 5, 123));
    final b = formatStamp(DateTime.utc(2026, 10, 20, 15, 4, 5, 124));
    expect(a.compareTo(b), lessThan(0));
    // Un sello del servidor con microsegundos sigue ordenando bien frente a uno local.
    expect(a.compareTo('2026-10-20T15:04:05.123456Z'), lessThan(0));
  });

  test('StampClock aplica el desfase con el servidor', () {
    final clock = StampClock(now: () => DateTime.utc(2026, 10, 20, 12), offset: const Duration(minutes: 7));
    expect(clock.stamp(), '2026-10-20T12:07:00.000000Z');
  });

  test('los sellos son estrictamente crecientes aunque el reloj no avance o retroceda', () {
    var t = DateTime.utc(2026, 10, 20, 12);
    final clock = StampClock(now: () => t);
    final a = clock.stamp();
    final b = clock.stamp(); // misma hora
    t = t.subtract(const Duration(seconds: 5)); // ajuste de reloj hacia atrás
    final c = clock.stamp();
    expect(a.compareTo(b), lessThan(0));
    expect(b.compareTo(c), lessThan(0));
    expect(c, matches(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z$')));
  });
}
