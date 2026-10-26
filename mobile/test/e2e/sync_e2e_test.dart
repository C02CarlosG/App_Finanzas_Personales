// Prueba de extremo a extremo: dos "dispositivos" (SQLite en memoria) contra la API real.
//
// Se omite salvo que exista E2E_API_URL. Para correrla:
//   cd backend && SYNC_SAFETY_LAG_MS=0 PORT=3111 JWT_SECRET=x DATABASE_URL=... npm run migrate && node src/server.js
//   cd mobile && E2E_API_URL=http://localhost:3111 flutter test test/e2e
import 'dart:io';

import 'package:drift/drift.dart' show BooleanExpressionOperators, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:finanzas_personales/core/db/app_database.dart';
import 'package:finanzas_personales/core/db/local_store.dart';
import 'package:finanzas_personales/core/db/queries.dart';
import 'package:finanzas_personales/core/db/queries_fase2.dart';
import 'package:finanzas_personales/core/money/money.dart';
import 'package:finanzas_personales/core/network/api_client.dart';
import 'package:finanzas_personales/core/sync/stamp.dart';
import 'package:finanzas_personales/core/sync/sync_api.dart';
import 'package:finanzas_personales/core/sync/sync_engine.dart';
import 'package:finanzas_personales/features/accounts/data/accounts_repository.dart';
import 'package:finanzas_personales/features/auth/data/auth_repository.dart';
import 'package:finanzas_personales/features/cards/data/credit_cards_repository.dart';
import 'package:finanzas_personales/features/loans/data/loans_repository.dart';
import 'package:finanzas_personales/features/subscriptions/data/subscriptions_repository.dart';
import 'package:finanzas_personales/features/categories/data/categories_repository.dart';
import 'package:finanzas_personales/features/transactions/data/transactions_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

final _baseUrl = Platform.environment['E2E_API_URL'];

class Device {
  Device(this.name, String baseUrl, String Function() token)
      : db = AppDatabase(NativeDatabase.memory()),
        clock = StampClock() {
    api = ApiClient(baseUrl: baseUrl, httpClient: http.Client(), tokenProvider: token);
    late final SyncEngine e;
    store = LocalStore(db, clock, isSyncing: () => e.isSyncing);
    e = SyncEngine(db: db, api: HttpSyncApi(api), store: store, clock: clock);
    engine = e;
  }

  final String name;
  final AppDatabase db;
  final StampClock clock;
  late final ApiClient api;
  late final LocalStore store;
  late final SyncEngine engine;

  Future<SyncReport> sync() => engine.run();

  Future<String> categoryId(String name, String kind) async => (await (db.select(db.categories)
            ..where((t) => t.name.equals(name) & t.kind.equals(kind) & t.deletedAt.isNull()))
          .getSingle())
      .id;

  Future<TransactionRow> tx(String id) => (db.select(db.transactions)..where((t) => t.id.equals(id))).getSingle();
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true; // varias bases en memoria a propósito
  final url = _baseUrl;
  if (url == null) {
    test('e2e contra la API real', () {}, skip: 'Defina E2E_API_URL para correrla');
    return;
  }

  late String token;
  late Device a;
  late Device b;
  const uuid = Uuid();
  String id() => uuid.v4();

  setUp(() async {
    final auth = AuthRepository(ApiClient(baseUrl: url, httpClient: http.Client()));
    final email = 'e2e${DateTime.now().microsecondsSinceEpoch}@example.com';
    token = (await auth.register(name: 'E2E', email: email, password: 'password123')).token;
    a = Device('A', url, () => token);
    b = Device('B', url, () => token);
  });

  tearDown(() async {
    await a.db.close();
    await b.db.close();
  });

  test('el primer sync baja el catálogo de bancos y las categorías sembradas', () async {
    final report = await a.sync();
    expect(report.pulled, greaterThan(30));
    expect((await a.db.select(a.db.banks).get()).length, greaterThanOrEqualTo(16));
    expect(await a.categoryId('Vivienda', 'expense'), isNotEmpty);
    expect(await a.categoryId('Préstamo cobrado', 'income'), isNotEmpty);
  });

