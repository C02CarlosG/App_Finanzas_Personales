import 'package:finanzas_personales/core/format/dates.dart';
import 'package:finanzas_personales/core/money/money.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/catalog.dart';
import '../support/ui.dart';
import '../sync/support.dart';

void main() {
  late Harness h;
  setUp(() async {
    h = Harness();
    await seedCatalog(h.db);
  });
  tearDown(() => h.close());

  Future<void> oneAccount(WidgetTester tester, {String balance = '1000'}) => tester.runAsync(
        () => h.store.saveAccount(id: 'acc-1', type: 'banco', bankId: Catalog.bbva, name: 'Nómina', initialBalance: Money.parse(balance)),
      );

  Future<void> pickCategory(WidgetTester tester, String name) async {
    await tester.ensureVisible(find.byKey(const Key('campo-categoria')));
    await tester.tap(find.byKey(const Key('campo-categoria')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(name).last);
    await tester.pumpAndSettle();
  }

  group('formulario', () {
    testWidgets('agregar un gasto: la cuenta única se preselecciona; el saldo y la lista se actualizan', (tester) async {
      await oneAccount(tester);
      await pumpApp(tester, h);
      await tester.tap(find.byKey(const Key('agregar-gasto')));
      await tester.pumpAndSettle();
      expect(find.text('Nuevo gasto'), findsOneWidget);
      expect(find.textContaining('Nómina'), findsWidgets); // cuenta preseleccionada

      await enter(tester, const Key('campo-monto'), r'$250.50');
      await pickCategory(tester, 'Alimentación');
      await enter(tester, const Key('campo-descripcion'), '  Súper  ');
      await tapKey(tester, const Key('guardar-movimiento'));
      await settleDb(tester);

      expect(find.text('Gasto guardado'), findsOneWidget);
      expect(find.text(r'$749.50'), findsWidgets); // 1000 − 250.50
      expect(find.text('Súper'), findsOneWidget);
      expect(find.text(r'-$250.50'), findsOneWidget);
      final row = (await tester.runAsync(() => h.db.select(h.db.transactions).getSingle()))!;
      expect([row.type, row.amountCents, row.categoryId, row.accountId, row.description, row.occurredOn], ['expense', 25050, Catalog.comida, 'acc-1', 'Súper', isoDate(DateTime.now())]);
      expect((await tester.runAsync(() => h.outbox()))!.map((e) => e.entity), contains('transactions'));
      await finishApp(tester);
    });

    testWidgets('agregar un ingreso solo ofrece categorías de ingresos', (tester) async {
      await oneAccount(tester);
      await pumpApp(tester, h);
      await tester.tap(find.byKey(const Key('agregar-ingreso')));
      await tester.pumpAndSettle();
      expect(find.text('Nuevo ingreso'), findsOneWidget);
      await enter(tester, const Key('campo-monto'), '3000');
      await tester.ensureVisible(find.byKey(const Key('campo-categoria')));
      await tester.tap(find.byKey(const Key('campo-categoria')));
      await tester.pumpAndSettle();
      expect(find.text('Salario / quincena'), findsWidgets);
      expect(find.text('Vivienda'), findsNothing);
      await tester.tap(find.text('Salario / quincena').last);
      await tester.pumpAndSettle();
      await tapKey(tester, const Key('guardar-movimiento'));
      await settleDb(tester);
      expect(find.text(r'$4,000.00'), findsWidgets);
      expect(find.text('+\$3,000.00'), findsOneWidget);
      await finishApp(tester);
    });

    testWidgets('valida monto, categoría y cuenta antes de guardar', (tester) async {
      await pumpApp(tester, h); // sin cuentas
      await tester.tap(find.byKey(const Key('agregar-gasto')));
      await tester.pumpAndSettle();
      await tapKey(tester, const Key('guardar-movimiento'));
      expect(find.text('Escribe un monto'), findsOneWidget);
      expect(find.text('Elige una categoría'), findsOneWidget);
      expect(find.text('Elige una cuenta'), findsOneWidget);
      await enter(tester, const Key('campo-monto'), '0');
      await tapKey(tester, const Key('guardar-movimiento'));
      expect(find.text('El monto debe ser mayor a 0'), findsOneWidget);
      await enter(tester, const Key('campo-monto'), '1.234');
      await tapKey(tester, const Key('guardar-movimiento'));
      expect(find.textContaining('Monto inválido'), findsOneWidget);
      expect((await tester.runAsync(() => h.db.select(h.db.transactions).get()))!, isEmpty);
      await finishApp(tester);
    });

    testWidgets('"Préstamo cobrado" pide el nombre de la persona y lo guarda', (tester) async {
      await oneAccount(tester);
      await pumpApp(tester, h);
      await tester.tap(find.byKey(const Key('agregar-ingreso')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('campo-persona')), findsNothing);
      await enter(tester, const Key('campo-monto'), '500');
      await pickCategory(tester, 'Préstamo cobrado');
      expect(find.byKey(const Key('campo-persona')), findsOneWidget);

      await tapKey(tester, const Key('guardar-movimiento'));
      expect(find.text('Escribe el nombre de la persona'), findsOneWidget);
      await enter(tester, const Key('campo-persona'), 'Luis Pérez');
      await tapKey(tester, const Key('guardar-movimiento'));
      await settleDb(tester);
      final row = (await tester.runAsync(() => h.db.select(h.db.transactions).getSingle()))!;
      expect([row.categoryId, row.counterparty], [Catalog.prestamoCobrado, 'Luis Pérez']);
      expect(find.textContaining('Luis Pérez'), findsOneWidget); // se ve en la lista
      await finishApp(tester);
    });

    testWidgets('crear una cuenta desde el formulario la deja seleccionada (spec 5.3)', (tester) async {
      await pumpApp(tester, h); // sin cuentas
      await tester.tap(find.byKey(const Key('agregar-gasto')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('campo-cuenta-0-null-0')));
      await tester.tap(find.byKey(const Key('campo-cuenta-0-null-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('+ Crear cuenta o banco nuevo').last);
      await tester.pumpAndSettle();
      expect(find.text('Agregar cuenta'), findsOneWidget);

      await tapKey(tester, const Key('banco-santander'));
      await enter(tester, const Key('campo-saldo-inicial'), '800');
      await tapKey(tester, const Key('guardar-cuenta'));
      await settleDb(tester);

      expect(find.text('Nuevo gasto'), findsOneWidget); // volvió al formulario
      expect(find.textContaining('Santander · \$800.00'), findsOneWidget); // con la cuenta ya elegida
      await enter(tester, const Key('campo-monto'), '100');
      await pickCategory(tester, 'Vivienda');
      await tapKey(tester, const Key('guardar-movimiento'));
      await settleDb(tester);
      final accounts = (await tester.runAsync(() => h.db.select(h.db.accounts).get()))!;
      final row = (await tester.runAsync(() => h.db.select(h.db.transactions).getSingle()))!;
      expect(row.accountId, accounts.single.id);
      await finishApp(tester);
    });

    testWidgets('cancelar "crear cuenta" no deja la opción seleccionada en el formulario', (tester) async {
      await pumpApp(tester, h); // sin cuentas
      await tester.tap(find.byKey(const Key('agregar-gasto')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('campo-cuenta-0-null-0')));
      await tester.tap(find.byKey(const Key('campo-cuenta-0-null-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('+ Crear cuenta o banco nuevo').last);
      await tester.pumpAndSettle();
      expect(find.text('Agregar cuenta'), findsOneWidget);

      await tester.tap(find.byType(BackButton)); // cancela sin crear nada
      await tester.pumpAndSettle();

      expect(find.text('Nuevo gasto'), findsOneWidget);
      // El desplegable quedó vacío: la opción de crear no se queda como si fuera la cuenta elegida.
      expect(find.text('+ Crear cuenta o banco nuevo'), findsNothing);
      await finishApp(tester);
    });

    testWidgets('elegir otra fecha con el selector en español', (tester) async {
      await oneAccount(tester);
      await pumpApp(tester, h);
      await tester.tap(find.byKey(const Key('agregar-gasto')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('campo-fecha')));
      await tester.tap(find.byKey(const Key('campo-fecha')));
      await tester.pumpAndSettle();
      expect(find.text('ACEPTAR'), findsOneWidget); // localizado (es-MX)
      final day = DateTime.now().day == 10 ? '11' : '10';
      await tester.tap(find.text(day).last);
      await tester.tap(find.text('ACEPTAR'));
      await tester.pumpAndSettle();
      expect(find.textContaining('$day ${formatDate(isoDate(DateTime.now())).split(' ')[1]}'), findsOneWidget);
      await finishApp(tester);
    });
  });

  group('editar y eliminar', () {
    Future<void> withExpense(WidgetTester tester) async {
      await oneAccount(tester);
      await tester.runAsync(() => h.store.saveTransaction(
          id: 't1', type: 'expense', amount: Money.parse('100'), accountId: 'acc-1', categoryId: Catalog.comida, occurredOn: '2026-10-19', description: 'Tacos'));
    }

    testWidgets('al tocar un movimiento se abre prellenado y los cambios se guardan', (tester) async {
      await withExpense(tester);
      await pumpApp(tester, h);
      await tester.tap(find.byKey(const Key('movimiento-t1')));
      await tester.pumpAndSettle();
      expect(find.text('Editar gasto'), findsOneWidget);
      expect(find.text('Tacos'), findsOneWidget);
      expect(tester.widget<EditableText>(find.descendant(of: find.byKey(const Key('campo-monto')), matching: find.byType(EditableText))).controller.text, '100.00');

      await enter(tester, const Key('campo-monto'), '120.75');
      await enter(tester, const Key('campo-descripcion'), 'Tacos y refresco');
      await tapKey(tester, const Key('guardar-movimiento'));
      await settleDb(tester);
      expect(find.text('Tacos y refresco'), findsOneWidget);
      expect(find.text(r'-$120.75'), findsOneWidget);
      expect(find.text(r'$879.25'), findsWidgets); // 1000 − 120.75
      await finishApp(tester);
    });

    testWidgets('eliminar pide confirmación y devuelve el saldo', (tester) async {
      await withExpense(tester);
      await pumpApp(tester, h);
      expect(find.text(r'$900.00'), findsWidgets);
      await tester.tap(find.byKey(const Key('movimiento-t1')));
      await tester.pumpAndSettle();
      await tapKey(tester, const Key('eliminar-movimiento'));
      await tapKey(tester, const Key('confirmar-eliminar'));
      await settleDb(tester);
      expect(find.byKey(const Key('movimiento-t1')), findsNothing);
      expect(find.byKey(const Key('sin-movimientos')), findsOneWidget);
      expect(find.text(r'$1,000.00'), findsWidgets);
      await finishApp(tester);
    });
  });

  group('Inicio', () {
    testWidgets('sin cuentas invita a agregar la primera', (tester) async {
      await pumpApp(tester, h);
      expect(find.byKey(const Key('invitacion-cuenta')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('saldo-total'))).data, r'$0.00');
      expect(find.byKey(const Key('sin-movimientos')), findsOneWidget);
      await tester.tap(find.byKey(const Key('invitacion-cuenta')));
      await tester.pumpAndSettle();
      expect(find.text('Agregar cuenta'), findsOneWidget);
      await finishApp(tester);
    });

    testWidgets('muestra solo los 10 movimientos más recientes, el más nuevo primero', (tester) async {
      await oneAccount(tester);
      await tester.runAsync(() async {
        for (var i = 1; i <= 12; i++) {
          await h.store.saveTransaction(
              id: 't$i', type: 'expense', amount: Money.parse('1'), accountId: 'acc-1', categoryId: Catalog.comida,
              occurredOn: '2026-10-${i.toString().padLeft(2, '0')}', description: 'Mov $i');
        }
      });
      await pumpApp(tester, h);
      expect(find.byKey(const Key('movimiento-t12')), findsOneWidget);
      expect(find.byKey(const Key('movimiento-t3')), findsOneWidget);
      expect(find.byKey(const Key('movimiento-t2')), findsNothing);
      expect(find.byKey(const Key('movimiento-t1')), findsNothing);
      expect(tester.getTopLeft(find.byKey(const Key('movimiento-t12'))).dy, lessThan(tester.getTopLeft(find.byKey(const Key('movimiento-t11'))).dy));
      await finishApp(tester);
    });

    testWidgets('un movimiento pendiente de enviar y uno huérfano se distinguen', (tester) async {
      await oneAccount(tester);
      await tester.runAsync(() async {
        await h.store.saveTransaction(
            id: 't1', type: 'expense', amount: Money.parse('5'), accountId: 'acc-1', categoryId: Catalog.comida, occurredOn: '2026-10-19', description: 'Normal');
        await h.store.saveTransaction(
            id: 't2', type: 'expense', amount: Money.parse('5'), accountId: 'no-existe', categoryId: Catalog.comida, occurredOn: '2026-10-18', description: 'Huérfano');
      });
      await pumpApp(tester, h);
      expect(find.byIcon(Icons.cloud_upload_outlined), findsNWidgets(2)); // ambos siguen en la outbox
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget); // solo el huérfano
      expect(find.descendant(of: find.byKey(const Key('movimiento-t2')), matching: find.byIcon(Icons.warning_amber_rounded)), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('movimiento-t1')), matching: find.byIcon(Icons.warning_amber_rounded)), findsNothing);
      await finishApp(tester);
    });
  });
}
