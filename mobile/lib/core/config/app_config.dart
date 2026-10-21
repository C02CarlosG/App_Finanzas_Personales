/// Configuración en tiempo de compilación (`--dart-define=NOMBRE=valor`).
class AppConfig {
  const AppConfig._();

  /// URL base de la API. En el emulador de Android, `10.0.2.2` es el localhost del equipo.
  static const apiBaseUrl =
      String.fromEnvironment('API_BASE_URL', defaultValue: 'http://10.0.2.2:3000');

  /// Solo desarrollo: salta el login con una sesión ficticia para revisar las pantallas
  /// sin servidor. Nunca debe activarse en una compilación de producción.
  static const demoMode = bool.fromEnvironment('DEMO_MODE');
}
