import 'dart:io';

import 'package:drift/native.dart';
import 'package:finanzas_personales/core/db/app_database.dart';
import 'package:finanzas_personales/core/db/queries.dart';
import 'package:finanzas_personales/core/db/queries_fase2.dart';
import 'package:finanzas_personales/core/money/money.dart';
import 'package:finanzas_personales/features/cards/data/credit_cards_repository.dart';
import 'package:finanzas_personales/features/loans/data/loans_repository.dart';
import 'package:finanzas_personales/features/subscriptions/data/subscriptions_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/catalog.dart';
import 'support.dart';

/// Lo que el servidor devolvería al aplicar un cambio de la Fase 2: el mismo `data` más sellos.
Map<String, dynamic> echo(Map<String, dynamic> change, {String? deletedAt}) => {
      'id': change['id'],
      ...?(change['data'] as Map<String, dynamic>?),
      'updated_at': '2026-10-20T12:00:00.000000Z',
      'client_updated_at': change['client_updated_at'],
      'deleted_at': deletedAt,
    };

void main() {
  late Harness h;
  late LoansRepository loans;
  late CreditCardsRepository cards;
  late SubscriptionsRepository subs;

  setUp(() async {
    h = Harness();
    await seedCatalog(h.db);
    await seedPhase2Categories(h.db);
    loans = LoansRepository(h.store);
    cards = CreditCardsRepository(h.store);
    subs = SubscriptionsRepository(h.store);
    await h.store.saveAccount(id: 'bbva', type: 'banco', bankId: Catalog.bbva, name: 'Nómina', initialBalance: Money.parse('1000'));
    // Por omisión el servidor acepta todo (la cuenta del setUp está pendiente de envío).
    h.api.onPush = (changes) async => pushResponse([for (final c in changes) result(c, 'applied', record: echo(c))]);
  });
  tearDown(() => h.close());

  test('el push lleva los datos de la Fase 2 con dinero como string y padres antes que hijos', () async {
    final loanId = await loans.create(personName: 'Luis', direction: 'owed_to_me', principal: Money.parse('500'), dueDate: '2026-12-01');
    await loans.addPayment(loanId, amount: Money.parse('120.50'), accountId: 'bbva', occurredOn: '2026-10-19');
    final cardId = await cards.create(name: 'Azul', bankId: Catalog.bbva, pendingBalance: Money.parse('900'), dueDate: '2026-11-10');
    await cards.addPayment(cardId, amount: Money.parse('100'), accountId: 'bbva', paidOn: '2026-10-19');
    await subs.create(name: 'Netflix', amount: Money.parse('199'), renewalDate: '2026-11-01', accountId: 'bbva');

    h.api.onPush = (changes) async => pushResponse([
          for (final c in changes) result(c, 'applied', record: echo(c)),
        ]);
    await h.engine.run();

    final sent = h.api.pushes.expand((b) => b).toList();
    final order = [for (final c in sent) c['table']];
    int at(String t) => order.indexOf(t);
    expect(at('accounts'), lessThan(at('transactions')));
    expect(at('loans'), lessThan(at('loan_movements')));
    expect(at('transactions'), lessThan(at('loan_movements')));
    expect(at('credit_cards'), lessThan(at('credit_card_payments')));
    expect(at('transactions'), lessThan(at('credit_card_payments')));

    Map<String, dynamic> data(String table) => sent.firstWhere((c) => c['table'] == table)['data'] as Map<String, dynamic>;
    expect(data('loans'), {
      'person_name': 'Luis',
      'direction': 'owed_to_me',
      'principal': '500.00',
      'due_date': '2026-12-01',
      'status': 'active',
      'notes': null,
    });
    final txId = sent.firstWhere((c) => c['table'] == 'transactions' && (c['data'] as Map)['type'] == 'income')['id'];
    expect(data('loan_movements'), {'loan_id': loanId, 'kind': 'payment', 'amount': '120.50', 'occurred_on': '2026-10-19', 'transaction_id': txId});
    expect(data('credit_cards'), {'bank_id': Catalog.bbva, 'name': 'Azul', 'pending_balance': '800.00', 'due_date': '2026-11-10'});
    expect(data('credit_card_payments')['amount'], '100.00');
    expect(data('subscriptions'), {
      'name': 'Netflix',
      'amount': '199.00',
      'renewal_date': '2026-11-01',
      'period': 'monthly',
      'account_id': 'bbva',
      'active': true,
    });
    expect(await h.outbox(), isEmpty);
  });

  test('el pull aplica las cinco tablas nuevas y los totales del préstamo salen de sus movimientos', () async {
    const t0 = '2026-10-20T10:00:00.000000Z';
    Map<String, dynamic> row(String id, Map<String, dynamic> data, {String? deletedAt}) =>
        {'id': id, ...data, 'updated_at': '2026-10-20T11:00:00.000000Z', 'client_updated_at': t0, 'deleted_at': deletedAt};
    await h.seedFromServer(pullPage(
      loans: [row('l1', {'person_name': 'Ana', 'direction': 'i_owe', 'principal': '1000.00', 'due_date': null, 'status': 'active', 'notes': 'renta'})],
      loanMovements: [
        row('m1', {'loan_id': 'l1', 'kind': 'payment', 'amount': '300.00', 'occurred_on': '2026-10-01', 'transaction_id': null}),
        row('m2', {'loan_id': 'l1', 'kind': 'increase', 'amount': '50.50', 'occurred_on': '2026-10-02', 'transaction_id': null}),
        row('m3', {'loan_id': 'l1', 'kind': 'payment', 'amount': '9.00', 'occurred_on': '2026-10-03', 'transaction_id': null}, deletedAt: t0),
      ],
      subscriptions: [row('s1', {'name': 'Spotify', 'amount': '129.00', 'renewal_date': '2026-11-03', 'period': 'yearly', 'account_id': null, 'active': false})],
      creditCards: [row('c1', {'bank_id': null, 'name': 'Nu', 'pending_balance': '0.00', 'due_date': null})],
      creditCardPayments: [row('p1', {'credit_card_id': 'c1', 'account_id': 'bbva', 'transaction_id': null, 'amount': '75.25', 'paid_on': '2026-10-05'})],
    ));
    final l = (await h.db.findLoan('l1'))!;
    expect([l.iOwe, l.total.cents, l.payments.cents, l.remaining.cents, l.notes], [true, 105050, 30000, 75050, 'renta']); // el movimiento borrado no cuenta
    final s = (await h.db.findSubscription('s1'))!;
    expect([s.period, s.active, s.amount.cents], ['yearly', false, 12900]);
    expect((await h.db.findCreditCard('c1'))!.pendingBalance.cents, 0);
    expect((await h.db.watchCardPayments('c1').first).single.amount.cents, 7525);
    expect(await h.outbox(), isEmpty);
  });

  test('un tombstone de préstamo que llega por pull lo quita del listado', () async {
    final id = await loans.create(personName: 'Ana', direction: 'owed_to_me', principal: Money.parse('10'));
    h.api.onPush = (changes) async => pushResponse([for (final c in changes) result(c, 'applied', record: echo(c))]);
    await h.engine.run();
    expect(await h.db.watchLoans().first, hasLength(1));
    h.api.pullQueue.add(pullPage(loans: [
      {
        'id': id,
        'person_name': 'Ana',
        'direction': 'owed_to_me',
        'principal': '10.00',
        'due_date': null,
        'status': 'active',
        'notes': null,
        'updated_at': '2026-10-21T00:00:00.000000Z',
        'client_updated_at': '2026-10-21T00:00:00.000000Z',
        'deleted_at': '2026-10-21T00:00:00.000000Z',
      }
    ], next: 'c2'));
    await h.engine.run();
    expect(await h.db.watchLoans().first, isEmpty);
  });

  test('in_use al borrar un préstamo (otro dispositivo agregó un movimiento): el préstamo resucita', () async {
    final id = await loans.create(personName: 'Ana', direction: 'owed_to_me', principal: Money.parse('10'));
    h.api.onPush = (changes) async => pushResponse([for (final c in changes) result(c, 'applied', record: echo(c))]);
    await h.engine.run();
    await loans.delete(id);
    expect(await h.db.watchLoans().first, isEmpty);
    h.api.onPush = (changes) async => pushResponse([
          for (final c in changes)
            result(c, 'rejected',
                code: 'in_use',
                record: {
                  'id': id,
                  'person_name': 'Ana',
                  'direction': 'owed_to_me',
                  'principal': '10.00',
                  'due_date': null,
                  'status': 'active',
                  'notes': null,
                  'updated_at': '2026-10-21T00:00:00.000000Z',
                  'client_updated_at': '2026-10-20T00:00:00.000000Z',
                  'deleted_at': null,
                }),
        ]);
    await h.engine.run();
    expect((await h.db.watchLoans().first).single.id, id);
    expect(await h.outbox(), isEmpty);
  });

  test('type_mismatch del servidor bloquea el cambio y la pantalla de problemas lo describe', () async {
    final id = await loans.create(personName: 'Ana', direction: 'owed_to_me', principal: Money.parse('100'));
    await loans.addPayment(id, amount: Money.parse('40'), accountId: 'bbva');
    h.api.onPush = (changes) async => pushResponse([
          for (final c in changes)
            c['table'] == 'loan_movements'
                ? result(c, 'invalid', code: 'type_mismatch', extra: {'message': 'x'})
                : result(c, 'applied', record: echo(c)),
        ]);
    await h.engine.run();
    final problems = await h.db.watchOutboxProblems().first;
    expect(problems.single.entity, 'loan_movements');
    expect(problems.single.blocked, isTrue);
    expect(await h.db.describeOutboxEntry(problems.single), 'Abono de \$40.00 (${(await h.db.select(h.db.loanMovements).getSingle()).occurredOn})');
  });

  test('describeOutboxEntry cubre las entidades de la Fase 2', () async {
    final loanId = await loans.create(personName: 'Ana', direction: 'i_owe', principal: Money.parse('10'));
    final cardId = await cards.create(name: 'Nu', pendingBalance: Money.parse('10'));
    final subId = await subs.create(name: 'Netflix', amount: Money.parse('10'), renewalDate: '2026-11-01');
    final byId = {for (final e in await h.outbox()) e.recordId: e};
    expect(await h.db.describeOutboxEntry(byId[loanId]!), 'Préstamo: Ana');
    expect(await h.db.describeOutboxEntry(byId[cardId]!), 'Tarjeta: Nu');
    expect(await h.db.describeOutboxEntry(byId[subId]!), 'Suscripción: Netflix');
  });

  test('una base de la versión 1 sube a la 2 con las tablas nuevas y conserva sus datos', () async {
    final dir = await Directory.systemTemp.createTemp('migracion_v1');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/finanzas.sqlite');

    var db = AppDatabase(NativeDatabase(file));
    await db.into(db.categories).insert(CategoriesCompanion.insert(id: 'c1', kind: 'expense', name: 'Comida', clientUpdatedAt: '2026-10-20T10:00:00.000000Z'));
    for (final t in ['loans', 'loan_movements', 'subscriptions', 'credit_cards', 'credit_card_payments']) {
      await db.customStatement('DROP TABLE $t');
    }
    await db.customStatement('PRAGMA user_version = 1');
    await db.close();

    db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect(await db.watchLoans().first, isEmpty); // la tabla existe otra vez
    expect(await db.watchSubscriptions().first, isEmpty);
    expect(await db.watchCreditCards().first, isEmpty);
    expect((await db.select(db.categories).getSingle()).name, 'Comida');
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 2);
  });
}
