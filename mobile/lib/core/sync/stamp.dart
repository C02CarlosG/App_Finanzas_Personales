/// Sellos de tiempo para sincronización: ISO 8601 UTC con **6 decimales**
/// (`2026-10-20T15:04:05.123000Z`), igual que los que devuelve el servidor.
///
/// Con el mismo formato y longitud, comparar los strings equivale a comparar
/// las fechas, y no se pierde precisión que el cursor del pull necesita.
String formatStamp(DateTime t) => formatStampMicros(t.toUtc().microsecondsSinceEpoch);

/// Formatea desde microsegundos desde la época **sin pasar por DateTime** para los decimales:
/// en la web un DateTime solo guarda milisegundos y se perderían los +1 µs de la monotonía.
String formatStampMicros(int micros) {
  final secs = micros ~/ 1000000;
  final frac = micros % 1000000;
  final u = DateTime.fromMillisecondsSinceEpoch(secs * 1000, isUtc: true);
  String p(int n, int w) => n.toString().padLeft(w, '0');
  return '${p(u.year, 4)}-${p(u.month, 2)}-${p(u.day, 2)}'
      'T${p(u.hour, 2)}:${p(u.minute, 2)}:${p(u.second, 2)}.${p(frac, 6)}Z';
}

/// Microsegundos desde la época de un sello `YYYY-MM-DDTHH:MM:SS.ffffffZ` (exacto también en la web).
int stampToMicros(String stamp) {
  final secs = DateTime.parse('${stamp.substring(0, 19)}Z').millisecondsSinceEpoch ~/ 1000;
  return secs * 1000000 + int.parse(stamp.substring(20, 26));
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

  /// Nunca emite un sello menor o igual que [stamp] (p. ej. el mayor que ya hay en la base al
  /// arrancar), aunque el reloj o su desfase con el servidor hayan cambiado.
  void seed(String stamp) {
    final micros = stampToMicros(stamp);
    if (micros > _lastMicros) _lastMicros = micros;
  }

  String stamp() {
    final micros = now().microsecondsSinceEpoch;
    _lastMicros = micros > _lastMicros ? micros : _lastMicros + 1;
    return formatStampMicros(_lastMicros);
  }
}
