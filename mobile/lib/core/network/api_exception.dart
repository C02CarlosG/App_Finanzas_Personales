/// Error de la API o de la red, con el `code` estable que define el backend
/// (`validation_error`, `unauthorized`, `batch_too_slow`, ...).
class ApiException implements Exception {
  const ApiException({
    required this.code,
    required this.message,
    this.status,
    this.details = const [],
  });

  /// Sin respuesta del servidor (sin conexión, DNS, tiempo de espera).
  const ApiException.network([String message = 'Sin conexión con el servidor'])
      : this(code: 'network', message: message);

  final String code;
  final String message;
  final int? status;
  final List<Map<String, dynamic>> details;

  bool get isNetwork => code == 'network';
  bool get isUnauthorized => status == 401;

  @override
  String toString() => 'ApiException($status, $code): $message';
}
