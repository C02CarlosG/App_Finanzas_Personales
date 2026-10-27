import 'dart:convert';

import 'package:drift/native.dart';
import 'package:finanzas_personales/core/db/app_database.dart';
import 'package:finanzas_personales/core/providers.dart';
import 'package:finanzas_personales/core/storage/session_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('cambiar nombre, correo o token no cierra ni reabre la base local; cerrar sesión sí', () async {
    final store = MemorySessionStore(const Session(token: 'a', userId: 'u1', email: 'a@b.c', name: 'Ana'));
    final opened = <String>[];
    final container = ProviderContainer(overrides: [
      sessionStoreProvider.overrideWithValue(store),
      httpClientProvider.overrideWithValue(MockClient((req) async {
        final user = {'id': 'u1', 'email': 'nuevo@b.c', 'name': 'Ana María', 'plan': 'premium'};
        return http.Response(jsonEncode({'token': 'b', 'user': user}), 200);
      })),
      databaseOpenerProvider.overrideWithValue((userId) {
        opened.add(userId);
        return AppDatabase(NativeDatabase.memory());
      }),
    ]);
    addTearDown(container.dispose);
    await container.read(authControllerProvider.future);

    final first = container.read(databaseProvider);
    expect(first, isNotNull);
    await container.read(authControllerProvider.notifier).updateName('Ana María');
    await container.read(authControllerProvider.notifier).changeEmail(email: 'nuevo@b.c', password: 'x');
    await container.read(authControllerProvider.notifier).changePassword(current: 'x', next: 'y' * 8); // token nuevo
    expect(container.read(authControllerProvider).value!.token, 'b');
    expect(identical(container.read(databaseProvider), first), isTrue);
    expect(opened, ['u1'], reason: 'se abrió una sola vez');

    await container.read(authControllerProvider.notifier).logout();
    expect(container.read(databaseProvider), isNull);
  });

  test('si no se puede vaciar la base local, la cuenta ya borrada en el servidor igual cierra la sesión', () async {
    final store = MemorySessionStore(const Session(token: 'a', userId: 'u1', email: 'a@b.c', name: 'Ana'));
    final container = ProviderContainer(overrides: [
      sessionStoreProvider.overrideWithValue(store),
      httpClientProvider.overrideWithValue(MockClient((_) async => http.Response('', 204))),
      databaseProvider.overrideWithValue(_BrokenDb()),
    ]);
    addTearDown(container.dispose);
    await container.read(authControllerProvider.future);

    await container.read(authControllerProvider.notifier).deleteAccount('password123');
    expect(container.read(authControllerProvider).value, isNull);
    expect(await store.read(), isNull);
  });
}

/// Una base cuyo vaciado falla (disco lleno, archivo bloqueado…).
class _BrokenDb extends AppDatabase {
  _BrokenDb() : super(NativeDatabase.memory());

  @override
  Future<void> wipe() => Future.error(StateError('disco lleno'));
}
