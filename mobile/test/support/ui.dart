import 'dart:convert';

import 'package:finanzas_personales/app.dart';
import 'package:finanzas_personales/core/providers.dart';
import 'package:finanzas_personales/core/storage/session_store.dart';
import 'package:finanzas_personales/core/sync/sync_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../sync/support.dart';

const testSession = Session(token: 't', userId: 'u1', email: 'ana@example.com', name: 'Ana');

/// Controlador de sync fijo (sin temporizadores) para probar la interfaz en cada estado.
class StubSyncController extends SyncController {
  StubSyncController(this.initial);
  final SyncStatus initial;

  @override
  SyncStatus build() => initial;

  @override
  void scheduleSoon() {}

  @override
  Future<void> syncNow() async {}
}

http.Response jsonResponse(int status, Object body) => http.Response(jsonEncode(body), status);

/// Monta la app con la base en memoria del [Harness] y un servidor HTTP simulado.
Future<void> pumpApp(
  WidgetTester tester,
  Harness h, {
  SyncStatus sync = const SyncStatus(phase: SyncPhase.disabled),
  MockClient? client,
  List<Override> extra = const [],
  Size size = const Size(800, 1600),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      sessionStoreProvider.overrideWithValue(MemorySessionStore(testSession)),
      httpClientProvider.overrideWithValue(client ?? MockClient((_) async => jsonResponse(404, {'code': 'not_found', 'error': 'no'}))),
      databaseProvider.overrideWithValue(h.db),
      localStoreProvider.overrideWithValue(h.store),
      syncEngineProvider.overrideWithValue(null),
      syncControllerProvider.overrideWith(() => StubSyncController(sync)),
      ...extra,
    ],
    child: const FinanzasApp(),
  ));
  await tester.pumpAndSettle();
}

Future<void> goToTab(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));
  await tester.pumpAndSettle();
}

/// Escrituras a la base fuera del tiempo simulado de `testWidgets` (drift necesita tiempo real).
Future<void> seedDb(WidgetTester tester, Future<void> Function() body) async {
  await tester.runAsync(body);
  await tester.pumpAndSettle();
}

/// Cierra la prueba: desmonta la app y deja correr los temporizadores de cero segundos que drift
/// deja al cancelar sus streams (si no, flutter_test reporta "Timer is still pending").
Future<void> finishApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 10));
}

/// Espera a que terminen las escrituras que dispara la interfaz (tiempo real + cuadros).
///
/// Una escritura con transacciones anidadas (p. ej. un abono de préstamo) alterna entre tareas en tiempo
/// real y temporizadores del reloj simulado: por eso se avanzan los dos varias veces.
Future<void> settleDb(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

/// Escribe en el campo identificado por [key] (sirve también para widgets que envuelven un TextFormField).
Future<void> enter(WidgetTester tester, Key key, String text) async {
  final field = find.descendant(of: find.byKey(key), matching: find.byType(EditableText));
  await tester.enterText(field.evaluate().isEmpty ? find.byKey(key) : field, text);
}

/// Toca un widget por clave, haciéndolo visible antes (formularios largos).
Future<void> tapKey(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}
