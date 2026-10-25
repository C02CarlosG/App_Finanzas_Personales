import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:finanzas_personales/core/network/api_exception.dart';
import 'package:finanzas_personales/core/providers.dart';
import 'package:finanzas_personales/core/storage/session_store.dart';
import 'package:finanzas_personales/core/sync/sync_controller.dart';
import 'package:finanzas_personales/core/sync/sync_engine.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateProvider;
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const _session = Session(token: 't1', userId: 'u1', email: 'a@b.c', name: 'Ana');

void main() {
  late Harness h;
  setUp(() => h = Harness());
  tearDown(() => h.close());

  ProviderContainer container({bool withEngine = true, SessionStore? store}) {
    final c = ProviderContainer(overrides: [
      sessionStoreProvider.overrideWithValue(store ?? MemorySessionStore(_session)),
      databaseProvider.overrideWithValue(h.db),
      localStoreProvider.overrideWithValue(h.store),
      syncEngineProvider.overrideWithValue(withEngine ? h.engine : null),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  test('sin motor (demo o sin sesión) queda deshabilitado', () {
    final c = container(withEngine: false);
    expect(c.read(syncControllerProvider).phase, SyncPhase.disabled);
  });

  test('al arrancar sincroniza y queda en reposo con la hora del último éxito', () async {
    final c = container();
    c.listen(syncControllerProvider, (_, _) {});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final s = c.read(syncControllerProvider);
    expect(s.phase, SyncPhase.idle);
    expect(s.lastSuccess, isNotNull);
    expect(h.api.pullCursors, hasLength(1));
  });

  test('una escritura local programa un ciclo tras el debounce (varias seguidas se agrupan)', () {
    fakeAsync((async) {
      final c = container();
      c.listen(syncControllerProvider, (_, _) {});
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 100));
      final base = h.api.pullCursors.length;

      final ctl = c.read(syncControllerProvider.notifier);
      ctl.scheduleSoon();
      async.elapse(const Duration(seconds: 1));
      ctl.scheduleSoon(); // reinicia el debounce
      async.elapse(const Duration(seconds: 1));
      expect(h.api.pullCursors.length, base, reason: 'aún no vence el debounce');
      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(h.api.pullCursors.length, base + 1, reason: 'un solo ciclo para ambas escrituras');
    });
  });

  test('cada 5 minutos sincroniza de nuevo', () {
    fakeAsync((async) {
      final c = container();
      c.listen(syncControllerProvider, (_, _) {});
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 100));
      final base = h.api.pullCursors.length;
      async.elapse(SyncController.periodic);
      async.flushMicrotasks();
      expect(h.api.pullCursors.length, base + 1);
    });
  });

  test('sin red: pasa a offline y reintenta con retroceso exponencial (30 s, 60 s…)', () {
    fakeAsync((async) {
      h.api.pullQueue.clear();
      var calls = 0;
      final failing = _FailingPullApi(() => ++calls);
      final engine = h.engineWith(failing);
      final c = ProviderContainer(overrides: [
        sessionStoreProvider.overrideWithValue(MemorySessionStore(_session)),
        databaseProvider.overrideWithValue(h.db),
        localStoreProvider.overrideWithValue(h.store),
        syncEngineProvider.overrideWithValue(engine),
      ]);
      addTearDown(c.dispose);
      c.listen(syncControllerProvider, (_, _) {});
      async.flushMicrotasks();
      expect(c.read(syncControllerProvider).phase, SyncPhase.offline);
      expect(calls, 1);
      async.elapse(const Duration(seconds: 29));
      expect(calls, 1);
      async.elapse(const Duration(seconds: 2)); // 31 s: primer reintento
      async.flushMicrotasks();
      expect(calls, 2);
      async.elapse(const Duration(seconds: 58)); // t = 89 s: el segundo reintento cae a los 90 s (30 + 60)
      expect(calls, 2);
      async.elapse(const Duration(seconds: 2)); // t = 91 s
      async.flushMicrotasks();
      expect(calls, 3);
      async.elapse(const Duration(seconds: 118)); // t = 209 s: el siguiente espera 120 s (cae a los 210 s)
      expect(calls, 3);
      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(calls, 4);
    });
  });

  test('401: sesión expirada, deja de reintentar y conserva la base y la outbox', () async {
    await h.store.saveCategory(id: 'cat-1', kind: 'expense', name: 'Pendiente');
    h.api.onPush = (_) async => throw apiError('unauthorized', 401);
    final c = container();
    c.listen(syncControllerProvider, (_, _) {});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.read(syncControllerProvider).phase, SyncPhase.sessionExpired);
    expect(await h.outbox(), hasLength(1)); // nada se perdió
    expect(await h.db.select(h.db.categories).get(), hasLength(1));

    // No reintenta por su cuenta ni al programar escrituras.
    final pushes = h.api.pushes.length;
    c.read(syncControllerProvider.notifier).scheduleSoon();
    await c.read(syncControllerProvider.notifier).syncNow();
    expect(h.api.pushes.length, pushes);
  });

  test('tras iniciar sesión de nuevo (token nuevo) reanuda el sync y envía lo pendiente', () async {
    await h.store.saveCategory(id: 'cat-1', kind: 'expense', name: 'Pendiente');
    var expired = true;
    h.api.onPush = (changes) async {
      if (expired) throw apiError('unauthorized', 401);
      return pushResponse([for (final c in changes) result(c, 'applied', record: okRecord(c))]);
    };
    final store = MemorySessionStore(_session);
    final c = container(store: store);
    c.listen(syncControllerProvider, (_, _) {});
    c.listen(authControllerProvider, (_, _) {});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.read(syncControllerProvider).phase, SyncPhase.sessionExpired);

    expired = false;
    await store.write(const Session(token: 't2', userId: 'u1', email: 'a@b.c', name: 'Ana'));
    c.invalidate(authControllerProvider); // el login real hace state = AsyncData(nuevaSesión)
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(c.read(syncControllerProvider).phase, SyncPhase.idle);
    expect(await h.outbox(), isEmpty);
  });

  test('los errores del servidor (5xx) se reintentan y quedan como error', () async {
    h.api.onPush = (_) async => throw apiError('internal', 500);
    await h.store.saveCategory(id: 'cat-1', kind: 'expense', name: 'X');
    final c = container();
    c.listen(syncControllerProvider, (_, _) {});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.read(syncControllerProvider).phase, SyncPhase.error);
  });

  test('una escritura hecha con un ciclo en vuelo provoca otro ciclo al terminar (no espera 5 min)', () async {
    final gate = Completer<void>();
    h.api.pullQueue.clear();
    final api = _GatedPullApi(h.api, gate);
    final engine = h.engineWith(api);
    final c = ProviderContainer(overrides: [
      sessionStoreProvider.overrideWithValue(MemorySessionStore(_session)),
      databaseProvider.overrideWithValue(h.db),
      localStoreProvider.overrideWithValue(h.store),
      syncEngineProvider.overrideWithValue(engine),
    ]);
    addTearDown(c.dispose);
    c.listen(syncControllerProvider, (_, _) {});
    await Future<void>.delayed(const Duration(milliseconds: 30)); // el primer pull queda detenido en la compuerta
    expect(engine.isSyncing, isTrue);

    await h.store.saveCategory(id: 'cat-1', kind: 'expense', name: 'Nueva');
    h.api.onPush = (changes) async => pushResponse([for (final x in changes) result(x, 'applied', record: okRecord(x))]);
    final ctl = c.read(syncControllerProvider.notifier);
    await ctl.syncNow(); // llega con el ciclo en vuelo: debe quedar anotado, no perderse
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(c.read(syncControllerProvider).phase, SyncPhase.idle);
    await Future<void>.delayed(SyncController.debounce + const Duration(milliseconds: 300));
    expect(h.api.pushes, isNotEmpty, reason: 'el cambio se envía sin esperar al ciclo periódico');
    expect(await h.outbox(), isEmpty);
  });

  test('un ciclo del usuario anterior no contamina al controlador del usuario nuevo (401 tardío)', () async {
    final late401 = Completer<void>();
    final slowApi = _LateFailurePullApi(late401);
    final engineA = h.engineWith(slowApi);
    final engineProvider = StateProvider<SyncEngine?>((ref) => engineA);
    final c = ProviderContainer(overrides: [
      sessionStoreProvider.overrideWithValue(MemorySessionStore(_session)),
      databaseProvider.overrideWithValue(h.db),
      localStoreProvider.overrideWithValue(h.store),
      syncEngineProvider.overrideWith((ref) => ref.watch(engineProvider)),
    ]);
    addTearDown(c.dispose);
    c.listen(syncControllerProvider, (_, _) {});
    await Future<void>.delayed(const Duration(milliseconds: 30)); // el ciclo de A queda en vuelo

    c.read(engineProvider.notifier).state = h.engine; // inicia sesión otro usuario: motor nuevo
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(c.read(syncControllerProvider).phase, SyncPhase.idle); // el usuario nuevo sincroniza bien

    late401.complete(); // la respuesta tardía (401) del ciclo de A llega ahora
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(c.read(syncControllerProvider).phase, SyncPhase.idle, reason: 'el 401 de A no debe expirar la sesión de B');
  });
}

/// Detiene el primer pull hasta que se abra la compuerta.
class _GatedPullApi extends FakeSyncApi {
  _GatedPullApi(this._inner, this._gate);
  final FakeSyncApi _inner;
  final Completer<void> _gate;
  var _first = true;

  @override
  Future<Map<String, dynamic>> push(List<Map<String, dynamic>> changes) => _inner.push(changes);

  @override
  Future<Map<String, dynamic>> pull({String? cursor, int limit = 500}) async {
    if (_first) {
      _first = false;
      await _gate.future;
    }
    return pullPage();
  }
}

/// El pull espera y luego falla con 401 (token vencido de otro usuario).
class _LateFailurePullApi extends FakeSyncApi {
  _LateFailurePullApi(this._gate);
  final Completer<void> _gate;

  @override
  Future<Map<String, dynamic>> pull({String? cursor, int limit = 500}) async {
    await _gate.future;
    throw apiError('unauthorized', 401);
  }
}

class _FailingPullApi extends FakeSyncApi {
  _FailingPullApi(this._count);
  final int Function() _count;

  @override
  Future<Map<String, dynamic>> pull({String? cursor, int limit = 500}) async {
    _count();
    throw const ApiException.network();
  }
}