  test('A crea cuenta y transacción offline; el saldo del servidor coincide y B las recibe', () async {
    await a.sync();
    final cat = await a.categoryId('Alimentación', 'expense');
    final acc = id();
    final tx = id();
    await a.store.saveAccount(id: acc, type: 'efectivo', name: 'Cartera', initialBalance: Money.parse('1000'));
    await a.store.saveTransaction(
        id: tx, type: 'expense', amount: Money.parse('250.75'), accountId: acc, categoryId: cat, occurredOn: '2026-10-19', description: 'Súper');
    await a.sync();

    final server = await a.api.get('/accounts/$acc');
    expect(server['balance'], '749.25'); // 1000 − 250.75, calculado por el servidor
    expect(await a.db.select(a.db.syncOutbox).get(), isEmpty);

    await b.sync();
    expect((await b.tx(tx)).amountCents, 25075);
    expect((await b.tx(tx)).description, 'Súper');
  });

  test('edición de B (más nueva) gana y llega a A; borrado de A llega a B como tombstone', () async {
    await a.sync();
    final cat = await a.categoryId('Salud', 'expense');
    final acc = id();
    final tx = id();
    await a.store.saveAccount(id: acc, type: 'efectivo', name: 'Cartera');
    await a.store.saveTransaction(
        id: tx, type: 'expense', amount: Money.parse('10'), accountId: acc, categoryId: cat, occurredOn: '2026-10-19');
    await a.sync();
    await b.sync();

    await Future<void>.delayed(const Duration(milliseconds: 20));
    await b.store.saveTransaction(
        id: tx, type: 'expense', amount: Money.parse('99.99'), accountId: acc, categoryId: cat, occurredOn: '2026-10-19', description: 'B');
    await b.sync();
    await a.sync();
    expect((await a.tx(tx)).amountCents, 9999);
    expect((await a.tx(tx)).description, 'B');

    await a.store.delete('transactions', tx);
    await a.sync();
    await b.sync();
    expect((await b.tx(tx)).deletedAt, isNotNull);
    expect(await b.db.select(b.db.syncOutbox).get(), isEmpty);
  });

  test('ediciones concurrentes offline: ambos dispositivos convergen a la más reciente', () async {
    await a.sync();
    final cat = await a.categoryId('Transporte', 'expense');
    final acc = id();
    final tx = id();
    await a.store.saveAccount(id: acc, type: 'efectivo', name: 'Cartera');
    await a.store.saveTransaction(
        id: tx, type: 'expense', amount: Money.parse('1'), accountId: acc, categoryId: cat, occurredOn: '2026-10-19');
    await a.sync();
    await b.sync();

    // Ambos editan sin conexión; B edita después.
    await a.store.saveTransaction(
        id: tx, type: 'expense', amount: Money.parse('11'), accountId: acc, categoryId: cat, occurredOn: '2026-10-19', description: 'A');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await b.store.saveTransaction(
        id: tx, type: 'expense', amount: Money.parse('22'), accountId: acc, categoryId: cat, occurredOn: '2026-10-19', description: 'B');

    // Llega primero la más nueva (B) y después la vieja (A): A debe perder.
    await b.sync();
    await a.sync();
    await b.sync();
    for (final d in [a, b]) {
      final row = await d.tx(tx);
      expect([row.amountCents, row.description], [2200, 'B'], reason: 'dispositivo ${d.name}');
      expect(await d.db.select(d.db.syncOutbox).get(), isEmpty, reason: d.name);
    }
  });

  test('categoría con el mismo nombre creada en dos dispositivos: el segundo la fusiona', () async {
    await a.sync();
    final acc = id();
    await a.store.saveAccount(id: acc, type: 'efectivo', name: 'Cartera');
    await a.sync();
    await b.sync(); // B ya conoce la cuenta
    final catA = id();
    final catB = id();
    final txB = id();
    await a.store.saveCategory(id: catA, kind: 'expense', name: 'Mascotas');
    await a.sync();
    // B, sin haber visto la categoría de A, crea una con el mismo nombre y gasta en ella.
    await b.store.saveCategory(id: catB, kind: 'expense', name: 'mascotas');
    await b.store.saveTransaction(
        id: txB, type: 'expense', amount: Money.parse('80'), accountId: acc, categoryId: catB, occurredOn: '2026-10-19');
    await b.sync(); // catB choca con catA → fusión local; la transacción se reasigna y queda pendiente

    expect((await b.db.select(b.db.categories).get()).where((c) => c.id == catB), isEmpty);
    expect((await b.tx(txB)).categoryId, catA);
    await b.sync(); // sube la transacción reasignada
    expect(await b.db.select(b.db.syncOutbox).get(), isEmpty);
    expect((await b.api.get('/transactions/$txB'))['category_id'], catA);
  });

