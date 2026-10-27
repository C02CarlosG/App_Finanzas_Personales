import 'dart:convert';

import 'package:finanzas_personales/app.dart';
import 'package:finanzas_personales/core/money/money.dart';
import 'package:finanzas_personales/core/providers.dart';
import 'package:finanzas_personales/core/storage/session_store.dart';
import 'package:finanzas_personales/core/sync/sync_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/catalog.dart';
import '../support/ui.dart';
import '../sync/support.dart';

const _stored = Session(token: 'viejo', userId: 'u1', email: 'ana@example.com', name: 'Ana');

http.Response _json(int status, Object body) => http.Response(jsonEncode(body), status);

Map<String, Object> _user({String name = 'Ana', String email = 'ana@example.com', String plan = 'free'}) =>
    {'id': 'u1', 'email': email, 'name': name, 'currency': 'MXN', 'plan': plan};

/// Servidor simulado: respuestas por «MÉTODO /ruta» y registro de cada petición recibida.
class FakeServer {
  final handlers = <String, http.Response Function(Map<String, dynamic> body)>{};
  final calls = <({String method, String path, Map<String, dynamic> body, String? auth})>[];

  MockClient get client => MockClient((req) async {
        final body = req.body.isEmpty ? <String, dynamic>{} : jsonDecode(req.body) as Map<String, dynamic>;
        calls.add((method: req.method, path: req.url.path, body: body, auth: req.headers['Authorization']));
        final handler = handlers['${req.method} ${req.url.path}'];
        if (handler == null) return _json(404, {'error': 'no', 'code': 'not_found'});
        return handler(body);
      });

  List<({String method, String path, Map<String, dynamic> body, String? auth})> to(String method, String path) =>
      calls.where((c) => c.method == method && c.path == path).toList();
}

late Harness _h;
late FakeServer _server;
late MemorySessionStore _store;

Future<void> _pump(WidgetTester tester, {Size size = const Size(800, 1600), double textScale = 1}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 2;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearAllTestValues);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      sessionStoreProvider.overrideWithValue(_store),
      httpClientProvider.overrideWithValue(_server.client),
      databaseProvider.overrideWithValue(_h.db),
      localStoreProvider.overrideWithValue(_h.store),
      syncEngineProvider.overrideWithValue(null),
      syncControllerProvider.overrideWith(() => StubSyncController(const SyncStatus(phase: SyncPhase.disabled))),
    ],
    child: const FinanzasApp(),
  ));
  await tester.pumpAndSettle();
  await goToTab(tester, 'Perfil');
}

