import 'package:drift/drift.dart' show Value;
import 'package:finanzas_personales/core/db/app_database.dart';
import 'package:finanzas_personales/core/money/money.dart';
import 'package:finanzas_personales/core/network/api_exception.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// `410 resync_required` (docs/sync.md §7): el servidor purgó tombstones que este dispositivo no vio.
void main() {
  late Harness h;
  setUp(() => h = Harness());
  tearDown(() => h.close());

  ApiException gone() => apiError('resync_required', 410);

  /// Deja el dispositivo con datos sincronizados y un cursor guardado.
  Future<void> seedSynced() async {
    await h.seedFromServer(pullPage(
      banks: [
        {'id': 'b1', 'name': 'BBVA México', 'logo_key': 'bbva', 'updated_at': '2026-10-01T00:00:00.000000Z', 'deleted_at': null}
      ],
      categories: [serverCategory('cat-1', 'Vivienda')],
      accounts: [serverAccount('acc-1', 'Cartera'), serverAccount('acc-gone', 'Purgada')],
      transactions: [serverTx('tx-1'), serverTx('tx-gone', description: 'ya no existe')],
      next: 'cursor-viejo',
    ));
    h.api.pullCursors.clear();
  }

  /// Todo lo que envíe queda pendiente (para probar el resync con cambios sin resolver).
  void keepPending() => h.api.onPush =
      (changes) async => pushResponse([for (final c in changes) result(c, 'rejected', code: 'conflict')]);

  test('410: olvida el cursor, vuelve a descargar desde cero y lo purgado en el servidor desaparece', () async {
    await seedSynced();
    h.api.pullQueue
      ..add(gone())
      ..add(pullPage(
        categories: [serverCategory('cat-1', 'Vivienda')],
        accounts: [serverAccount('acc-1', 'Cartera')],
        transactions: [serverTx('tx-1')],
        next: 'cursor-nuevo',
      ));
    final report = await h.engine.run();

    expect(report.resynced, isTrue);
    expect(h.api.pullCursors, ['cursor-viejo', null]);
    expect(await h.db.readState('cursor'), 'cursor-nuevo');
    expect((await h.db.select(h.db.accounts).get()).map((a) => a.id), ['acc-1']);
    expect((await h.db.select(h.db.transactions).get()).map((t) => t.id), ['tx-1']);
    expect(await h.db.select(h.db.banks).get(), hasLength(1), reason: 'el catálogo de bancos no se borra');
  });

  test('410: lo pendiente en la outbox sobrevive (ediciones, borrados y altas nunca enviadas)', () async {
    await seedSynced();
    await h.store.saveTransaction(
        id: 'tx-1', type: 'expense', amount: Money.parse('9'), accountId: 'acc-1', categoryId: 'cat-1', occurredOn: '2026-10-19');
    await h.store.delete('accounts', 'acc-gone');
    await h.store.saveCategory(id: 'cat-new', kind: 'income', name: 'Nueva'); // alta que nunca llegó al servidor
    keepPending();
    h.api.pullQueue
      ..add(gone())
      ..add(pullPage(
        categories: [serverCategory('cat-1', 'Vivienda')],
        accounts: [serverAccount('acc-1', 'Cartera'), serverAccount('acc-gone', 'Purgada')],
        transactions: [serverTx('tx-1', amount: '50.00')],
        next: 'cursor-nuevo',
      ));
    await h.engine.run();

    final tx = await h.tx('tx-1');
    expect(tx.amountCents, 900, reason: 'la edición local pendiente es más nueva y gana');
    expect((await h.db.select(h.db.accounts).get()).firstWhere((a) => a.id == 'acc-gone').deletedAt, isNotNull,
        reason: 'el borrado local pendiente se conserva');
    expect((await h.db.select(h.db.categories).get()).map((c) => c.id), containsAll(['cat-1', 'cat-new']));
    expect((await h.outbox()).map((e) => e.recordId), containsAll(['tx-1', 'acc-gone', 'cat-new']));
  });

  test('410: una edición pendiente de algo que el servidor ya no tiene se conserva y se reenvía', () async {
    await seedSynced();
    await h.store.saveTransaction(
        id: 'tx-gone', type: 'expense', amount: Money.parse('7'), accountId: 'acc-1', categoryId: 'cat-1', occurredOn: '2026-10-19');
    keepPending();
    h.api.pullQueue
      ..add(gone())
      ..add(pullPage(accounts: [serverAccount('acc-1', 'Cartera')], categories: [serverCategory('cat-1', 'Vivienda')], next: 'n'));
    await h.engine.run();
    expect((await h.tx('tx-gone')).amountCents, 700);
    expect((await h.outbox()).single.recordId, 'tx-gone');
  });

  test('410: el cursor se olvida en la misma transacción; si se corta a medias, el siguiente ciclo parte de cero', () async {
    await seedSynced();
    h.api.pullQueue
      ..add(gone())
      ..add(apiError('network', 0));
    await expectLater(h.engine.run(), throwsA(isA<ApiException>()));
    expect(await h.db.readState('cursor'), isNull);
    expect(await h.db.select(h.db.transactions).get(), isEmpty);

    h.api.pullCursors.clear();
    h.api.pullQueue.add(pullPage(transactions: [serverTx('tx-1')], next: 'c2'));
    final report = await h.engine.run();
    expect(h.api.pullCursors, [null]);
    expect(report.resynced, isFalse);
    expect((await h.tx('tx-1')).id, 'tx-1');
  });

  test('410 a mitad de una descarga paginada reinicia desde cero', () async {
    await seedSynced();
    h.api.pullQueue
      ..add(pullPage(transactions: [serverTx('tx-2')], next: 'p1', hasMore: true))
      ..add(gone())
      ..add(pullPage(transactions: [serverTx('tx-1')], next: 'c9'));
    final report = await h.engine.run();
    expect(h.api.pullCursors, ['cursor-viejo', 'p1', null]);
    expect(report.resynced, isTrue);
    expect((await h.db.select(h.db.transactions).get()).map((t) => t.id), ['tx-1']);
  });

  test('si el servidor insiste con 410 más de dos veces en un ciclo, se rinde con el error', () async {
    await seedSynced();
    h.api.pullQueue..add(gone())..add(gone())..add(gone());
    await expectLater(h.engine.run(), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'resync_required')));
    expect(h.api.pullCursors, ['cursor-viejo', null, null]);
  });

  test('otros errores del pull (cursor inválido, 5xx) no disparan un resync ni borran datos', () async {
    await seedSynced();
    h.api.pullQueue.add(apiError('invalid_cursor', 400));
    await expectLater(h.engine.run(), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invalid_cursor')));
    expect(await h.db.readState('cursor'), 'cursor-viejo');
    expect(await h.db.select(h.db.transactions).get(), hasLength(2));
  });

  test('las filas nunca sincronizadas (updated_at nulo) sin outbox tampoco se pierden', () async {
    await seedSynced();
    // p. ej. una fila escrita por el sembrado local o por una versión anterior
    await h.db.into(h.db.categories).insert(CategoriesCompanion.insert(
        id: 'cat-local', kind: 'expense', name: 'Local', clientUpdatedAt: '2026-10-20T10:00:00.000000Z', updatedAt: const Value(null)));
    h.api.pullQueue..add(gone())..add(pullPage(next: 'n'));
    await h.engine.run();
    expect((await h.db.select(h.db.categories).get()).map((c) => c.id), contains('cat-local'));
  });
}
