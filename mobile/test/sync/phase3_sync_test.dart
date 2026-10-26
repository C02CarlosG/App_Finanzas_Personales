import 'dart:io';

import 'package:drift/native.dart';
import 'package:finanzas_personales/core/db/app_database.dart';
import 'package:finanzas_personales/core/db/queries.dart';
import 'package:finanzas_personales/core/db/queries_fase3.dart';
import 'package:finanzas_personales/core/money/money.dart';
import 'package:finanzas_personales/features/budgets/data/budgets_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/catalog.dart';
import 'support.dart';

Map<String, dynamic> echo(Map<String, dynamic> change) => {
      'id': change['id'],
      ...?(change['data'] as Map<String, dynamic>?),
      'updated_at': '2026-10-20T12:00:00.000000Z',
      'client_updated_at': change['client_updated_at'],
      'deleted_at': null,
    };

void main() {
  late Harness h;
  late BudgetsRepository budgets;

  setUp(() async {
    h = Harness();
    await seedCatalog(h.db);
    budgets = BudgetsRepository(h.store);
    h.api.onPush = (changes) async => pushResponse([for (final c in changes) result(c, 'applied', record: echo(c))]);
  });
  tearDown(() => h.close());

  Future<List<BudgetProgress>> all() => h.db.watchBudgets('2000-01-01', '2100-01-01').first;

  test('el push de un presupuesto lleva el límite como string, el umbral entero y va después de su categoría', () async {
    final custom = 'cat-mascotas';
    await h.store.saveCategory(id: custom, kind: 'expense', name: 'Mascotas');
    await budgets.save(categoryId: custom, limit: Money.parse('1500.5'), alertPercent: 90);
    await h.engine.run();
    final sent = h.api.pushes.expand((b) => b).toList();
    expect([for (final c in sent) c['table']], ['categories', 'budgets']);
    expect(sent.last['data'], {'category_id': custom, 'monthly_limit': '1500.50', 'alert_percent': 90});
    expect(await h.outbox(), isEmpty);
  });

  test('el pull aplica presupuestos, incluido un tombstone', () async {
    const t0 = '2026-10-20T10:00:00.000000Z';
    Map<String, dynamic> row(String id, String category, String limit, {String? deletedAt}) => {
          'id': id,
          'category_id': category,
          'monthly_limit': limit,
          'alert_percent': 70,
          'updated_at': '2026-10-20T11:00:00.000000Z',
          'client_updated_at': t0,
          'deleted_at': deletedAt,
        };
    await h.seedFromServer(pullPage(budgets: [row('b1', Catalog.comida, '800.00'), row('b2', Catalog.vivienda, '5000.00', deletedAt: t0)]));
    final list = await all();
    expect([for (final b in list) (b.categoryName, b.limit.cents, b.alertPercent)], [('Alimentación', 80000, 70)]);
  });

  test('duplicate_budget: el presupuesto local se descarta y sale de la outbox (el vigente llega por pull)', () async {
    final id = await budgets.save(categoryId: Catalog.comida, limit: Money.parse('500'));
    h.api.onPush = (changes) async => pushResponse([
          for (final c in changes)
            c['table'] == 'budgets'
                ? result(c, 'rejected', code: 'duplicate_budget', extra: {'conflicting_id': 'b-server', 'message': 'x'})
                : result(c, 'applied', record: echo(c)),
        ]);
    h.api.pullQueue.add(pullPage(budgets: [
      {
        'id': 'b-server',
        'category_id': Catalog.comida,
        'monthly_limit': '900.00',
        'alert_percent': 80,
        'updated_at': '2026-10-20T11:00:00.000000Z',
        'client_updated_at': '2026-10-20T10:00:00.000000Z',
        'deleted_at': null,
      }
    ]));
    await h.engine.run();
    expect(await h.outbox(), isEmpty);
    final rows = await h.db.select(h.db.budgets).get();
    expect([for (final r in rows) r.id], ['b-server']); // el local desapareció y quedó el del servidor
    expect(rows.single.id == id, isFalse);
    expect((await all()).single.limit.cents, 90000);
  });

  test('duplicate_budget con el presupuesto editado durante el envío no lo descarta todavía', () async {
    final id = await budgets.save(categoryId: Catalog.comida, limit: Money.parse('500'));
    h.api.onPush = (changes) async {
      h.advance(const Duration(seconds: 1));
      await budgets.save(categoryId: Catalog.comida, limit: Money.parse('600')); // el usuario edita con el lote en vuelo
      return pushResponse([
        for (final c in changes)
          c['table'] == 'budgets' ? result(c, 'rejected', code: 'duplicate_budget', extra: {'conflicting_id': 'x'}) : result(c, 'applied', record: echo(c)),
      ]);
    };
    await h.engine.run();
    expect((await h.db.select(h.db.budgets).get()).map((r) => r.id), [id]);
    expect((await h.outbox()).where((e) => e.entity == 'budgets'), hasLength(1)); // la edición sigue pendiente
  });

  test('describeOutboxEntry no falla con presupuestos (cae al nombre de la entidad)', () async {
    final id = await budgets.save(categoryId: Catalog.comida, limit: Money.parse('500'));
    final entry = (await h.outbox()).firstWhere((e) => e.recordId == id);
    expect(await h.db.describeOutboxEntry(entry), 'Presupuesto: Alimentación');
  });

  test('una base de la versión 2 sube a la 3 con la tabla de presupuestos y conserva sus datos', () async {
    final dir = await Directory.systemTemp.createTemp('migracion_v2');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/finanzas.sqlite');

    var db = AppDatabase(NativeDatabase(file));
    await db.into(db.categories).insert(CategoriesCompanion.insert(id: 'c1', kind: 'expense', name: 'Comida', clientUpdatedAt: '2026-10-20T10:00:00.000000Z'));
    await db.customStatement('DROP TABLE budgets');
    await db.customStatement('PRAGMA user_version = 2');
    await db.close();

    db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect(await db.watchBudgets('2000-01-01', '2100-01-01').first, isEmpty); // la tabla existe otra vez
    expect((await db.select(db.categories).getSingle()).name, 'Comida');
    expect((await db.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), 3);
  });
}
