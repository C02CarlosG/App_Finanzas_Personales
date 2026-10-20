import 'dart:convert';

import 'package:finanzas_personales/core/network/api_client.dart';
import 'package:finanzas_personales/core/network/api_exception.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ApiClient clientFor(MockClient mock, {String? token}) =>
    ApiClient(baseUrl: 'http://api.test', httpClient: mock, tokenProvider: () => token);

void main() {
  test('GET agrega Authorization y parámetros de consulta', () async {
    late http.Request seen;
    final api = clientFor(MockClient((req) async {
      seen = req;
      return http.Response(jsonEncode({'ok': true}), 200);
    }), token: 'abc');
    final res = await api.get('/sync/pull', query: {'cursor': 'x', 'limit': '5'});
    expect(res['ok'], true);
    expect(seen.url.toString(), 'http://api.test/sync/pull?cursor=x&limit=5');
    expect(seen.headers['Authorization'], 'Bearer abc');
  });

  test('POST envía JSON y no manda Authorization sin token', () async {
    late http.Request seen;
    final api = clientFor(MockClient((req) async {
      seen = req;
      return http.Response('{}', 201);
    }));
    await api.post('/auth/login', body: {'email': 'a@b.c'});
    expect(seen.headers['Content-Type'], contains('application/json'));
    expect(jsonDecode(seen.body), {'email': 'a@b.c'});
    expect(seen.headers.containsKey('Authorization'), isFalse);
  });

  test('errores de la API se convierten en ApiException con code, status y detalles', () async {
    final api = clientFor(MockClient((_) async => http.Response(
        jsonEncode({
          'error': 'Datos inválidos',
          'code': 'validation_error',
          'details': [
            {'path': 'password', 'message': 'Mínimo 8 caracteres'}
          ]
        }),
        400)));
    await expectLater(
      api.post('/auth/register', body: {}),
      throwsA(isA<ApiException>()
          .having((e) => e.status, 'status', 400)
          .having((e) => e.code, 'code', 'validation_error')
          .having((e) => e.details.single['path'], 'path', 'password')),
    );
  });

  test('respuesta no JSON usa un código genérico por estado', () async {
    final api = clientFor(MockClient((_) async => http.Response('<html>502</html>', 502)));
    await expectLater(api.get('/x'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'http_502')));
  });

  test('fallos de red se reportan como code network', () async {
    final api = clientFor(MockClient((_) async => throw http.ClientException('sin red')));
    await expectLater(api.get('/x'), throwsA(isA<ApiException>().having((e) => e.isNetwork, 'isNetwork', true)));
  });

  test('401 se marca como no autorizado', () async {
    final api = clientFor(MockClient((_) async => http.Response(jsonEncode({'error': 'x', 'code': 'unauthorized'}), 401)));
    await expectLater(api.get('/x'), throwsA(isA<ApiException>().having((e) => e.isUnauthorized, 'unauthorized', true)));
  });
}
