import 'package:flutter/foundation.dart' show kReleaseMode;

/// Configuración en tiempo de compilación (`--dart-define=NOMBRE=valor`).
class AppConfig {
  const AppConfig._();

  /// URL base de la API. En el emulador de Android, `10.0.2.2` es el localhost del equipo.
  static const apiBaseUrl =
      String.fromEnvironment('API_BASE_URL', defaultValue: 'http://10.0.2.2:3000');

  /// Solo desarrollo: salta el login con una sesión ficticia para revisar las pantallas
  /// sin servidor. Nunca debe activarse en una compilación de producción.
  static const demoMode = bool.fromEnvironment('DEMO_MODE');

  /// Por qué esta compilación no puede arrancar (o `null` si está bien configurada).
  static String? get problem => releaseConfigProblem(release: kReleaseMode, demo: demoMode, apiBaseUrl: apiBaseUrl);
}

/// Una compilación release (no demo) debe hablar con la API por HTTPS: Android bloquea el tráfico en claro y la
/// dirección por defecto (`10.0.2.2`) solo existe en el emulador. Se avisa en pantalla en vez de fallar en silencio.
String? releaseConfigProblem({required bool release, required bool demo, required String apiBaseUrl}) {
  if (!release || demo) return null;
  final uri = Uri.tryParse(apiBaseUrl);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
    return 'Esta compilación no tiene una dirección de servidor válida. '
        'Compílala con --dart-define=API_BASE_URL=https://tu-servidor (debe empezar con https://).';
  }
  return null;
}