  test('borrar una cuenta que el servidor ve en uso se rechaza y la cuenta "resucita"', () async {
    await a.sync();
    final cat = await a.categoryId('Educación', 'expense');
    final acc = id();
    await a.store.saveAccount(id: acc, type: 'efectivo', name: 'Cartera');
    await a.sync();
    await b.sync();
    await b.store.saveTransaction(
        id: id(), type: 'expense', amount: Money.parse('5'), accountId: acc, categoryId: cat, occurredOn: '2026-10-19');
    await b.sync(); // B usa la cuenta
    await a.store.delete('accounts', acc); // A (sin saberlo) la borra
    await a.sync();
    final row = await (a.db.select(a.db.accounts)..where((t) => t.id.equals(acc))).getSingle();
    expect(row.deletedAt, isNull);
    expect(await a.db.select(a.db.syncOutbox).get(), isEmpty);
  });

  test('lo que crean los repositorios de la app (reglas locales) lo acepta el backend y el saldo coincide', () async {
    await a.sync(); // baja bancos y categorías del servidor
    final accounts = AccountsRepository(a.store);
    final categories = CategoriesRepository(a.store);
    final transactions = TransactionsRepository(a.store);

    final bank = (await a.db.select(a.db.banks).get()).firstWhere((b) => b.logoKey == 'bbva');
    final acc = await accounts.createBankAccount(bankId: bank.id, cardType: 'debito', initialBalance: Money.parse('2500.40'));
    final cash = await accounts.createCashAccount(initialBalance: Money.parse('-100'));
    final cat = await categories.create(kind: 'expense', name: 'Mascotas', color: '#C62828');
    final loan = (await a.db.select(a.db.categories).get()).firstWhere((c) => c.name == 'Préstamo cobrado');
    final t1 = await transactions.add(type: 'expense', amount: Money.parse('300.15'), accountId: acc, categoryId: cat, occurredOn: '2026-10-19', description: '  Croquetas ');
    final t2 = await transactions.add(
        type: 'income', amount: Money.parse('1000'), accountId: cash, categoryId: loan.id, occurredOn: '2026-10-19', counterparty: 'Luis Pérez');
    final t3 = await transactions.add(type: 'expense', amount: Money.parse('5'), accountId: cash, categoryId: cat, occurredOn: '2026-10-19');
    await transactions.update(t3, type: 'expense', amount: Money.parse('7.50'), accountId: cash, categoryId: cat, occurredOn: '2026-10-20');
    await transactions.delete(t3);
    await a.sync();

    expect(await a.db.select(a.db.syncOutbox).get(), isEmpty, reason: 'el servidor aceptó todo');
    expect((await a.api.get('/accounts/$acc'))['balance'], '2200.25'); // 2500.40 − 300.15
    expect((await a.api.get('/accounts/$cash'))['balance'], '900.00'); // −100 + 1000
    final server1 = await a.api.get('/transactions/$t1');
    expect([server1['description'], server1['amount']], ['Croquetas', '300.15']);
    expect((await a.api.get('/transactions/$t2'))['counterparty'], 'Luis Pérez');
    await expectLater(a.api.get('/transactions/$t3'), throwsA(isA<Object>())); // eliminado en el servidor (404)

    await b.sync();
    expect((await b.tx(t1)).amountCents, 30015); // y el otro dispositivo lo recibe
    expect((await b.db.select(b.db.categories).get()).any((c) => c.id == cat && c.color == '#C62828'), isTrue);
  });

