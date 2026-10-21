import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'config/app_config.dart';
import 'db/app_database.dart';
import 'db/local_store.dart';
import 'network/api_client.dart';
import 'storage/session_store.dart';
import 'sync/stamp.dart';
import 'sync/sync_api.dart';
import 'sync/sync_controller.dart';
import 'sync/sync_engine.dart';
import '../features/auth/data/auth_repository.dart';

final sessionStoreProvider = Provider<SessionStore>((ref) => SecureSessionStore());

final httpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

/// Cliente de la API; toma el token de la sesión vigente en cada petición.
final apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient(
    baseUrl: AppConfig.apiBaseUrl,
    httpClient: ref.watch(httpClientProvider),
    tokenProvider: () => ref.read(authControllerProvider).value?.token,
  );
});

final authRepositoryProvider = Provider<AuthRepository>((ref) => AuthRepository(ref.watch(apiClientProvider)));

/// Sesión actual: `null` = sin iniciar sesión.
final authControllerProvider = AsyncNotifierProvider<AuthController, Session?>(AuthController.new);

class AuthController extends AsyncNotifier<Session?> {
  @override
  Future<Session?> build() async {
    if (AppConfig.demoMode) {
      return const Session(token: 'demo', userId: 'demo-user', email: 'demo@example.com', name: 'Modo demo');
    }
    // Offline-first: la sesión guardada se confía sin consultar la red.
    return ref.read(sessionStoreProvider).read();
  }

  Future<void> login({required String email, required String password}) =>
      _authenticate(() => ref.read(authRepositoryProvider).login(email: email, password: password));

  Future<void> register({required String name, required String email, required String password}) =>
      _authenticate(() => ref.read(authRepositoryProvider).register(name: name, email: email, password: password));

  /// Los errores (credenciales, red) se propagan a la pantalla; el estado conserva la sesión previa.
  Future<void> _authenticate(Future<Session> Function() action) async {
    final session = await action();
    await ref.read(sessionStoreProvider).write(session);
    state = AsyncData(session);
  }

  Future<void> logout() async {
    await ref.read(sessionStoreProvider).clear();
    state = const AsyncData(null);
  }
}

/// Base local del usuario con sesión; se cierra al cambiar de usuario o cerrar sesión.
/// `null` sin sesión. En modo demo `main()` la reemplaza por una base de ejemplo ya sembrada.
final databaseProvider = Provider<AppDatabase?>((ref) {
  final session = ref.watch(authControllerProvider.select((s) => s.value));
  if (session == null || AppConfig.demoMode) return null;
  final db = AppDatabase.forUser(session.userId);
  ref.onDispose(db.close);
  return db;
});

final stampClockProvider = Provider<StampClock>((ref) => StampClock());

/// Punto único de escritura local (pantallas → repositorios → aquí, nunca directo a las tablas).
/// Tras cada escritura programa el sync automático.
final Provider<LocalStore?> localStoreProvider = Provider<LocalStore?>((ref) {
  final db = ref.watch(databaseProvider);
  if (db == null) return null;
  return LocalStore(
    db,
    ref.watch(stampClockProvider),
    // Lecturas perezosas: el motor depende de este store y este store del motor.
    isSyncing: () => ref.read(syncEngineProvider)?.isSyncing ?? false,
    onChanged: () => ref.read(syncControllerProvider.notifier).scheduleSoon(),
  );
});

/// Sin motor (`null`) no se sincroniza: sin sesión o en modo demo (no hay servidor).
final Provider<SyncEngine?> syncEngineProvider = Provider<SyncEngine?>((ref) {
  final db = ref.watch(databaseProvider);
  final store = ref.watch(localStoreProvider);
  if (db == null || store == null || AppConfig.demoMode) return null;
  return SyncEngine(
    db: db,
    api: HttpSyncApi(ref.watch(apiClientProvider)),
    store: store,
    clock: ref.watch(stampClockProvider),
  );
});
