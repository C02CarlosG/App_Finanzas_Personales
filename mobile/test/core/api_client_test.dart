import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
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

  test('el tiempo límite cubre también el cuerpo de la respuesta', () async {
    final stalled = StreamController<List<int>>(); // cuerpo que nunca termina
    addTearDown(stalled.close);
    final api = ApiClient(
      baseUrl: 'http://api.test',
      httpClient: MockClient.streaming((req, body) async => http.StreamedResponse(stalled.stream, 200)),
      timeout: const Duration(milliseconds: 50),
    );
    await expectLater(api.get('/x'), throwsA(isA<ApiException>().having((e) => e.isNetwork, 'isNetwork', true)));
  });

  test('por defecto espera 60 s: tolera una API gratuita que está despertando', () {
    fakeAsync((async) {
      final never = Completer<http.Response>(); // el servidor no responde
      final api = ApiClient(baseUrl: 'http://api.test', httpClient: MockClient((_) => never.future));
      var done = false;
      Object? error;
      api.get('/x').then<void>((_) => done = true, onError: (Object e) {
        error = e;
        done = true;
      });

      async.elapse(const Duration(seconds: 59));
      expect(done, false, reason: 'a los 59 s todavía espera');

      async.elapse(const Duration(seconds: 2));
      expect(done, true, reason: 'pasados los 60 s se rinde');
      expect(error, isA<ApiException>().having((e) => e.isNetwork, 'isNetwork', true));
    });
  });

  test('una respuesta 2xx que no es JSON se reporta como bad_response', () async {
    final api = clientFor(MockClient((_) async => http.Response('<html>login del portal cautivo</html>', 200)));
    await expectLater(api.post('/auth/login', body: {}), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'bad_response')));
  });

  test('un cuerpo vacío 2xx es válido', () async {
    final api = clientFor(MockClient((_) async => http.Response('', 204)));
    expect(await api.get('/x'), isEmpty);
  });

  test('conserva el prefijo de ruta de la URL base', () async {
    late Uri seen;
    final mock = MockClient((req) async {
      seen = req.url;
      return http.Response('{}', 200);
    });
    for (final base in ['https://host.mx/api', 'https://host.mx/api/']) {
      await ApiClient(baseUrl: base, httpClient: mock).get('/sync/pull', query: {'limit': '5'});
      expect(seen.toString(), 'https://host.mx/api/sync/pull?limit=5', reason: base);
    }
    await ApiClient(baseUrl: 'http://10.0.2.2:3000', httpClient: mock).get('/health');
    expect(seen.toString(), 'http://10.0.2.2:3000/health');
  });
}
