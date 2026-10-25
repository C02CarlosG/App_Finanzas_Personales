import 'dart:convert';

import 'package:finanzas_personales/core/data/data_providers.dart';
import 'package:finanzas_personales/core/money/money.dart';
import 'package:finanzas_personales/core/providers.dart';
import 'package:finanzas_personales/core/storage/session_store.dart';
import 'package:finanzas_personales/core/sync/sync_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/catalog.dart';
import 'support.dart';

/// Servidor HTTP mínimo: acepta todo lo que se le envía (como un servidor sano).
MockClient fakeServer(List<String> log) => MockClient((req) async {
      log.add('${req.method} ${req.url.path}');
      if (req.url.path == '/sync/pull') return http.Response(jsonEncode(pullPage()), 200);
      if (req.url.path == '/sync/push') {
        final changes = (jsonDecode(req.body)['changes'] as List).cast<Map<String, dynamic>>();
        return http.Response(
            jsonEncode(pushResponse([for (final c in changes) result(c, 'applied', record: c['deleted'] == true ? null : okRecord(c))])), 200);
      }
      return http.Response('{}', 404);
    });

/// Prueba con el **grafo real** de providers: solo se sustituyen sesión, HTTP y base. Todas las demás
/// pruebas de interfaz sobrescriben localStore/syncEngine con valores fijos y no ven ciclos de dependencias.
void main() {
  late Harness h;
  setUp(() async {
    h = Harness();
    await seedCatalog(h.db);
  });
  tearDown(() => h.close());

  ProviderContainer realGraph(List<String> log) {
    final c = ProviderContainer(overrides: [
      sessionStoreProvider.overrideWithValue(MemorySessionStore(const Session(token: 't', userId: 'u1', email: 'a@b.c', name: 'Ana'))),
      httpClientProvider.overrideWithValue(fakeServer(log)),
      databaseProvider.overrideWithValue(h.db),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  test('guardar y borrar con el grafo real no lanza (en depuración Riverpod detecta ciclos al leer providers)', () async {
    final c = realGraph([]);
    c.listen(syncControllerProvider, (_, _) {});
    c.listen(authControllerProvider, (_, _) {});
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final store = c.read(localStoreProvider)!;
    await store.saveCategory(id: 'c1', kind: 'expense', name: 'Prueba');
    await store.saveAccount(id: 'a1', type: 'efectivo', name: 'Cartera');
    await store.delete('categories', 'c1'); // borra dentro de una transacción: debe consultar isSyncing sin lanzar
    expect((await h.db.select(h.db.categories).get()).where((x) => x.id == 'c1'), isEmpty);
  });

  test('los repositorios reales (como los usa la interfaz) guardan, editan y eliminan con el grafo real', () async {
    final c = realGraph([]);
    c.listen(syncControllerProvider, (_, _) {});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final acc = await c.read(accountsRepositoryProvider).createCashAccount(initialBalance: Money.parse('100'));
    final tx = await c.read(transactionsRepositoryProvider).add(
        type: 'expense', amount: Money.parse('10'), accountId: acc, categoryId: Catalog.comida, occurredOn: '2026-10-19');
    await c.read(transactionsRepositoryProvider).update(
        tx, type: 'expense', amount: Money.parse('12'), accountId: acc, categoryId: Catalog.comida, occurredOn: '2026-10-19');
    await c.read(transactionsRepositoryProvider).delete(tx);
    // Nunca se envió, así que borrarla la elimina físicamente (sin tombstone).
    expect(await h.db.select(h.db.transactions).get(), isEmpty);
  });

  test('una escritura programa un ciclo de sync que envía el cambio al servidor', () async {
    final log = <String>[];
    final c = realGraph(log);
    c.listen(syncControllerProvider, (_, _) {});
    await Future<void>.delayed(const Duration(milliseconds: 100)); // ciclo inicial
    log.clear();
    await c.read(localStoreProvider)!.saveCategory(id: 'c1', kind: 'expense', name: 'Nueva');
    await Future<void>.delayed(const Duration(milliseconds: 2600)); // debounce de 2 s
    expect(log, contains('POST /sync/push'));
    expect(await h.outbox(), isEmpty);
  });
}
