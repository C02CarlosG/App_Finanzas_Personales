// Perfil contra la API real (se omite sin E2E_API_URL; ver sync_e2e_test.dart para correrla).
import 'dart:io';

import 'package:finanzas_personales/core/network/api_client.dart';
import 'package:finanzas_personales/core/network/api_exception.dart';
import 'package:finanzas_personales/features/auth/data/auth_repository.dart';
import 'package:finanzas_personales/features/profile/data/profile_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  final url = Platform.environment['E2E_API_URL'];
  if (url == null) {
    test('e2e del perfil contra la API real', () {}, skip: 'Defina E2E_API_URL para correrla');
    return;
  }

  ApiClient clientWith(String? Function() token) => ApiClient(baseUrl: url, httpClient: http.Client(), tokenProvider: token);

  late String email;
  late String token;
  late ProfileRepository profile;
  late AuthRepository auth;

  setUp(() async {
    email = 'perfil${DateTime.now().microsecondsSinceEpoch}@example.com';
    auth = AuthRepository(clientWith(() => null));
    token = (await auth.register(name: 'Perfil', email: email, password: 'password123')).token;
    profile = ProfileRepository(clientWith(() => token));
  });

  Future<void> expectApiError(Future<Object?> call, String code, int status) => expectLater(
        call,
        throwsA(isA<ApiException>().having((e) => e.code, 'code', code).having((e) => e.status, 'status', status)),
      );

  test('nombre, correo y plan: la app y el servidor hablan el mismo contrato', () async {
    final me = await profile.fetch();
    expect([me.name, me.email, me.plan], ['Perfil', email, 'free']);
    expect((await profile.updateName('  Perfil Nuevo ')).name, 'Perfil Nuevo');

    await expectApiError(profile.changeEmail(email: 'otro@example.com', password: 'incorrecta1'), 'invalid_password', 403);
    final newEmail = 'nuevo-$email';
    expect((await profile.changeEmail(email: newEmail, password: 'password123')).email, newEmail);
    expect((await auth.login(email: newEmail, password: 'password123')).email, newEmail);
    await expectApiError(auth.login(email: email, password: 'password123'), 'invalid_credentials', 401);
  });

  test('cambiar la contraseña revoca los tokens anteriores y entrega uno nuevo', () async {
    final other = (await auth.login(email: email, password: 'password123')).token; // otro dispositivo
    final update = await profile.changePassword(current: 'password123', next: 'nueva-clave-456');
    expect(update.token, isNotNull);

    await expectApiError(ProfileRepository(clientWith(() => token)).fetch(), 'unauthorized', 401);
    await expectApiError(ProfileRepository(clientWith(() => other)).fetch(), 'unauthorized', 401);
    expect((await ProfileRepository(clientWith(() => update.token)).fetch()).email, email);
    await expectApiError(profile.changePassword(current: 'incorrecta1', next: 'otra-clave-789'), 'unauthorized', 401);
  });

  test('cerrar sesión en todos los dispositivos revoca todos los tokens; un login nuevo funciona', () async {
    await profile.logoutEverywhere();
    await expectApiError(profile.fetch(), 'unauthorized', 401);
    final fresh = (await auth.login(email: email, password: 'password123')).token;
    expect((await ProfileRepository(clientWith(() => fresh)).fetch()).email, email);
  });

  test('borrar la cuenta: contraseña incorrecta no borra; correcta elimina todo y libera el correo', () async {
    await expectApiError(profile.deleteAccount('incorrecta1'), 'invalid_password', 403);
    expect((await profile.fetch()).email, email);

    await profile.deleteAccount('password123'); // 204 sin cuerpo
    await expectApiError(profile.fetch(), 'unauthorized', 401);
    await expectApiError(auth.login(email: email, password: 'password123'), 'invalid_credentials', 401);
    expect((await auth.register(name: 'Otra vez', email: email, password: 'password123')).userId, isNotEmpty);
  });
}
