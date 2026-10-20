import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

/// Cliente JSON mínimo sobre `package:http`: agrega el JWT, convierte errores
/// de la API y de la red en [ApiException].
class ApiClient {
  ApiClient({
    required this.baseUrl,
    required http.Client httpClient,
    this.tokenProvider,
    this.timeout = const Duration(seconds: 20),
  }) : _http = httpClient;

  final String baseUrl;
  final http.Client _http;
  final Duration timeout;

  /// Se consulta en cada petición (el token puede cambiar con el login/logout).
  final String? Function()? tokenProvider;

  Future<Map<String, dynamic>> get(String path, {Map<String, String>? query}) =>
      _send('GET', path, query: query);

  Future<Map<String, dynamic>> post(String path, {Object? body}) =>
      _send('POST', path, body: body);

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    final uri = Uri.parse(baseUrl).replace(
      path: path,
      queryParameters: (query == null || query.isEmpty) ? null : query,
    );
    final request = http.Request(method, uri)
      ..headers['Accept'] = 'application/json';
    final token = tokenProvider?.call();
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    final http.Response response;
    try {
      response = await http.Response.fromStream(await _http.send(request).timeout(timeout));
    } on TimeoutException {
      throw const ApiException.network('El servidor tardó demasiado en responder');
    } on http.ClientException {
      throw const ApiException.network();
    } on Exception {
      // SocketException y similares (no se importa dart:io para compilar en web).
      throw const ApiException.network();
    }

    final decoded = _decode(response.body);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return decoded ?? <String, dynamic>{};
    }
    throw ApiException(
      status: response.statusCode,
      code: (decoded?['code'] as String?) ?? 'http_${response.statusCode}',
      message: (decoded?['error'] as String?) ?? 'Error ${response.statusCode}',
      details: [
        for (final d in (decoded?['details'] as List?) ?? const [])
          if (d is Map<String, dynamic>) d,
      ],
    );
  }

  Map<String, dynamic>? _decode(String body) {
    if (body.isEmpty) return null;
    try {
      final value = jsonDecode(body);
      return value is Map<String, dynamic> ? value : null;
    } on FormatException {
      return null;
    }
  }

  void close() => _http.close();
}
