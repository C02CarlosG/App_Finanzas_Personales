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
import 'package:finanzas_personales/core/money/money.dart';
import 'package:finanzas_personales/core/network/api_client.dart';
import 'package:finanzas_personales/core/sync/stamp.dart';
import 'package:finanzas_personales/core/sync/sync_api.dart';
import 'package:finanzas_personales/core/sync/sync_engine.dart';
import 'package:finanzas_personales/features/auth/data/auth_repository.dart';
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
}
