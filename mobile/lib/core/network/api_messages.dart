import 'api_exception.dart';

/// Mensaje en español para un error de la API en acciones del perfil (las que exigen conexión).
String profileErrorMessage(ApiException e) {
  if (e.isNetwork) return 'Sin conexión con el servidor. Esta acción necesita internet.';
  if (e.isUnauthorized) return 'Tu sesión expiró. Inicia sesión de nuevo.';
  return switch (e.code) {
    'invalid_password' => 'La contraseña no es correcta',
    'email_taken' => 'Ese correo ya está registrado',
    'same_password' => 'La nueva contraseña debe ser distinta de la actual',
    'validation_error' => 'Revisa los datos: ${e.details.map((d) => d['message']).join(', ')}',
    _ => e.message, // too_many_attempts y demás: el servidor ya responde en español
  };
}