  test('Fase 2: préstamos, tarjetas y suscripciones de la app los acepta el backend y el otro dispositivo converge', () async {
    await a.sync();
    final accounts = AccountsRepository(a.store);
    final loans = LoansRepository(a.store);
    final cards = CreditCardsRepository(a.store);
    final subs = SubscriptionsRepository(a.store);

    final acc = await accounts.createCashAccount(name: 'Cartera', initialBalance: Money.parse('1000'));
    final owedToMe = await loans.create(personName: 'Luis Pérez', direction: 'owed_to_me', principal: Money.parse('500'), dueDate: '2026-12-31');
    final iOwe = await loans.create(personName: 'Mamá', direction: 'i_owe', principal: Money.parse('300'));
    await loans.addIncrease(owedToMe, amount: Money.parse('100'));
    await loans.addPayment(owedToMe, amount: Money.parse('250.50'), accountId: acc, occurredOn: '2026-10-19'); // cobro: +250.50
    await loans.addPayment(iOwe, amount: Money.parse('100'), accountId: acc, occurredOn: '2026-10-19'); // pago: −100
    final card = await cards.create(name: 'BBVA Azul', pendingBalance: Money.parse('2000'), dueDate: '2026-11-10');
    await cards.addPayment(card, amount: Money.parse('500'), accountId: acc, paidOn: '2026-10-19'); // −500
    final sub = await subs.create(name: 'Netflix', amount: Money.parse('199'), renewalDate: '2026-11-01', accountId: acc);
    await a.sync();

    expect(await a.db.select(a.db.syncOutbox).get(), isEmpty, reason: 'el servidor aceptó todo');
    expect((await a.api.get('/accounts/$acc'))['balance'], '650.50'); // 1000 + 250.50 − 100 − 500

    await b.sync();
    final l = (await b.db.findLoan(owedToMe))!;
    expect([l.total.cents, l.payments.cents, l.remaining.cents, l.dueDate], [60000, 25050, 34950, '2026-12-31']);
    expect((await b.db.findLoan(iOwe))!.remaining.cents, 20000);
    expect((await b.db.findCreditCard(card))!.pendingBalance.cents, 150000);
    expect((await b.db.watchCardPayments(card).first).single.amount.cents, 50000);
    expect((await b.db.findSubscription(sub))!.accountName, 'Cartera');
    expect((await b.db.watchAccounts().first).firstWhere((x) => x.id == acc).balance.cents, 65050);

    // B deshace el cobro: el movimiento y su ingreso desaparecen en A y el saldo vuelve a cuadrar.
    final movement = (await b.db.watchLoanMovements(owedToMe).first).firstWhere((m) => m.isPayment);
    await LoansRepository(b.store).deleteMovement(movement.id);
    await b.sync();
    expect(await b.db.select(b.db.syncOutbox).get(), isEmpty, reason: 'borrar movimiento y transacción en orden hijo→padre');
    await a.sync();
    expect((await a.db.findLoan(owedToMe))!.remaining.cents, 60000);
    expect((await a.db.watchAccounts().first).firstWhere((x) => x.id == acc).balance.cents, 40000); // 650.50 − 250.50
    expect((await a.api.get('/accounts/$acc'))['balance'], '400.00');

    // Eliminar el préstamo conserva el gasto del pago; la tarjeta con pagos tampoco arrastra transacciones.
    await LoansRepository(a.store).delete(iOwe);
    await CreditCardsRepository(a.store).delete(card);
    await a.sync();
    expect(await a.db.select(a.db.syncOutbox).get(), isEmpty);
    expect((await a.api.get('/accounts/$acc'))['balance'], '400.00');
    await b.sync();
    expect(await b.db.findLoan(iOwe), isNull);
    expect(await b.db.findCreditCard(card), isNull);
  });

  test('Fase 2: una cuenta usada por una suscripción en otro dispositivo no se pierde al borrarla', () async {
    await a.sync();
    final acc = await AccountsRepository(a.store).createCashAccount(name: 'Vacía');
    await a.sync();
    await b.sync();
    await SubscriptionsRepository(b.store).create(name: 'Spotify', amount: Money.parse('129'), renewalDate: '2026-11-01', accountId: acc);
    await b.sync(); // B usa la cuenta
    await a.store.delete('accounts', acc); // A, sin saberlo, la borra (saltándose la regla local a propósito)
    await a.sync();
    final row = await (a.db.select(a.db.accounts)..where((t) => t.id.equals(acc))).getSingle();
    expect(row.deletedAt, isNull); // el servidor respondió in_use y la cuenta resucitó
    expect((await a.db.findSubscription((await a.db.watchSubscriptions().first).single.id)), isNotNull);
  });
}
