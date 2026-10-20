import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  late Harness h;
  setUp(() => h = Harness());
  tearDown(() => h.close());

  test('al reiniciar, el desfase de reloj aprendido se restaura antes del primer sello', () async {
    await h.db.writeState('clock_offset_ms', '5000'); // aprendido en una sesión anterior (+5 s)
    await h.store.saveCategory(id: 'cat-1', kind: 'expense', name: 'A');
    expect((await h.outbox()).single.clientUpdatedAt, '2026-10-20T12:00:05.000000Z');
  });

  test('al reiniciar, un sello nuevo nunca es menor que uno ya guardado (aunque el desfase cambie)', () async {
    // Un registro con sello "futuro" respecto al reloj del dispositivo (p. ej. se aprendió un desfase mayor).
    await h.seedFromServer(pullPage(categories: [serverCategory('cat-1', 'Vivienda', clientUpdatedAt: '2026-10-20T13:00:00.000000Z')]));
    await h.store.saveCategory(id: 'cat-1', kind: 'expense', name: 'Editada');
    final stamp = (await h.outbox()).single.clientUpdatedAt;
    expect(stamp.compareTo('2026-10-20T13:00:00.000000Z'), greaterThan(0));
  });

  test('sin datos ni desfase guardados, los sellos siguen el reloj local', () async {
    await h.store.saveCategory(id: 'cat-1', kind: 'expense', name: 'A');
    expect((await h.outbox()).single.clientUpdatedAt, '2026-10-20T12:00:00.000000Z');
  });
}
