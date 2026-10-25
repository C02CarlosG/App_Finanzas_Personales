import 'dart:convert';

import 'package:finanzas_personales/app.dart';
import 'package:finanzas_personales/core/providers.dart';
import 'package:finanzas_personales/core/storage/session_store.dart';
import 'package:finanzas_personales/core/sync/sync_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/ui.dart';
import '../sync/support.dart';

const _session = Session(token: 't', userId: 'u1', email: 'ana@example.com', name: 'Ana');

late Harness _h;

http.Response _json(int status, Object body) => http.Response(jsonEncode(body), status);

Future<void> _pump(WidgetTester tester, {Session? stored, MockClient? client}) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final mock = client ??
      MockClient((req) async {
        if (req.url.path == '/auth/login') {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          if (body['password'] != 'password123') {
            return _json(401, {'error': 'Credenciales inválidas', 'code': 'invalid_credentials'});
          }
          return _json(200, {'token': 't', 'user': {'id': 'u1', 'email': body['email'], 'name': 'Ana'}});
        }
        if (req.url.path == '/auth/register') {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          return _json(201, {'token': 't', 'user': {'id': 'u2', 'email': body['email'], 'name': body['name']}});
        }
        return _json(404, {'error': 'no', 'code': 'not_found'});
      });
  await tester.pumpWidget(ProviderScope(
    overrides: [
      sessionStoreProvider.overrideWithValue(MemorySessionStore(stored)),
      httpClientProvider.overrideWithValue(mock),
      databaseProvider.overrideWithValue(_h.db),
      localStoreProvider.overrideWithValue(_h.store),
      syncEngineProvider.overrideWithValue(null),
      syncControllerProvider.overrideWith(() => StubSyncController(const SyncStatus(phase: SyncPhase.disabled))),
    ],
    child: const FinanzasApp(),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => _h = Harness());
  tearDown(() => _h.close());

  testWidgets('sin sesión se muestra el login', (tester) async {
    await _pump(tester);
    expect(find.text('Finanzas Personales'), findsOneWidget);
    expect(find.byKey(const Key('boton-enviar')), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    await finishApp(tester);
  });

  testWidgets('con una sesión guardada entra directo a Inicio (offline-first, sin red)', (tester) async {
    await _pump(tester, stored: _session, client: MockClient((_) async => throw http.ClientException('sin red')));
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byKey(const Key('saldo-total')), findsOneWidget);
    expect(find.text(r'$0.00'), findsOneWidget);
    await finishApp(tester);
  });

  testWidgets('login correcto lleva a Inicio con las 5 secciones', (tester) async {
    await _pump(tester);
    await tester.enterText(find.byKey(const Key('campo-correo')), 'ana@example.com');
    await tester.enterText(find.byKey(const Key('campo-contrasena')), 'password123');
    await tester.tap(find.byKey(const Key('boton-enviar')));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    for (final label in ['Inicio', 'Bancos', 'Categorías', 'Reportes', 'Perfil']) {
      expect(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)), findsOneWidget, reason: label);
    }
    await finishApp(tester);
  });

  testWidgets('credenciales incorrectas muestran el error y siguen en el login', (tester) async {
    await _pump(tester);
    await tester.enterText(find.byKey(const Key('campo-correo')), 'ana@example.com');
    await tester.enterText(find.byKey(const Key('campo-contrasena')), 'incorrecta1');
    await tester.tap(find.byKey(const Key('boton-enviar')));
    await tester.pumpAndSettle();

    expect(find.text('Correo o contraseña incorrectos'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    await finishApp(tester);
  });

  testWidgets('sin conexión el login explica que se necesita internet la primera vez', (tester) async {
    await _pump(tester, client: MockClient((_) async => throw http.ClientException('sin red')));
    await tester.enterText(find.byKey(const Key('campo-correo')), 'ana@example.com');
    await tester.enterText(find.byKey(const Key('campo-contrasena')), 'password123');
    await tester.tap(find.byKey(const Key('boton-enviar')));
    await tester.pumpAndSettle();
    expect(find.textContaining('necesita internet'), findsOneWidget);
    await finishApp(tester);
  });

  testWidgets('el formulario valida correo y contraseña antes de llamar a la API', (tester) async {
    var calls = 0;
    await _pump(tester, client: MockClient((_) async {
      calls++;
      return _json(500, {});
    }));
    await tester.enterText(find.byKey(const Key('campo-correo')), 'no-es-correo');
    await tester.enterText(find.byKey(const Key('campo-contrasena')), 'corta');
    await tester.tap(find.byKey(const Key('boton-enviar')));
    await tester.pumpAndSettle();
    expect(find.text('Correo inválido'), findsOneWidget);
    expect(find.text('Mínimo 8 caracteres'), findsOneWidget);
    expect(calls, 0);
    await finishApp(tester);
  });

  testWidgets('registro: pide nombre y entra a Inicio', (tester) async {
    await _pump(tester);
    await tester.tap(find.text('Crear una cuenta'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('campo-nombre')), 'Beto');
    await tester.enterText(find.byKey(const Key('campo-correo')), 'beto@example.com');
    await tester.enterText(find.byKey(const Key('campo-contrasena')), 'password123');
    await tester.tap(find.byKey(const Key('boton-enviar')));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    await finishApp(tester);
  });

  testWidgets('la barra inferior cambia de sección y conserva el estado de cada una', (tester) async {
    await _pump(tester, stored: _session);
    Future<void> goTo(String label) async {
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));
      await tester.pumpAndSettle();
    }

    await goTo('Bancos');
    expect(find.byKey(const Key('sin-cuentas')), findsOneWidget);
    await goTo('Categorías');
    expect(find.text('Ingresos'), findsWidgets);
    expect(find.text('Gastos'), findsWidgets);
    await goTo('Reportes');
    expect(find.textContaining('Ingresos contra gastos'), findsOneWidget);
    await goTo('Perfil');
    expect(find.text('ana@example.com'), findsOneWidget);
    await goTo('Inicio');
    expect(find.byKey(const Key('saldo-total')), findsOneWidget);
    await finishApp(tester);
  });

  testWidgets('cerrar sesión regresa al login y borra la sesión guardada', (tester) async {
    final store = MemorySessionStore(_session);
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sessionStoreProvider.overrideWithValue(store),
        databaseProvider.overrideWithValue(_h.db),
        localStoreProvider.overrideWithValue(_h.store),
        syncEngineProvider.overrideWithValue(null),
        syncControllerProvider.overrideWith(() => StubSyncController(const SyncStatus(phase: SyncPhase.disabled))),
      ],
      child: const FinanzasApp(),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Perfil')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cerrar-sesion')));
    await tester.pumpAndSettle();
    // Pide confirmación; cancelar no cierra la sesión.
    expect(find.byKey(const Key('dialogo-cerrar-sesion')), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(await store.read(), isNotNull);
    await tester.tap(find.byKey(const Key('cerrar-sesion')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirmar-cerrar-sesion')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('boton-enviar')), findsOneWidget);
    expect(await store.read(), isNull);
    await finishApp(tester);
  });
}
