import 'package:finanzas_personales/core/db/queries.dart';
import 'package:finanzas_personales/core/db/queries_fase2.dart';
import 'package:finanzas_personales/core/demo/demo_seed.dart';
import 'package:flutter_test/flutter_test.dart';

import '../sync/support.dart';

void main() {
  late Harness h;
  setUp(() => h = Harness());
  tearDown(() => h.close());

  test('siembra catálogo, categorías, cuentas y movimientos de ejemplo, sin outbox', () async {
    await seedDemoData(h.db, now: DateTime(2026, 10, 20));
    expect((await h.db.watchBanks().first).length, 16);
    expect((await h.db.watchCategories(kind: 'income').first).map((c) => c.name), contains('Préstamo cobrado'));
    final accounts = await h.db.watchAccounts().first;
    expect(accounts.length, 3);
    expect(accounts.where((a) => a.isCash), hasLength(1));
    expect((await h.db.watchTransactions(const TransactionFilter()).first).length, greaterThan(20));
    expect(await h.outbox(), isEmpty); // en demo no hay nada que sincronizar
    expect((await h.db.watchLoans().first).length, 2);
    expect((await h.db.watchSubscriptions().first).length, 4);
    expect((await h.db.watchCreditCards().first).length, 2);
    expect(accounts.every((a) => !a.pending), isTrue);
  });

  test('es idempotente: sembrar de nuevo no duplica nada', () async {
    await seedDemoData(h.db, now: DateTime(2026, 10, 20));
    final first = (await h.db.watchTransactions(const TransactionFilter()).first).length;
    await seedDemoData(h.db, now: DateTime(2026, 10, 20));
    expect((await h.db.watchTransactions(const TransactionFilter()).first).length, first);
    expect((await h.db.watchBanks().first).length, 16);
  });

  test('ningún movimiento queda en el futuro y hay datos en el mes actual', () async {
    final today = DateTime(2026, 10, 7); // a inicio de mes: no debe sembrar días posteriores
    await seedDemoData(h.db, now: today);
    final list = await h.db.watchTransactions(const TransactionFilter()).first;
    expect(list.every((t) => t.occurredOn.compareTo('2026-10-07') <= 0), isTrue);
    expect(list.any((t) => t.occurredOn.startsWith('2026-10')), isTrue);
    expect(list.any((t) => t.occurredOn.startsWith('2026-08')), isTrue);
  });
}
