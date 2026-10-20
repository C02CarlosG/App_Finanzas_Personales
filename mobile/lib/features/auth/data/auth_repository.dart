import '../../../core/network/api_client.dart';
import '../../../core/storage/session_store.dart';

class AuthRepository {
  AuthRepository(this._api);

  final ApiClient _api;

  Future<Session> login({required String email, required String password}) async {
    final res = await _api.post('/auth/login', body: {'email': email, 'password': password});
    return _toSession(res);
  }

  Future<Session> register({
    required String name,
    required String email,
    required String password,
  }) async {
    final res = await _api.post('/auth/register', body: {'name': name, 'email': email, 'password': password});
    return _toSession(res);
  }

  Session _toSession(Map<String, dynamic> res) {
    final user = res['user'] as Map<String, dynamic>;
    return Session(
      token: res['token'] as String,
      userId: user['id'] as String,
      email: user['email'] as String,
      name: user['name'] as String,
    );
  }
}
