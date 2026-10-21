import 'package:finanzas_personales/core/money/money.dart';
import 'package:finanzas_personales/core/network/api_exception.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  late Harness h;
  setUp(() => h = Harness());
  tearDown(() => h.close());

  Future<void> seedBasics() async {
    await h.store.saveCategory(id: 'cat-1', kind: 'expense', name: 'Vivienda');
    await h.store.saveAccount(id: 'acc-1', type: 'efectivo', name: 'Cartera', initialBalance: Money.parse('100'));
    await h.store.saveTransaction(
        id: 'tx-1', type: 'expense', amount: Money.parse('50.5'), accountId: 'acc-1', categoryId: 'cat-1', occurredOn: '2026-10-19');
  }

  Future<void> acceptAll() async => h.api.onPush = (changes) async => pushResponse([
        for (final c in changes) result(c, 'applied', record: c['deleted'] == true ? null : okRecord(c)),
      ]);

  /// Respuesta que deja todo pendiente (para probar el pull con ediciones locales sin resolver).
  void keepPending() => h.api.onPush =
      (changes) async => pushResponse([for (final c in changes) result(c, 'rejected', code: 'conflict')]);

  group('push', () {
    test('envía altas padres→hijos con dinero como string y sellos de 6 decimales', () async {
      await seedBasics();
      await acceptAll();
      final report = await h.engine.run();
      final changes = h.api.pushes.single;
      expect(changes.map((c) => c['table']).toList(), ['categories', 'accounts', 'transactions']);
      expect(changes.last['data'], containsPair('amount', '50.50'));
      expect(changes.last['deleted'], false);
      expect(changes.last['client_updated_at'], matches(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z$')));
      expect(report.pushed, 3);
      expect(await h.outbox(), isEmpty);
    });

    test('los borrados van después de las altas y en orden hijos→padres', () async {
      await h.seedFromServer(pullPage(
        categories: [serverCategory('cat-s', 'Servidor')],
        accounts: [serverAccount('acc-s', 'Cuenta')],
        transactions: [serverTx('tx-s', accountId: 'acc-s', categoryId: 'cat-s')],
      ));
      await h.store.delete('categories', 'cat-s');
      await h.store.delete('accounts', 'acc-s');
      await h.store.delete('transactions', 'tx-s');
      await h.store.saveCategory(id: 'cat-new', kind: 'income', name: 'Nueva');
      await acceptAll();
      await h.engine.run();
      expect(h.api.pushes.single.map((c) => '${c['table']}:${c['deleted']}').toList(),
          ['categories:false', 'transactions:true', 'accounts:true', 'categories:true']);
    });

    test('applied: adopta el registro del servidor (updated_at) y vacía la outbox', () async {
      await seedBasics();
      await acceptAll();
      await h.engine.run();
      final tx = await h.tx('tx-1');
      expect(tx.updatedAt, '2026-10-20T11:00:00.000000Z');
      expect(tx.amountCents, 5050);
    });

    test('stale: el servidor gana y el cliente adopta su versión', () async {
      await seedBasics();
      h.api.onPush = (changes) async => pushResponse([
            for (final c in changes)
              result(c, c['table'] == 'transactions' ? 'stale' : 'applied',
                  record: c['table'] == 'transactions' ? serverTx('tx-1', amount: '99.00', description: 'del servidor') : okRecord(c)),
          ]);
      await h.engine.run();
      final tx = await h.tx('tx-1');
      expect([tx.amountCents, tx.description], [9900, 'del servidor']);
      expect(await h.outbox(), isEmpty);
    });

    test('edición hecha mientras el lote iba en vuelo: no se pisa la fila y la outbox la conserva', () async {
      await seedBasics();
      h.api.onPush = (changes) async {
        h.advance(const Duration(seconds: 5));
        await h.store.saveTransaction(
            id: 'tx-1', type: 'expense', amount: Money.parse('77'), accountId: 'acc-1', categoryId: 'cat-1', occurredOn: '2026-10-19');
        return pushResponse([for (final c in changes) result(c, 'applied', record: okRecord(c))]);
      };
      await h.engine.run();
      final tx = await h.tx('tx-1');
      expect(tx.amountCents, 7700); // la edición más nueva sigue intacta
      expect(tx.updatedAt, isNotNull); // pero ya sabe que existe en el servidor
      expect((await h.outbox()).map((e) => e.recordId), ['tx-1']);
    });

    test('borrado de algo que el servidor no conocía (record null) elimina la fila local', () async {
      await h.store.saveCategory(id: 'cat-1', kind: 'expense', name: 'X');
      await h.store.enqueue('categories', 'cat-1', h.clock.stamp(), deleted: true);
      h.api.onPush = (changes) async => pushResponse([for (final c in changes) result(c, 'applied', record: null)]);
      await h.engine.run();
      expect(await h.db.select(h.db.categories).get(), isEmpty);
      expect(await h.outbox(), isEmpty);
    });

    test('rejected in_use: el registro borrado "resucita" con la versión del servidor', () async {
      await h.seedFromServer(pullPage(accounts: [serverAccount('acc-1', 'Cartera')]));
      await h.store.delete('accounts', 'acc-1');
      expect((await h.db.select(h.db.accounts).getSingle()).deletedAt, isNotNull);
      h.api.onPush = (changes) async => pushResponse(
          [for (final c in changes) result(c, 'rejected', code: 'in_use', record: serverAccount('acc-1', 'Cartera'))]);
      await h.engine.run();
      expect((await h.db.select(h.db.accounts).getSingle()).deletedAt, isNull);
      expect(await h.outbox(), isEmpty);
    });

    test('duplicate_name sin record: fusiona (transacciones → categoría existente, la local se elimina)', () async {
      await seedBasics();
      h.api.onPush = (changes) async => pushResponse([
            for (final c in changes)
              switch (c['table']) {
                'categories' => result(c, 'rejected', code: 'duplicate_name', extra: {'conflicting_id': 'cat-existing'}),
                'transactions' => result(c, 'invalid', code: 'invalid_reference'),
                _ => result(c, 'applied', record: okRecord(c)),
              },
          ]);
      await h.engine.run();
      expect(await h.db.select(h.db.categories).get(), isEmpty);
      expect((await h.tx('tx-1')).categoryId, 'cat-existing');
      final pending = await h.outbox();
      expect(pending.map((e) => e.recordId), ['tx-1']); // reenviada con la categoría correcta
      expect(pending.single.lastError, isNull); // el intento fallido anterior no se hereda
      expect(pending.single.attempts, 0);
    });

    test('duplicate_name con record (renombre rechazado): conserva la categoría con su nombre anterior', () async {
      await h.seedFromServer(pullPage(categories: [serverCategory('cat-1', 'Mascotas')]));
      await h.store.saveCategory(id: 'cat-1', kind: 'expense', name: 'Viajes');
      h.api.onPush = (changes) async => pushResponse([
            for (final c in changes)
              result(c, 'rejected', code: 'duplicate_name', record: serverCategory('cat-1', 'Mascotas'), extra: {'conflicting_id': 'otra'}),
          ]);
      await h.engine.run();
      expect((await h.db.select(h.db.categories).getSingle()).name, 'Mascotas');
      expect(await h.outbox(), isEmpty);
    });

    test('invalid_reference se conserva para reintentar; los demás invalid se bloquean y no se reenvían', () async {
      await seedBasics();
      h.api.onPush = (changes) async => pushResponse([
            for (final c in changes)
              switch (c['table']) {
                'transactions' => result(c, 'invalid', code: 'invalid_reference'),
                'accounts' => result(c, 'invalid', code: 'validation_error', extra: {'message': 'nombre vacío'}),
                _ => result(c, 'applied', record: okRecord(c)),
              },
          ]);
      final report = await h.engine.run();
      final pending = {for (final e in await h.outbox()) e.recordId: e};
      expect(pending['tx-1']!.blocked, isFalse);
      expect(pending['tx-1']!.attempts, 1);
      expect(pending['acc-1']!.blocked, isTrue);
      expect(pending['acc-1']!.lastError, contains('validation_error'));
      expect(report.retained, 2);

      // Segundo ciclo: solo se reintenta la transacción (la bloqueada no se reenvía).
      h.api.pushes.clear();
      h.api.onPush = (changes) async => pushResponse([for (final c in changes) result(c, 'applied', record: okRecord(c))]);
      await h.engine.run();
      expect(h.api.pushes.single.map((c) => c['id']), ['tx-1']);
    });

    test('batch_too_slow: reintenta con lotes de la mitad', () async {
      for (var i = 0; i < 250; i++) {
        await h.store.saveCategory(id: 'cat-$i', kind: 'expense', name: 'C$i');
      }
      var first = true;
      h.api.onPush = (changes) async {
        if (first) {
          first = false;
          throw apiError('batch_too_slow', 503);
        }
        return pushResponse([for (final c in changes) result(c, 'applied', record: okRecord(c))]);
      };
      await h.engine.run();
      expect(h.api.pushes.map((p) => p.length).toList(), [200, 100, 100, 50]);
      expect(await h.outbox(), isEmpty);
    });

    test('retry_later: espera con retroceso exponencial y reintenta', () async {
      final delays = <Duration>[];
      await h.close();
      h = Harness(delays: delays);
      await seedBasics();
      var calls = 0;
      h.api.onPush = (changes) async {
        calls++;
        if (calls <= 2) throw apiError('retry_later', 503);
        return pushResponse([for (final c in changes) result(c, 'applied', record: okRecord(c))]);
      };
      await h.engine.run();
      expect(delays, [const Duration(seconds: 2), const Duration(seconds: 4)]);
      expect(await h.outbox(), isEmpty);
    });

    test('sin red: el ciclo falla y la outbox queda intacta', () async {
      await seedBasics();
      h.api.onPush = (_) async => throw const ApiException.network();
      await expectLater(h.engine.run(), throwsA(isA<ApiException>()));
      expect(await h.outbox(), hasLength(3));
      expect(h.engine.isSyncing, isFalse);
    });

    test('respuesta perdida + borrado posterior: queda tombstone y el borrado SÍ se envía (no resucita)', () async {
      await h.store.saveCategory(id: 'cat-1', kind: 'expense', name: 'Comida');
      h.api.onPush = (_) async => throw const ApiException.network(); // el servidor aplicó, pero la respuesta se perdió
      await expectLater(h.engine.run(), throwsA(isA<ApiException>()));
      expect(h.engine.isSyncing, isFalse);

      await h.store.delete('categories', 'cat-1');
      final row = await h.db.select(h.db.categories).getSingle();
      expect(row.deletedAt, isNotNull); // NO se eliminó físicamente
      final entry = (await h.outbox()).single;
      expect([entry.deleted, entry.maybeSent], [true, true]);

      h.api.onPush = (changes) async => pushResponse([
            for (final c in changes)
              result(c, 'applied', record: serverCategory('cat-1', 'Comida', deletedAt: '2026-10-20T11:59:00.000000Z')),
          ]);
      await h.engine.run();
      expect(h.api.pushes.last.single['deleted'], isTrue);
      expect((await h.db.select(h.db.categories).getSingle()).deletedAt, '2026-10-20T11:59:00.000000Z');
      expect(await h.outbox(), isEmpty);
    });

    test('maybe_sent se conserva si el usuario edita de nuevo antes de la respuesta', () async {
      await h.store.saveCategory(id: 'cat-1', kind: 'expense', name: 'A');
      h.api.onPush = (_) async => throw const ApiException.network();
      await expectLater(h.engine.run(), throwsA(isA<ApiException>()));
      await h.store.saveCategory(id: 'cat-1', kind: 'expense', name: 'B'); // reemplaza el renglón
      expect((await h.outbox()).single.maybeSent, isTrue);
      await h.store.delete('categories', 'cat-1');
      expect((await h.db.select(h.db.categories).getSingle()).deletedAt, isNotNull);
    });

    test('duplicate_name sin record NO fusiona si el usuario renombró la categoría con el lote en vuelo', () async {
      await seedBasics();
      h.api.onPush = (changes) async {
        h.advance(const Duration(seconds: 5));
        await h.store.saveCategory(id: 'cat-1', kind: 'expense', name: 'Renombrada por el usuario');
        return pushResponse([
          for (final c in changes)
            switch (c['table']) {
              'categories' => result(c, 'rejected', code: 'duplicate_name', extra: {'conflicting_id': 'cat-existing'}),
              _ => result(c, 'applied', record: okRecord(c)),
            },
        ]);
      };
      await h.engine.run();
      final cat = await h.db.select(h.db.categories).getSingle();
      expect(cat.name, 'Renombrada por el usuario'); // sigue existiendo
      expect((await h.tx('tx-1')).categoryId, 'cat-1'); // sin reasignar
      expect((await h.outbox()).map((e) => e.recordId), contains('cat-1')); // se reenviará
    });

    test('un solo ciclo a la vez: run() concurrente devuelve el mismo Future', () async {
      await seedBasics();
      await acceptAll();
      final a = h.engine.run();
      final b = h.engine.run();
      expect(identical(a, b), isTrue);
      await a;
      expect(h.api.pushes, hasLength(1));
    });
  });

  group('pull', () {
    test('aplica bancos y registros, guarda el cursor y lo reutiliza', () async {
      h.api.pullQueue.add(pullPage(
        banks: [
          {'id': 'b1', 'name': 'BBVA México', 'logo_key': 'bbva', 'updated_at': '2026-10-01T00:00:00.000000Z', 'deleted_at': null}
        ],
        categories: [serverCategory('cat-1', 'Vivienda')],
        accounts: [serverAccount('acc-1', 'Cartera')],
        transactions: [serverTx('tx-1', amount: '1234.50')],
        next: 'c1',
      ));
      final report = await h.engine.run();
      expect(report.pulled, 4);
      expect((await h.db.select(h.db.banks).getSingle()).logoKey, 'bbva');
      expect((await h.tx('tx-1')).amountCents, 123450);
      expect(await h.db.readState('cursor'), 'c1');
      await h.engine.run();
      expect(h.api.pullCursors, [null, 'c1']);
    });

    test('pagina con has_more y guarda el cursor página por página', () async {
      h.api.pullQueue
        ..add(pullPage(transactions: [serverTx('tx-1')], next: 'p1', hasMore: true))
        ..add(pullPage(transactions: [serverTx('tx-2')], next: 'p2'));
      await h.engine.run();
      expect(h.api.pullCursors, [null, 'p1']);
      expect(await h.db.select(h.db.transactions).get(), hasLength(2));
      expect(await h.db.readState('cursor'), 'p2');
    });

    test('si falla la página 2, queda guardado hasta el cursor de la página 1', () async {
      h.api.pullQueue.add(pullPage(transactions: [serverTx('tx-1')], next: 'p1', hasMore: true));
      var calls = 0;
      final engine = h.engineWith(_ThrowingSecondPull(h.api, () => ++calls));
      await expectLater(engine.run(), throwsA(isA<ApiException>()));
      expect(await h.db.readState('cursor'), 'p1');
      expect(await h.db.select(h.db.transactions).get(), hasLength(1));
    });

    test('un tombstone del servidor descarta las ediciones locales pendientes', () async {
      await h.seedFromServer(pullPage(transactions: [serverTx('tx-1')]));
      await h.store.saveTransaction(
          id: 'tx-1', type: 'expense', amount: Money.parse('9'), accountId: 'acc-1', categoryId: 'cat-1', occurredOn: '2026-10-19');
      keepPending();
      h.api.pullQueue.add(pullPage(transactions: [serverTx('tx-1', deletedAt: '2026-10-20T11:50:00.000000Z')], next: 'c2'));
      await h.engine.run();
      expect((await h.tx('tx-1')).deletedAt, isNotNull);
      expect(await h.outbox(), isEmpty);
    });

    test('un borrado local pendiente gana a una edición del servidor, sin importar fechas', () async {
      await h.seedFromServer(pullPage(transactions: [serverTx('tx-1')]));
      await h.store.delete('transactions', 'tx-1');
      keepPending();
      h.api.pullQueue.add(pullPage(
          transactions: [serverTx('tx-1', amount: '500.00', clientUpdatedAt: '2030-01-01T00:00:00.000000Z')], next: 'c2'));
      await h.engine.run();
      final tx = await h.tx('tx-1');
      expect(tx.deletedAt, isNotNull);
      expect(tx.amountCents, 5000); // la edición del servidor no se aplicó
      expect((await h.outbox()).single.deleted, isTrue);
    });

    test('una edición local más nueva que la del servidor se conserva', () async {
      await h.seedFromServer(pullPage(transactions: [serverTx('tx-1')]));
      await h.store.saveTransaction(
          id: 'tx-1', type: 'expense', amount: Money.parse('9'), accountId: 'acc-1', categoryId: 'cat-1', occurredOn: '2026-10-19');
      keepPending();
      h.api.pullQueue.add(pullPage(
          transactions: [serverTx('tx-1', amount: '500.00', clientUpdatedAt: '2026-10-20T11:00:00.000000Z')], next: 'c2'));
      await h.engine.run();
      expect((await h.tx('tx-1')).amountCents, 900);
      expect(await h.outbox(), hasLength(1));
    });

    test('una edición local más vieja que la del servidor se sobrescribe', () async {
      await h.seedFromServer(pullPage(transactions: [serverTx('tx-1')]));
      await h.store.saveTransaction(
          id: 'tx-1', type: 'expense', amount: Money.parse('9'), accountId: 'acc-1', categoryId: 'cat-1', occurredOn: '2026-10-19');
      keepPending();
      h.api.pullQueue.add(pullPage(
          transactions: [serverTx('tx-1', amount: '500.00', clientUpdatedAt: '2026-10-20T13:00:00.000000Z')], next: 'c2'));
      await h.engine.run();
      expect((await h.tx('tx-1')).amountCents, 50000);
      expect(await h.outbox(), isEmpty);
    });

    test('aprende el desfase de reloj con server_time y lo persiste', () async {
      h.advance(const Duration(seconds: 3)); // el reloj del dispositivo va 3 s adelantado
      await h.engine.run();
      expect(h.clock.offset, const Duration(seconds: -3));
      expect(await h.db.readState('clock_offset_ms'), '-3000');
    });
  });

  group('LocalStore', () {
    test('un registro que nunca se envió se elimina físicamente y sale de la outbox', () async {
      await seedBasics();
      await h.store.delete('transactions', 'tx-1');
      expect(await h.db.select(h.db.transactions).get(), isEmpty);
      expect((await h.outbox()).map((e) => e.entity), isNot(contains('transactions')));
    });

    test('un registro ya sincronizado queda como tombstone local con renglón deleted', () async {
      await h.seedFromServer(pullPage(transactions: [serverTx('tx-1')]));
      await h.store.delete('transactions', 'tx-1');
      expect((await h.tx('tx-1')).deletedAt, isNotNull);
      expect((await h.outbox()).single.deleted, isTrue);
    });

    test('ediciones sucesivas se coalescen en un solo renglón con el sello más reciente', () async {
      await h.store.saveCategory(id: 'cat-1', kind: 'expense', name: 'A');
      final first = (await h.outbox()).single.clientUpdatedAt;
      h.advance(const Duration(seconds: 1));
      await h.store.saveCategory(id: 'cat-1', kind: 'expense', name: 'B');
      final entries = await h.outbox();
      expect(entries, hasLength(1));
      expect(entries.single.clientUpdatedAt.compareTo(first), greaterThan(0));
      expect((await h.db.select(h.db.categories).getSingle()).name, 'B');
    });

    test('borrar durante una sincronización deja tombstone aunque el registro no tenga updated_at', () async {
      await seedBasics();
      h.api.onPush = (changes) async {
        await h.store.delete('transactions', 'tx-1'); // el ciclo está en curso
        return pushResponse([for (final c in changes) result(c, 'applied', record: okRecord(c))]);
      };
      await h.engine.run();
      expect((await h.tx('tx-1')).deletedAt, isNotNull);
      expect((await h.outbox()).single.deleted, isTrue);
    });
  });
}

/// Delegado que falla en la segunda llamada a pull.
class _ThrowingSecondPull extends FakeSyncApi {
  _ThrowingSecondPull(this._inner, this._count);
  final FakeSyncApi _inner;
  final int Function() _count;

  @override
  Future<Map<String, dynamic>> pull({String? cursor, int limit = 500}) {
    if (_count() >= 2) throw const ApiException.network();
    return _inner.pull(cursor: cursor, limit: limit);
  }
}
