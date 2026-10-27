import 'dart:convert';

import 'package:finanzas_personales/core/providers.dart';
import 'package:finanzas_personales/core/storage/session_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('cambiar nombre, correo o token no cierra ni reabre la base local; cambiar de usuario sí', () async {
    final store = MemorySessionStore(const Session(token: 'a', userId: 'u1', email: 'a@b.c', name: 'Ana'));
    final container = ProviderContainer(overrides: [
      sessionStoreProvider.overrideWithValue(store),
      httpClientProvider.overrideWithValue(MockClient((req) async {
        final user = {'id': 'u1', 'email': 'nuevo@b.c', 'name': 'Ana María', 'plan': 'premium'};
        return http.Response(jsonEncode({'token': 'b', 'user': user}), 200);
      })),
    ]);
    addTearDown(container.dispose);
    await container.read(authControllerProvider.future);

    final first = container.read(databaseProvider);
    expect(first, isNotNull);
    await container.read(authControllerProvider.notifier).updateName('Ana María');
    await container.read(authControllerProvider.notifier).changePassword(current: 'x', next: 'y' * 8); // token nuevo
    expect(container.read(authControllerProvider).value!.token, 'b');
    expect(identical(container.read(databaseProvider), first), isTrue);

    await container.read(authControllerProvider.notifier).logout();
    expect(container.read(databaseProvider), isNull);
  });
}
