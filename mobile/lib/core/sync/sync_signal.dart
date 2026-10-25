/// Puente sin dependencias entre la escritura local y el sync.
///
/// `LocalStore` necesita saber si hay un ciclo en curso y avisar de cada escritura, pero el motor y el
/// controlador de sync dependen del store: si el store los leyera con `ref.read` formaría un ciclo de
/// providers (Riverpod lo detecta en depuración y rompe cada guardado). Con este objeto el store solo
/// depende de la señal, y el motor y el controlador la **rellenan** al construirse.
class SyncSignal {
  /// ¿Hay un ciclo de sync en curso? (lo registra el motor)
  bool Function() isSyncing = () => false;

  /// Se llama tras confirmar cada escritura local (lo registra el controlador de sync).
  void Function() onLocalChange = () {};
}
