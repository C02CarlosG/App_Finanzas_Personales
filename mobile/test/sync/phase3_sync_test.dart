import 'dart:io';

import 'package:drift/drift.dart' show Value;
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

  test('duplicate_budget con la baja del presupuesto viejo pendiente en otro lote: el nuevo se conserva y se reintenta', () async {
    // Este dispositivo quitó el presupuesto X (la baja sigue en la outbox) y creó Y para la misma categoría.
    await h.db.into(h.db.budgets).insert(BudgetsCompanion.insert(
        id: 'x', categoryId: Catalog.comida, monthlyLimitCents: 10000, updatedAt: const Value('2026-10-20T10:00:00.000000Z'), clientUpdatedAt: '2026-10-20T10:00:00.000000Z'));
    await h.store.delete('budgets', 'x'); // tombstone local + baja en la outbox
    final y = await budgets.save(categoryId: Catalog.comida, limit: Money.parse('700'));
    h.api.onPush = (changes) async => pushResponse([
          for (final c in changes)
            c['table'] == 'budgets' && c['id'] == y
                ? result(c, 'rejected', code: 'duplicate_budget', extra: {'conflicting_id': 'x'})
                : result(c, 'applied', record: c['deleted'] == true ? null : echo(c)),
        ]);
    expect((await h.outbox()).where((e) => e.entity == 'budgets').map((e) => e.recordId).toSet(), {'x', y});
    // El servidor responde a Y (duplicate_budget) antes de que llegue la baja de X; el motor procesa las respuestas en ese orden.
    await h.engine.run();
    final rows = await h.db.select(h.db.budgets).get();
    expect(rows.any((r) => r.id == y && r.deletedAt == null), isTrue, reason: 'el nuevo no se descartó');
  });

  test('fusionar una categoría duplicada lleva su presupuesto a la que sobrevive (o lo quita si esa ya tiene uno)', () async {
    // Categoría creada aquí sin conexión con el nombre de una que ya existe en el servidor, con presupuesto.
    await h.store.saveCategory(id: 'cat-nueva', kind: 'expense', name: 'Comida (nueva)');
    final mine = await budgets.save(categoryId: 'cat-nueva', limit: Money.parse('400'));
    h.api.onPush = (changes) async => pushResponse([
          for (final c in changes)
            c['table'] == 'categories' && c['id'] == 'cat-nueva'
                ? result(c, 'rejected', code: 'duplicate_name', extra: {'conflicting_id': Catalog.comida, 'message': 'x'})
                : result(c, 'invalid', code: 'invalid_reference', extra: {'message': 'x'}),
        ]);
    await h.engine.run();
    final moved = await (h.db.select(h.db.budgets)..where((b) => b.id.equals(mine))).getSingle();
    expect(moved.categoryId, Catalog.comida);
    expect((await h.outbox()).where((e) => e.recordId == mine), hasLength(1)); // sigue pendiente, ya sobre la categoría vigente

    // Si la categoría que sobrevive ya tiene presupuesto, el local sobra.
    await h.store.saveCategory(id: 'cat-otra', kind: 'expense', name: 'Otra (nueva)');
    final sobra = await budgets.save(categoryId: 'cat-otra', limit: Money.parse('50'));
    await h.db.into(h.db.budgets).insert(BudgetsCompanion.insert(
        id: 'del-servidor', categoryId: Catalog.vivienda, monthlyLimitCents: 90000, updatedAt: const Value('2026-10-20T10:00:00.000000Z'), clientUpdatedAt: '2026-10-20T10:00:00.000000Z'));
    h.api.onPush = (changes) async => pushResponse([
          for (final c in changes)
            c['table'] == 'categories' && c['id'] == 'cat-otra'
                ? result(c, 'rejected', code: 'duplicate_name', extra: {'conflicting_id': Catalog.vivienda, 'message': 'x'})
                : result(c, 'invalid', code: 'invalid_reference', extra: {'message': 'x'}),
        ]);
    await h.engine.run();
    expect((await h.db.select(h.db.budgets).get()).any((b) => b.id == sobra), isFalse);
    expect((await h.outbox()).any((e) => e.recordId == sobra), isFalse);
  });

  test('si otro dispositivo elimina la categoría, el presupuesto local sin enviar se quita y deja de reintentarse', () async {
    await h.store.saveCategory(id: 'cat-x', kind: 'expense', name: 'Temporal');
    final id = await budgets.save(categoryId: 'cat-x', limit: Money.parse('100'));
    h.api.onPush = (changes) async => pushResponse([
          for (final c in changes)
            c['table'] == 'budgets' ? result(c, 'invalid', code: 'invalid_reference', extra: {'message': 'x'}) : result(c, 'applied', record: echo(c)),
        ]);
    h.api.pullQueue.add(pullPage(categories: [
      {
        'id': 'cat-x',
        'kind': 'expense',
        'name': 'Temporal',
        'icon': null,
        'color': null,
        'is_system': false,
        'updated_at': '2026-10-21T00:00:00.000000Z',
        'client_updated_at': '2026-10-21T00:00:00.000000Z',
        'deleted_at': '2026-10-21T00:00:00.000000Z',
      }
    ]));
    await h.engine.run();
    expect((await h.db.select(h.db.budgets).get()).any((b) => b.id == id), isFalse);
    expect(await h.outbox(), isEmpty);
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
