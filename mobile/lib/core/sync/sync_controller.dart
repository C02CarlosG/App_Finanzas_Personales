import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/api_exception.dart';
import '../providers.dart';

enum SyncPhase {
  /// Sin motor (modo demo o sin sesión): no se sincroniza.
  disabled,
  idle,
  syncing,

  /// Sin conexión con el servidor; se reintenta con retroceso.
  offline,

  /// El servidor respondió con un error; se reintenta con retroceso.
  error,

  /// El JWT venció (401): no se reintenta hasta iniciar sesión de nuevo. Los datos locales se conservan.
  sessionExpired,
}

class SyncStatus {
  const SyncStatus({this.phase = SyncPhase.idle, this.lastSuccess, this.message});

  final SyncPhase phase;
  final DateTime? lastSuccess;
  final String? message;

  bool get isBusy => phase == SyncPhase.syncing;
}

/// Dispara el sync automáticamente (docs/sync.md §6): al arrancar, tras escribir (con *debounce*),
/// al volver a la app, cada 5 minutos y con reintentos con retroceso si falla. Un solo ciclo a la vez
/// lo garantiza el motor.
class SyncController extends Notifier<SyncStatus> {
  static const debounce = Duration(seconds: 2);
  static const periodic = Duration(minutes: 5);
  static const _retryBase = Duration(seconds: 30);
  static const _retryMax = Duration(minutes: 5);

  Timer? _debounceTimer;
  Timer? _retryTimer;
  Timer? _periodicTimer;
  int _failures = 0;
  bool _disposed = false;

  @override
  SyncStatus build() {
    _disposed = false;
    final engine = ref.watch(syncEngineProvider);

    // Un nuevo token (reingreso tras 401) reanuda el sync sin reiniciar la app.
    ref.listen(authControllerProvider.select((s) => s.value?.token), (prev, next) {
      if (prev != null && next != null && prev != next && state.phase == SyncPhase.sessionExpired) {
        state = SyncStatus(phase: SyncPhase.idle, lastSuccess: state.lastSuccess);
        _failures = 0;
        _startPeriodic();
        unawaited(syncNow());
      }
    });
    ref.onDispose(() {
      _disposed = true;
      _debounceTimer?.cancel();
      _retryTimer?.cancel();
      _periodicTimer?.cancel();
    });

    if (engine == null) return const SyncStatus(phase: SyncPhase.disabled);
    _startPeriodic();
    Future.microtask(syncNow);
    return const SyncStatus();
  }

  void _startPeriodic() {
    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(periodic, (_) => unawaited(syncNow()));
  }

  /// Programa un ciclo en unos segundos (varias escrituras seguidas se agrupan).
  void scheduleSoon() {
    if (_disposed || state.phase == SyncPhase.disabled || state.phase == SyncPhase.sessionExpired) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () => unawaited(syncNow()));
  }

  Future<void> syncNow() async {
    final engine = ref.read(syncEngineProvider);
    if (_disposed || engine == null || state.phase == SyncPhase.sessionExpired) return;
    if (engine.isSyncing) return;
    _debounceTimer?.cancel();
    _retryTimer?.cancel();
    state = SyncStatus(phase: SyncPhase.syncing, lastSuccess: state.lastSuccess);
    try {
      await engine.run();
      if (_disposed) return;
      _failures = 0;
      state = SyncStatus(phase: SyncPhase.idle, lastSuccess: DateTime.now());
    } on ApiException catch (e) {
      if (_disposed) return;
      if (e.isUnauthorized) {
        _periodicTimer?.cancel();
        _retryTimer?.cancel();
        state = SyncStatus(phase: SyncPhase.sessionExpired, lastSuccess: state.lastSuccess, message: e.message);
        return;
      }
      _fail(e.isNetwork ? SyncPhase.offline : SyncPhase.error, e.message);
    } catch (e) {
      if (_disposed) return;
      _fail(SyncPhase.error, '$e');
    }
  }

  void _fail(SyncPhase phase, String message) {
    _failures += 1;
    final seconds = _retryBase.inSeconds * (1 << (_failures - 1).clamp(0, 10));
    final delay = Duration(seconds: seconds > _retryMax.inSeconds ? _retryMax.inSeconds : seconds);
    state = SyncStatus(phase: phase, lastSuccess: state.lastSuccess, message: message);
    _retryTimer = Timer(delay, () => unawaited(syncNow()));
  }
}

final syncControllerProvider = NotifierProvider<SyncController, SyncStatus>(SyncController.new);