/// Abre la fila de Perfil [key], desplazando la lista si queda fuera de pantalla (las filas se construyen al vuelo).
Future<void> _open(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
  }
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    _h = Harness();
    _server = FakeServer();
    _store = MemorySessionStore(_stored);
  });
  tearDown(() => _h.close());

  testWidgets('muestra nombre, correo, moneda fija en MXN y el plan gratuito', (tester) async {
    await _pump(tester);
    expect(find.byKey(const Key('perfil-nombre-actual')), findsOneWidget);
    expect(find.text('Ana'), findsWidgets);
    expect(find.text('ana@example.com'), findsWidgets);
    expect(find.descendant(of: find.byKey(const Key('perfil-moneda')), matching: find.text('Peso mexicano (MXN)')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('perfil-plan')), matching: find.textContaining('Gratuito')), findsOneWidget);
    await finishApp(tester);
  });

  testWidgets('al abrir Perfil se pone al día con el servidor (plan, nombre y correo cambiados desde otro lugar)', (tester) async {
    _server.handlers['GET /auth/me'] = (_) => _json(200, {'user': _user(name: 'Ana María', email: 'nueva@example.com', plan: 'premium')});
    await _pump(tester);
    expect(find.text('Ana María'), findsWidgets);
    expect(find.text('nueva@example.com'), findsWidgets);
    expect(find.descendant(of: find.byKey(const Key('perfil-plan')), matching: find.text('Premium')), findsOneWidget);
    final saved = (await _store.read())!;
    expect([saved.name, saved.email, saved.plan, saved.token], ['Ana María', 'nueva@example.com', 'premium', 'viejo']);
    await finishApp(tester);
  });

  testWidgets('sin conexión o con el servidor caído el perfil se queda con lo guardado', (tester) async {
    _server.handlers['GET /auth/me'] = (_) => throw http.ClientException('sin red');
    await _pump(tester);
    expect(find.text('Ana'), findsWidgets);
    expect(tester.takeException(), isNull);
    await finishApp(tester);
  });

  group('nombre', () {
    testWidgets('se valida, se envía recortado y se actualiza la pantalla y la sesión guardada', (tester) async {
      _server.handlers['PATCH /auth/me'] = (b) => _json(200, {'user': _user(name: b['name'] as String)});
      await _pump(tester);
      await _open(tester, 'perfil-nombre');
      expect(find.byKey(const Key('campo-nombre-perfil')), findsOneWidget);

      await enter(tester, const Key('campo-nombre-perfil'), '   ');
      await tapKey(tester, const Key('guardar-nombre'));
      expect(find.text('Escribe tu nombre'), findsOneWidget);
      expect(_server.to('PATCH', '/auth/me'), isEmpty, reason: 'no se envía un nombre inválido');

      await enter(tester, const Key('campo-nombre-perfil'), '  María López  ');
      await tapKey(tester, const Key('guardar-nombre'));
      expect(_server.to('PATCH', '/auth/me').single.body, {'name': 'María López'});
      expect(find.byKey(const Key('campo-nombre-perfil')), findsNothing, reason: 'el diálogo se cierra');
      expect(find.text('Nombre actualizado'), findsOneWidget);
      // La lista es perezosa y al abrir la fila el encabezado quedó fuera de la ventana: se vuelve al inicio.
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 600));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.byKey(const Key('perfil-nombre-actual'))).data, 'María López');
      expect((await _store.read())!.name, 'María López');
      await finishApp(tester);
    });

    testWidgets('sin conexión el diálogo sigue abierto con el aviso y no cambia nada', (tester) async {
      _server.handlers['PATCH /auth/me'] = (_) => throw http.ClientException('sin red');
      await _pump(tester);
      await _open(tester, 'perfil-nombre');
      await enter(tester, const Key('campo-nombre-perfil'), 'Otra');
      await tapKey(tester, const Key('guardar-nombre'));
      expect(find.byKey(const Key('error-dialogo')), findsOneWidget);
      expect(find.textContaining('necesita internet'), findsOneWidget);
      expect(find.byKey(const Key('campo-nombre-perfil')), findsOneWidget);
      expect((await _store.read())!.name, 'Ana');
      await tester.tap(find.byKey(const Key('cancelar-dialogo')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('campo-nombre-perfil')), findsNothing);
      await finishApp(tester);
    });
  });

  group('correo', () {
    testWidgets('pide la contraseña; una incorrecta se avisa sin cerrar el diálogo ni la sesión', (tester) async {
      _server.handlers['POST /auth/email'] = (b) => b['password'] == 'password123'
          ? _json(200, {'user': _user(email: b['email'] as String)})
          : _json(403, {'error': 'La contraseña no es correcta', 'code': 'invalid_password'});
      await _pump(tester);
      await _open(tester, 'perfil-correo');

      await enter(tester, const Key('campo-correo-nuevo'), 'no-es-correo');
      await enter(tester, const Key('campo-contrasena-actual'), '');
      await tapKey(tester, const Key('guardar-correo'));
      expect(find.text('Correo inválido'), findsOneWidget);
      expect(find.text('Escribe tu contraseña'), findsOneWidget);
      expect(_server.to('POST', '/auth/email'), isEmpty);

      await enter(tester, const Key('campo-correo-nuevo'), '  nuevo@example.com ');
      await enter(tester, const Key('campo-contrasena-actual'), 'equivocada1');
      await tapKey(tester, const Key('guardar-correo'));
      expect(find.text('La contraseña no es correcta'), findsOneWidget);
      expect(find.byKey(const Key('boton-enviar')), findsNothing, reason: 'un 403 no cierra la sesión');
      expect((await _store.read())!.email, 'ana@example.com');

      await enter(tester, const Key('campo-contrasena-actual'), 'password123');
      await tapKey(tester, const Key('guardar-correo'));
      expect(_server.to('POST', '/auth/email').last.body, {'email': 'nuevo@example.com', 'password': 'password123'});
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 600)); // de vuelta al encabezado
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.byKey(const Key('perfil-correo-actual'))).data, 'nuevo@example.com');
      expect((await _store.read())!.email, 'nuevo@example.com');
      await finishApp(tester);
    });

    testWidgets('correo ya registrado y demasiados intentos muestran el mensaje del servidor', (tester) async {
      var n = 0;
      _server.handlers['POST /auth/email'] = (_) => ++n == 1
          ? _json(409, {'error': 'El correo ya está registrado', 'code': 'email_taken'})
          : _json(429, {'error': 'Demasiados intentos. Vuelve a intentar en 15 min', 'code': 'too_many_attempts'});
      await _pump(tester);
      await _open(tester, 'perfil-correo');
      await enter(tester, const Key('campo-correo-nuevo'), 'otro@example.com');
      await enter(tester, const Key('campo-contrasena-actual'), 'password123');
      await tapKey(tester, const Key('guardar-correo'));
      expect(find.text('Ese correo ya está registrado'), findsOneWidget);
      await tapKey(tester, const Key('guardar-correo'));
      expect(find.text('Demasiados intentos. Vuelve a intentar en 15 min'), findsOneWidget);
      await finishApp(tester);
    });
  });

  group('contraseña', () {
    testWidgets('valida mínimo, distinta de la actual y confirmación; luego guarda el token nuevo', (tester) async {
      _server.handlers['POST /auth/password'] = (_) => _json(200, {'token': 'nuevo', 'user': _user()});
      _server.handlers['GET /auth/me'] = (_) => _json(200, {'user': _user()});
      await _pump(tester);
      await _open(tester, 'perfil-contrasena');

      await enter(tester, const Key('campo-contrasena-actual'), 'password123');
      await enter(tester, const Key('campo-contrasena-nueva'), 'corta');
      await enter(tester, const Key('campo-contrasena-confirmar'), 'otra');
      await tapKey(tester, const Key('guardar-contrasena'));
      expect(find.text('Mínimo 8 caracteres'), findsOneWidget);
      expect(find.text('No coincide'), findsOneWidget);

      await enter(tester, const Key('campo-contrasena-nueva'), 'password123');
      await enter(tester, const Key('campo-contrasena-confirmar'), 'password123');
      await tapKey(tester, const Key('guardar-contrasena'));
      expect(find.text('Debe ser distinta de la actual'), findsOneWidget);
      expect(_server.to('POST', '/auth/password'), isEmpty);

      await enter(tester, const Key('campo-contrasena-nueva'), 'nueva-clave-456');
      await enter(tester, const Key('campo-contrasena-confirmar'), 'nueva-clave-456');
      await tapKey(tester, const Key('guardar-contrasena'));
      expect(_server.to('POST', '/auth/password').single.body, {'current_password': 'password123', 'new_password': 'nueva-clave-456'});
      expect((await _store.read())!.token, 'nuevo');
      expect(find.text('Contraseña actualizada'), findsOneWidget);

      // Las peticiones siguientes ya usan el token nuevo y el usuario sigue dentro.
      expect(find.byKey(const Key('boton-enviar')), findsNothing);
      await tester.runAsync(() async {
        final container = ProviderScope.containerOf(tester.element(find.byType(FinanzasApp)));
        await container.read(authControllerProvider.notifier).refreshProfile();
      });
      expect(_server.to('GET', '/auth/me').last.auth, 'Bearer nuevo');
      await finishApp(tester);
    });

    testWidgets('contraseña actual incorrecta: aviso en el diálogo y la sesión sigue abierta', (tester) async {
      _server.handlers['POST /auth/password'] = (_) => _json(403, {'error': 'La contraseña no es correcta', 'code': 'invalid_password'});
      await _pump(tester);
      await _open(tester, 'perfil-contrasena');
      await enter(tester, const Key('campo-contrasena-actual'), 'equivocada1');
      await enter(tester, const Key('campo-contrasena-nueva'), 'nueva-clave-456');
      await enter(tester, const Key('campo-contrasena-confirmar'), 'nueva-clave-456');
      await tapKey(tester, const Key('guardar-contrasena'));
      expect(find.text('La contraseña no es correcta'), findsOneWidget);
      expect((await _store.read())!.token, 'viejo');
      await finishApp(tester);
    });
  });

  group('cerrar sesión en todos los dispositivos', () {
    testWidgets('avisa al servidor y cierra la sesión local; los datos locales se conservan', (tester) async {
      _server.handlers['POST /auth/logout-all'] = (_) => http.Response('', 204);
      await _pump(tester);
      await tester.runAsync(() => seedCatalog(_h.db));
      await _open(tester, 'cerrar-sesion-todos');
      expect(find.byKey(const Key('dialogo-cerrar-todos')), findsOneWidget);
      await tapKey(tester, const Key('confirmar-cerrar-todos'));
      expect(_server.to('POST', '/auth/logout-all'), hasLength(1));
      expect(find.byKey(const Key('boton-enviar')), findsOneWidget, reason: 'regresa al login');
      expect(await _store.read(), isNull);
      expect(await tester.runAsync(() => _h.db.select(_h.db.categories).get()), isNotEmpty);
      await finishApp(tester);
    });

    testWidgets('sin conexión no se cierra nada: el servidor no revocó los otros dispositivos', (tester) async {
      _server.handlers['POST /auth/logout-all'] = (_) => throw http.ClientException('sin red');
      await _pump(tester);
      await _open(tester, 'cerrar-sesion-todos');
      await tapKey(tester, const Key('confirmar-cerrar-todos'));
      expect(find.textContaining('necesita internet'), findsOneWidget);
      expect(await _store.read(), isNotNull);
      expect(find.byKey(const Key('boton-enviar')), findsNothing);
      await finishApp(tester);
    });

    testWidgets('cancelar no hace nada', (tester) async {
      await _pump(tester);
      await _open(tester, 'cerrar-sesion-todos');
      await tester.tap(find.byKey(const Key('cancelar-dialogo')));
      await tester.pumpAndSettle();
      expect(_server.to('POST', '/auth/logout-all'), isEmpty);
      expect(await _store.read(), isNotNull);
      await finishApp(tester);
    });
  });

  group('eliminar cuenta', () {
    Future<void> seedLocal(WidgetTester tester) => tester.runAsync(() async {
          await seedCatalog(_h.db);
          await _h.store.saveAccount(id: 'acc-1', type: 'efectivo', name: 'Cartera', initialBalance: Money.parse('100'));
        });

    testWidgets('contraseña incorrecta: el servidor la rechaza y no se borra nada local', (tester) async {
      _server.handlers['POST /auth/delete-account'] = (_) => _json(403, {'error': 'La contraseña no es correcta', 'code': 'invalid_password'});
      await _pump(tester);
      await seedLocal(tester);
      await _open(tester, 'eliminar-cuenta');
      expect(find.textContaining('No se puede deshacer'), findsOneWidget);

      await tapKey(tester, const Key('confirmar-eliminar-cuenta'));
      expect(find.text('Escribe tu contraseña para confirmar'), findsOneWidget);
      expect(_server.to('POST', '/auth/delete-account'), isEmpty);

      await enter(tester, const Key('campo-contrasena-eliminar'), 'equivocada1');
      await tapKey(tester, const Key('confirmar-eliminar-cuenta'));
      expect(find.text('La contraseña no es correcta'), findsOneWidget);
      expect(await _store.read(), isNotNull);
      expect(await tester.runAsync(() => _h.db.select(_h.db.accounts).get()), hasLength(1));
      await finishApp(tester);
    });

    testWidgets('con la contraseña correcta borra la cuenta, vacía la base de este dispositivo y vuelve al login', (tester) async {
      _server.handlers['POST /auth/delete-account'] = (b) => b['password'] == 'password123'
          ? http.Response('', 204)
          : _json(403, {'error': 'La contraseña no es correcta', 'code': 'invalid_password'});
      await _pump(tester);
      await seedLocal(tester);
      await _h.db.writeState('cursor', 'c1');
      await _open(tester, 'eliminar-cuenta');
      await enter(tester, const Key('campo-contrasena-eliminar'), 'password123');
      await tapKey(tester, const Key('confirmar-eliminar-cuenta'));
      await settleDb(tester);

      expect(_server.to('POST', '/auth/delete-account').single.body, {'password': 'password123'});
      expect(find.byKey(const Key('boton-enviar')), findsOneWidget, reason: 'regresa al login');
      expect(await _store.read(), isNull);
      await tester.runAsync(() async {
        for (final table in _h.db.allTables) {
          expect(await _h.db.select(table).get(), isEmpty, reason: table.actualTableName);
        }
      });
      await finishApp(tester);
    });

    testWidgets('si el servidor no responde, la base local no se toca', (tester) async {
      _server.handlers['POST /auth/delete-account'] = (_) => throw http.ClientException('sin red');
      await _pump(tester);
      await seedLocal(tester);
      await _open(tester, 'eliminar-cuenta');
      await enter(tester, const Key('campo-contrasena-eliminar'), 'password123');
      await tapKey(tester, const Key('confirmar-eliminar-cuenta'));
      expect(find.textContaining('necesita internet'), findsOneWidget);
      expect(await _store.read(), isNotNull);
      expect(await tester.runAsync(() => _h.db.select(_h.db.accounts).get()), hasLength(1));
      await finishApp(tester);
    });
  });

  testWidgets('la sesión guardada por una versión anterior (sin plan) se lee como plan gratuito', (tester) async {
    final session = Session.fromJson({'token': 't', 'user_id': 'u1', 'email': 'a@b.c', 'name': 'A'});
    expect(session.plan, 'free');
    expect(session.copyWith(plan: 'premium').plan, 'premium');
    expect(session.copyWith(name: 'B').plan, 'free');
  });

  group('letra al 200 %', () {
    testWidgets('Perfil y cada diálogo se ven sin desbordes en una pantalla angosta', (tester) async {
      _server.handlers['POST /auth/password'] = (_) => _json(403, {'error': 'La contraseña no es correcta', 'code': 'invalid_password'});
      // 360 de ancho (teléfono angosto) y alto de sobra para que se construya toda la lista (las filas son perezosas).
      await _pump(tester, size: const Size(360 * 2, 3000 * 2), textScale: 2);
      expect(tester.takeException(), isNull);
      for (final (open, field, cancel) in [
        ('perfil-nombre', 'campo-nombre-perfil', 'cancelar-dialogo'),
        ('perfil-correo', 'campo-correo-nuevo', 'cancelar-dialogo'),
        ('perfil-contrasena', 'campo-contrasena-confirmar', 'cancelar-dialogo'),
        ('cerrar-sesion-todos', 'confirmar-cerrar-todos', 'cancelar-dialogo'),
        ('eliminar-cuenta', 'campo-contrasena-eliminar', 'cancelar-dialogo'),
      ]) {
        await _open(tester, open);
        expect(find.byKey(Key(field)), findsOneWidget, reason: open);
        expect(tester.takeException(), isNull, reason: open);
        await tester.tap(find.byKey(Key(cancel)));
        await tester.pumpAndSettle();
      }
      await _open(tester, 'perfil-contrasena');
      await enter(tester, const Key('campo-contrasena-actual'), 'x');
      await enter(tester, const Key('campo-contrasena-nueva'), 'nueva-clave-456');
      await enter(tester, const Key('campo-contrasena-confirmar'), 'nueva-clave-456');
      await tapKey(tester, const Key('guardar-contrasena'));
      expect(find.byKey(const Key('error-dialogo')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await finishApp(tester);
    });
  });
}
