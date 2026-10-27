import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'config/app_config.dart';
import 'db/app_database.dart';
import 'db/local_store.dart';
import 'network/api_client.dart';
import 'network/api_exception.dart';
import 'storage/session_store.dart';
import 'sync/stamp.dart';
import 'sync/sync_api.dart';
import 'sync/sync_signal.dart';
import 'sync/sync_engine.dart';
import '../features/auth/data/auth_repository.dart';
import '../features/profile/data/profile_repository.dart';

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

final profileRepositoryProvider = Provider<ProfileRepository>((ref) => ProfileRepository(ref.watch(apiClientProvider)));

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

  // ---- Perfil: las acciones que cambian la cuenta en el servidor propagan el error a la pantalla.

  Future<void> updateName(String name) async => _applyProfile(await ref.read(profileRepositoryProvider).updateName(name));

  Future<void> changeEmail({required String email, required String password}) async =>
      _applyProfile(await ref.read(profileRepositoryProvider).changeEmail(email: email, password: password));

  /// Revoca los demás dispositivos y deja en este el token nuevo (el sync continúa sin volver a iniciar sesión).
  Future<void> changePassword({required String current, required String next}) async =>
      _applyProfile(await ref.read(profileRepositoryProvider).changePassword(current: current, next: next));

  /// Pone al día nombre, correo y plan con lo que diga el servidor (p. ej. editados desde otro dispositivo).
  /// Es un ajuste de cortesía: sin conexión o con sesión vencida se queda lo guardado.
  Future<void> refreshProfile() async {
    try {
      await _applyProfile(await ref.read(profileRepositoryProvider).fetch());
    } on ApiException {
      // offline-first: se confía en la sesión guardada
    }
  }

  /// El servidor revoca todos los tokens; solo si responde se cierra la sesión local.
  Future<void> logoutEverywhere() async {
    await ref.read(profileRepositoryProvider).logoutEverywhere();
    await logout();
  }

  /// Borra la cuenta en el servidor y, solo si lo logró, vacía la base local de este dispositivo.
  Future<void> deleteAccount(String password) async {
    await ref.read(profileRepositoryProvider).deleteAccount(password);
    try {
      await ref.read(databaseProvider)?.wipe();
    } catch (_) {
      // La cuenta ya no existe en el servidor: aunque la base local no se pueda vaciar (disco lleno, archivo
      // bloqueado) hay que salir; ese archivo queda huérfano y nadie lo vuelve a abrir (el id de usuario no se reutiliza).
    }
    await logout();
  }

  Future<void> _applyProfile(ProfileUpdate update) async {
    final current = state.value;
    if (current == null) return;
    final next = current.copyWith(token: update.token, email: update.email, name: update.name, plan: update.plan);
    await ref.read(sessionStoreProvider).write(next);
    state = AsyncData(next);
  }
}

/// Cómo se abre la base de un usuario (las pruebas la sustituyen por una en memoria).
final databaseOpenerProvider = Provider<AppDatabase Function(String userId)>((ref) => AppDatabase.forUser);

/// Base local del usuario con sesión; se cierra al cambiar de usuario o cerrar sesión.
/// `null` sin sesión. En modo demo `main()` la reemplaza por una base de ejemplo ya sembrada.
final databaseProvider = Provider<AppDatabase?>((ref) {
  // Solo el id: cambiar nombre, correo o token no debe cerrar y reabrir la base.
  final userId = ref.watch(authControllerProvider.select((s) => s.value?.userId));
  if (userId == null || AppConfig.demoMode) return null;
  final db = ref.watch(databaseOpenerProvider)(userId);
  ref.onDispose(db.close);
  return db;
});

final stampClockProvider = Provider<StampClock>((ref) => StampClock());

/// Señal compartida entre el store, el motor y el controlador de sync (ver `SyncSignal`).
final syncSignalProvider = Provider<SyncSignal>((ref) => SyncSignal());

/// Punto único de escritura local (pantallas → repositorios → aquí, nunca directo a las tablas).
/// Tras cada escritura avisa al controlador de sync por la señal; no depende de él.
final localStoreProvider = Provider<LocalStore?>((ref) {
  final db = ref.watch(databaseProvider);
  if (db == null) return null;
  final signal = ref.watch(syncSignalProvider);
  return LocalStore(
    db,
    ref.watch(stampClockProvider),
    isSyncing: () => signal.isSyncing(),
    onChanged: () => signal.onLocalChange(),
  );
});

/// Sin motor (`null`) no se sincroniza: sin sesión o en modo demo (no hay servidor).
final syncEngineProvider = Provider<SyncEngine?>((ref) {
  final db = ref.watch(databaseProvider);
  final store = ref.watch(localStoreProvider);
  if (db == null || store == null || AppConfig.demoMode) return null;
  final engine = SyncEngine(
    db: db,
    api: HttpSyncApi(ref.watch(apiClientProvider)),
    store: store,
    clock: ref.watch(stampClockProvider),
  );
  final signal = ref.watch(syncSignalProvider);
  signal.isSyncing = () => engine.isSyncing;
  ref.onDispose(() => signal.isSyncing = () => false);
  return engine;
});
