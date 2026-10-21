import 'package:finanzas_personales/core/db/app_database.dart';
import 'package:finanzas_personales/core/money/money.dart';
import 'package:finanzas_personales/core/sync/sync_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:drift/drift.dart' show Value;

import '../support/catalog.dart';
import '../support/ui.dart';
import '../sync/support.dart';

void main() {
  late Harness h;
  setUp(() async {
    h = Harness();
    await seedCatalog(h.db);
  });
  tearDown(() async {
    await h.close();
  });

  Future<void> addProblem(WidgetTester tester) => seedDb(tester, () async {
        await h.store.saveAccount(id: 'acc-1', type: 'efectivo', name: 'Cartera');
        await h.store.saveTransaction(
            id: 'tx-1', type: 'expense', amount: Money.parse('250'), accountId: 'acc-1', categoryId: Catalog.comida, occurredOn: '2026-10-19', description: 'Súper');
        await (h.db.update(h.db.syncOutbox)..where((o) => o.recordId.equals('tx-1')))
            .write(const SyncOutboxCompanion(lastError: Value('invalid_reference'), attempts: Value(2)));
      });

  testWidgets('sin problemas ni pendientes no se muestra ningún banner', (tester) async {
    await pumpApp(tester, h);
    expect(find.byKey(const Key('banner-problemas')), findsNothing);
    expect(find.byKey(const Key('banner-offline')), findsNothing);
    expect(find.byKey(const Key('banner-sesion-expirada')), findsNothing);
    await finishApp(tester);
  });

  testWidgets('sin conexión con cambios pendientes: avisa cuántos hay por enviar', (tester) async {
    await tester.runAsync(() async {
      await h.store.saveAccount(id: 'acc-1', type: 'efectivo', name: 'Cartera');
      await h.store.saveCategory(id: 'cat-x', kind: 'expense', name: 'X');
    });
    await pumpApp(tester, h, sync: const SyncStatus(phase: SyncPhase.offline));
    expect(find.byKey(const Key('banner-offline')), findsOneWidget);
    expect(find.text('Sin conexión · 2 cambios por enviar'), findsOneWidget);
    await finishApp(tester);
  });

  testWidgets('cambios con problemas: banner → pantalla de problemas con explicación', (tester) async {
    await addProblem(tester);
    await pumpApp(tester, h);
    expect(find.text('1 cambio con problemas'), findsOneWidget);

    await tester.tap(find.text('Revisar'));
    await tester.pumpAndSettle();
    expect(find.text('Problemas de sincronización'), findsOneWidget);
    expect(find.textContaining('Gasto de \$250.00 · Súper'), findsOneWidget);
    expect(find.textContaining('Falta la cuenta o la categoría'), findsOneWidget);
    await finishApp(tester);
  });

  testWidgets('eliminar un cambio con problemas lo descarta y vacía la pantalla', (tester) async {
    await addProblem(tester);
    await pumpApp(tester, h);
    await tester.tap(find.text('Revisar'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('eliminar-tx-1')));
    await tester.pumpAndSettle();
    expect(find.text('¿Eliminar este cambio?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Eliminar'));
    await settleDb(tester);

    expect(find.byKey(const Key('sin-problemas')), findsOneWidget);
    final row = await tester.runAsync(() => (h.db.select(h.db.transactions)..where((t) => t.id.equals('tx-1'))).getSingleOrNull());
    expect(row == null || row.deletedAt != null, isTrue);
    await finishApp(tester);
  });

  testWidgets('sesión expirada: banner, reingreso con el mismo correo y vuelta a Inicio', (tester) async {
    final client = MockClient((req) async {
      if (req.url.path == '/auth/login') {
        return jsonResponse(200, {'token': 't2', 'user': {'id': 'u1', 'email': 'ana@example.com', 'name': 'Ana'}});
      }
      return http.Response('{}', 404);
    });
    await pumpApp(tester, h, sync: const SyncStatus(phase: SyncPhase.sessionExpired), client: client);
    expect(find.byKey(const Key('banner-sesion-expirada')), findsOneWidget);
    expect(find.textContaining('Tus datos siguen guardados'), findsOneWidget);

    await tester.tap(find.text('Iniciar sesión'));
    await tester.pumpAndSettle();
    expect(find.text('Sesión expirada'), findsOneWidget);
    final email = tester.widget<TextFormField>(find.byKey(const Key('campo-correo')));
    expect(email.controller!.text, 'ana@example.com');
    expect(find.text('Crear una cuenta'), findsNothing); // en reingreso no hay registro

    await tester.enterText(find.byKey(const Key('campo-contrasena')), 'password123');
    await tester.tap(find.byKey(const Key('boton-enviar')));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget); // de vuelta en la app
    await finishApp(tester);
  });

  testWidgets('reingreso con contraseña incorrecta muestra el error y no sale de la pantalla', (tester) async {
    final client = MockClient((req) async => jsonResponse(401, {'error': 'x', 'code': 'invalid_credentials'}));
    await pumpApp(tester, h, sync: const SyncStatus(phase: SyncPhase.sessionExpired), client: client);
    await tester.tap(find.text('Iniciar sesión'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('campo-contrasena')), 'incorrecta1');
    await tester.tap(find.byKey(const Key('boton-enviar')));
    await tester.pumpAndSettle();
    expect(find.text('Correo o contraseña incorrectos'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    await finishApp(tester);
  });
}
