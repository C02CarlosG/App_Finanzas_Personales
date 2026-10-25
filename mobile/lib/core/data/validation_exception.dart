/// Regla de negocio incumplida; el mensaje está listo para mostrarse al usuario.
class ValidationException implements Exception {
  const ValidationException(this.message);

  final String message;

  @override
  String toString() => message;
}
