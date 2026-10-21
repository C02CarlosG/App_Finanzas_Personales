import '../network/api_client.dart';

/// Frontera de red del motor de sync (se reemplaza en pruebas).
abstract class SyncApi {
  Future<Map<String, dynamic>> push(List<Map<String, dynamic>> changes);
  Future<Map<String, dynamic>> pull({String? cursor, int limit});
}

class HttpSyncApi implements SyncApi {
  HttpSyncApi(this._client);

  final ApiClient _client;

  @override
  Future<Map<String, dynamic>> push(List<Map<String, dynamic>> changes) =>
      _client.post('/sync/push', body: {'changes': changes});

  @override
  Future<Map<String, dynamic>> pull({String? cursor, int limit = 500}) =>
      _client.get('/sync/pull', query: {'cursor': ?cursor, 'limit': '$limit'});
}
