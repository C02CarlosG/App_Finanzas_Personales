import 'package:finanzas_personales/core/data/validation_exception.dart';
import 'package:finanzas_personales/core/money/money.dart';
import 'package:finanzas_personales/features/accounts/data/accounts_repository.dart';
import 'package:finanzas_personales/features/categories/data/categories_repository.dart';
import 'package:finanzas_personales/features/transactions/data/transactions_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/catalog.dart';
import '../sync/support.dart';

Matcher invalid(String text) =>
    throwsA(isA<ValidationException>().having((e) => e.message, 'message', contains(text)));

void main() {
  late Harness h;
  late AccountsRepository accounts;
  late CategoriesRepository categories;
  late TransactionsRepository transactions;
  var n = 0;
  String id() => 'id-${++n}';

  setUp(() async {
    h = Harness();
    n = 0;
    await seedCatalog(h.db);
    accounts = AccountsRepository(h.store, newId: id);
    categories = CategoriesRepository(h.store, newId: id);
    transactions = TransactionsRepository(h.store, newId: id);
  });
  tearDown(() => h.close());

  group('cuentas', () {
    test('cuenta de banco: nombre por defecto = banco, saldo inicial y tarjeta', () async {
      final a = await accounts.createBankAccount(bankId: Catalog.santander, cardType: 'credito', initialBalance: Money.parse('-1500.50'));
      final row = await h.db.select(h.db.accounts).getSingle();
      expect([row.id, row.type, row.bankId, row.name, row.cardType, row.initialBalanceCents], [a, 'banco', Catalog.santander, 'Santander', 'credito', -150050]);
      expect((await h.outbox()).single.entity, 'accounts'); // quedó en la outbox
    });

    test('efectivo: nombre por defecto y sin banco ni tarjeta', () async {
      await accounts.createCashAccount(initialBalance: Money.parse('300'));
      final row = await h.db.select(h.db.accounts).getSingle();
      expect([row.type, row.name, row.bankId, row.cardType, row.initialBalanceCents], ['efectivo', 'Efectivo', null, null, 30000]);
    });

    test('valida banco inexistente, nombre largo, tarjeta inválida y monto enorme', () async {
      await expectLater(accounts.createBankAccount(bankId: 'nope'), invalid('banco'));
      await expectLater(accounts.createCashAccount(name: 'x' * 101), invalid('largo'));
      await expectLater(accounts.createBankAccount(bankId: Catalog.bbva, cardType: 'oro'), invalid('tarjeta'));
      await expectLater(accounts.createCashAccount(initialBalance: const Money(100000000000000)), invalid('grande'));
      expect(await h.db.select(h.db.accounts).get(), isEmpty);
    });

    test('editar conserva tipo y banco; efectivo ignora el tipo de tarjeta', () async {
      final bank = await accounts.createBankAccount(bankId: Catalog.bbva);
      final cash = await accounts.createCashAccount();
      await accounts.update(bank, name: 'Nómina', cardType: 'debito', initialBalance: Money.parse('50'));
      await accounts.update(cash, name: 'Cartera', cardType: 'debito', initialBalance: Money.zero);
      final rows = {for (final r in await h.db.select(h.db.accounts).get()) r.id: r};
      expect([rows[bank]!.name, rows[bank]!.bankId, rows[bank]!.cardType], ['Nómina', Catalog.bbva, 'debito']);
      expect([rows[cash]!.name, rows[cash]!.cardType], ['Cartera', null]);
      await expectLater(accounts.update(bank, name: '  ', initialBalance: Money.zero), invalid('nombre'));
      await expectLater(accounts.update('nope', name: 'x', initialBalance: Money.zero), invalid('ya no existe'));
    });

    test('no se elimina una cuenta con movimientos; sin movimientos sí', () async {
      final a = await accounts.createCashAccount();
      await transactions.add(type: 'expense', amount: Money.parse('10'), accountId: a, categoryId: Catalog.comida, occurredOn: '2026-10-01');
      await expectLater(accounts.delete(a), invalid('movimientos'));
      final tx = (await h.db.select(h.db.transactions).getSingle()).id;
      await transactions.delete(tx);
      await accounts.delete(a);
      expect(await (h.db.select(h.db.accounts)..where((x) => x.deletedAt.isNull())).get(), isEmpty);
    });
  });

  group('categorías', () {
    test('crea con color y exige nombre único por tipo sin distinguir mayúsculas', () async {
      await categories.create(kind: 'expense', name: 'Mascotas', color: '#1B7F5C');
      await expectLater(categories.create(kind: 'expense', name: ' mascotas '), invalid('Ya existe'));
      await categories.create(kind: 'income', name: 'Mascotas'); // otro tipo: permitido
      await expectLater(categories.create(kind: 'expense', name: ''), invalid('nombre'));
      await expectLater(categories.create(kind: 'expense', name: 'y' * 61), invalid('largo'));
      await expectLater(categories.create(kind: 'expense', name: 'Z', color: 'rojo'), invalid('Color'));
      await expectLater(categories.create(kind: 'otro', name: 'Z'), invalid('inválido'));
    });

    test('renombrar permite conservar el propio nombre pero no tomar el de otra', () async {
      final a = await categories.create(kind: 'expense', name: 'Viajes');
      await categories.create(kind: 'expense', name: 'Ropa');
      await categories.update(a, name: 'viajes', color: '#C62828'); // mismo nombre, otro color
      await expectLater(categories.update(a, name: 'ROPA'), invalid('Ya existe'));
    });

    test('las categorías del sistema solo cambian de color y no se eliminan', () async {
      await categories.update(Catalog.prestamoCobrado, name: 'Préstamo cobrado', color: '#AD1457');
      await expectLater(categories.update(Catalog.prestamoCobrado, name: 'Otro'), invalid('sistema'));
      await expectLater(categories.delete(Catalog.prestamoCobrado), invalid('sistema'));
    });

    test('no se elimina una categoría con movimientos', () async {
      final acc = await accounts.createCashAccount();
      await transactions.add(type: 'expense', amount: Money.parse('10'), accountId: acc, categoryId: Catalog.comida, occurredOn: '2026-10-01');
      await expectLater(categories.delete(Catalog.comida), invalid('movimientos'));
      final c = await categories.create(kind: 'expense', name: 'Temporal');
      await categories.delete(c);
    });
  });

  group('movimientos', () {
    late String acc;
    setUp(() async => acc = await accounts.createCashAccount(initialBalance: Money.parse('100')));

    test('alta correcta limpia espacios y deja la outbox', () async {
      final t = await transactions.add(
          type: 'expense', amount: Money.parse('50.5'), accountId: acc, categoryId: Catalog.comida, occurredOn: '2026-10-19', description: '  Súper  ', counterparty: '  ');
      final row = await h.db.select(h.db.transactions).getSingle();
      expect([row.id, row.amountCents, row.description, row.counterparty], [t, 5050, 'Súper', null]);
      expect((await h.outbox()).map((e) => e.entity), contains('transactions'));
    });

    test('valida monto, fecha, cuenta, categoría y su tipo', () async {
      Future<void> add({Money? amount, String? date, String? account, String? cat, String type = 'expense'}) =>
          transactions.add(type: type, amount: amount ?? Money.parse('1'), accountId: account ?? acc, categoryId: cat ?? Catalog.comida, occurredOn: date ?? '2026-10-19');
      await expectLater(add(amount: Money.zero), invalid('mayor a 0'));
      await expectLater(add(amount: const Money(-5)), invalid('mayor a 0'));
      await expectLater(add(amount: const Money(100000000000000)), invalid('grande'));
      await expectLater(add(date: '19/10/2026'), invalid('Fecha'));
      await expectLater(add(account: 'nope'), invalid('cuenta'));
      await expectLater(add(cat: 'nope'), invalid('categoría'));
      await expectLater(add(type: 'income'), invalid('no corresponde')); // categoría de gasto en un ingreso
      await expectLater(add(type: 'transfer'), invalid('inválido'));
      expect(await h.db.select(h.db.transactions).get(), isEmpty);
    });

    test('editar cambia los campos; editar uno eliminado falla', () async {
      final t = await transactions.add(type: 'expense', amount: Money.parse('10'), accountId: acc, categoryId: Catalog.comida, occurredOn: '2026-10-19');
      await transactions.update(t, type: 'income', amount: Money.parse('99.99'), accountId: acc, categoryId: Catalog.salario, occurredOn: '2026-10-20', description: 'Bono');
      final row = await h.db.select(h.db.transactions).getSingle();
      expect([row.type, row.amountCents, row.categoryId, row.occurredOn, row.description], ['income', 9999, Catalog.salario, '2026-10-20', 'Bono']);
      await transactions.delete(t);
      await expectLater(
          transactions.update(t, type: 'income', amount: Money.parse('1'), accountId: acc, categoryId: Catalog.salario, occurredOn: '2026-10-20'),
          invalid('ya no existe'));
    });

    test('el nombre de la persona se guarda (préstamo cobrado)', () async {
      await transactions.add(type: 'income', amount: Money.parse('500'), accountId: acc, categoryId: Catalog.prestamoCobrado, occurredOn: '2026-10-19', counterparty: 'Luis Pérez');
      expect((await h.db.select(h.db.transactions).getSingle()).counterparty, 'Luis Pérez');
    });
  });
}
