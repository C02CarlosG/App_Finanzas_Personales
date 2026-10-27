import '../../../core/network/api_client.dart';

/// Datos de la cuenta tal como los devuelve el servidor tras un cambio.
class ProfileUpdate {
  const ProfileUpdate({required this.name, required this.email, required this.plan, this.token});

  final String name;
  final String email;
  final String plan;

  /// Solo al cambiar la contraseña: el token anterior queda revocado y este dispositivo recibe uno nuevo.
  final String? token;
}

/// Perfil de usuario (docs/sync.md §8). Todo esto vive en el servidor: necesita conexión.
class ProfileRepository {
  ProfileRepository(this._api);

  final ApiClient _api;

  ProfileUpdate _from(Map<String, dynamic> res) {
    final user = res['user'] as Map<String, dynamic>;
    return ProfileUpdate(
      name: user['name'] as String,
      email: user['email'] as String,
      plan: (user['plan'] as String?) ?? 'free',
      token: res['token'] as String?,
    );
  }

  Future<ProfileUpdate> fetch() async => _from(await _api.get('/auth/me'));

  Future<ProfileUpdate> updateName(String name) async => _from(await _api.patch('/auth/me', body: {'name': name}));

  Future<ProfileUpdate> changeEmail({required String email, required String password}) async =>
      _from(await _api.post('/auth/email', body: {'email': email, 'password': password}));

  Future<ProfileUpdate> changePassword({required String current, required String next}) async =>
      _from(await _api.post('/auth/password', body: {'current_password': current, 'new_password': next}));

  /// Revoca todos los tokens de la cuenta, incluido el de este dispositivo.
  Future<void> logoutEverywhere() async {
    await _api.post('/auth/logout-all');
  }

  Future<void> deleteAccount(String password) async {
    await _api.post('/auth/delete-account', body: {'password': password});
  }
}
