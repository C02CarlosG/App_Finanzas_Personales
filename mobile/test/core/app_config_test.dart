import 'package:finanzas_personales/core/config/app_config.dart';
import 'package:finanzas_personales/core/ui/config_error_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('releaseConfigProblem', () {
    String? check(String url, {bool release = true, bool demo = false}) =>
        releaseConfigProblem(release: release, demo: demo, apiBaseUrl: url);

    test('un release con HTTPS está bien, también con prefijo de ruta o puerto', () {
      expect(check('https://api.ejemplo.mx'), isNull);
      expect(check('https://api.ejemplo.mx/v1'), isNull);
      expect(check('https://api.ejemplo.mx:8443'), isNull);
    });

    test('un release con la dirección del emulador, HTTP o basura se rechaza', () {
      for (final url in ['http://10.0.2.2:3000', 'http://api.ejemplo.mx', 'ftp://x.mx', 'https://', 'api.ejemplo.mx', '', 'https:///ruta']) {
        expect(check(url), isNotNull, reason: url);
      }
      expect(check('http://10.0.2.2:3000'), contains('https://'));
    });

    test('en desarrollo (no release) y en modo demo no se exige nada', () {
      expect(check('http://10.0.2.2:3000', release: false), isNull);
      expect(check('http://10.0.2.2:3000', demo: true), isNull);
    });

    test('las pruebas corren en modo debug, así que la configuración real no tiene problema', () {
      expect(AppConfig.problem, isNull);
    });
  });

  testWidgets('la pantalla de configuración muestra el motivo y no se desborda con letra al 200 %', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const ConfigErrorApp(message: 'Falta API_BASE_URL con https://'));
    expect(find.text('Falta API_BASE_URL con https://'), findsOneWidget);
    expect(find.text('App mal configurada'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
