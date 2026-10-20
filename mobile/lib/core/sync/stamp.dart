/// Sellos de tiempo para sincronización: ISO 8601 UTC con **6 decimales**
/// (`2026-10-20T15:04:05.123000Z`), igual que los que devuelve el servidor.
///
/// Con el mismo formato y longitud, comparar los strings equivale a comparar
/// las fechas, y no se pierde precisión que el cursor del pull necesita.
String formatStamp(DateTime t) {
  final u = t.toUtc();
  String p(int n, int w) => n.toString().padLeft(w, '0');
  final micros = u.millisecond * 1000 + u.microsecond;
  return '${p(u.year, 4)}-${p(u.month, 2)}-${p(u.day, 2)}'
      'T${p(u.hour, 2)}:${p(u.minute, 2)}:${p(u.second, 2)}.${p(micros, 6)}Z';
}

DateTime parseStamp(String s) => DateTime.parse(s);

/// Reloj que sella ediciones con la hora local corregida por el desfase con el servidor
/// (`offset = server_time − hora local`, ver docs/sync.md §3).
///
/// Los sellos son **estrictamente crecientes** dentro de la sesión (+1 µs si la hora no avanzó o
/// retrocedió por un ajuste de reloj): el motor de sync decide si un registro se editó
/// mientras su lote iba en vuelo comparando sellos, así que dos ediciones nunca pueden empatar.
class StampClock {
  StampClock({DateTime Function()? now, this.offset = Duration.zero}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  Duration offset;
  int _lastMicros = 0;

  DateTime now() => _now().toUtc().add(offset);

  String stamp() {
    final micros = now().microsecondsSinceEpoch;
    _lastMicros = micros > _lastMicros ? micros : _lastMicros + 1;
    return formatStamp(DateTime.fromMicrosecondsSinceEpoch(_lastMicros, isUtc: true));
  }
}
