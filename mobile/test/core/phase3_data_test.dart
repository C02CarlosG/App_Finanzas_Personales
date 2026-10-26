import 'package:finanzas_personales/core/data/validation_exception.dart';
import 'package:finanzas_personales/core/db/queries_fase3.dart';
import 'package:finanzas_personales/core/money/money.dart';
import 'package:finanzas_personales/features/budgets/data/budgets_repository.dart';
import 'package:finanzas_personales/features/categories/data/categories_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/catalog.dart';
import '../sync/support.dart';

void main() {
  late Harness h;
  late BudgetsRepository budgets;

  setUp(() async {
    h = Harness();
    await seedCatalog(h.db);
    budgets = BudgetsRepository(h.store);
    await h.store.saveAccount(id: 'cash', type: 'efectivo', name: 'Efectivo', initialBalance: Money.parse('10000'));
  });
  tearDown(() => h.close());

  Future<void> spend(String id, String amount, String date, {String category = Catalog.comida, String type = 'expense'}) =>
      h.store.saveTransaction(id: id, type: type, amount: Money.parse(amount), accountId: 'cash', categoryId: category, occurredOn: date);

  Future<List<BudgetProgress>> octoberBudgets() => h.db.watchBudgets('2026-10-01', '2026-11-01').first;

  group('presupuestos', () {
    test('estado según el umbral: por debajo, en aviso (gastado ≥ umbral) y excedido (gastado > límite)', () async {
      await budgets.save(categoryId: Catalog.comida, limit: Money.parse('1000'), alertPercent: 80);
      Future<BudgetStatus> statusAfter(String id, String amount) async {
        await spend(id, amount, '2026-10-10');
        return (await octoberBudgets()).single.status;
      }

      expect(await statusAfter('t1', '799.99'), BudgetStatus.ok);
      await h.store.delete('transactions', 't1');
      expect(await statusAfter('t2', '800'), BudgetStatus.warning);
      await h.store.delete('transactions', 't2');
      expect(await statusAfter('t3', '1000'), BudgetStatus.warning); // en el límite todavía no es "excedido"
      await h.store.delete('transactions', 't3');
      expect(await statusAfter('t4', '1000.01'), BudgetStatus.exceeded);
    });

    test('con umbral de 100 % avisa justo en el límite; con 50 % avisa a la mitad', () async {
      await budgets.save(categoryId: Catalog.comida, limit: Money.parse('200'), alertPercent: 100);
      await spend('t1', '199.99', '2026-10-10');
      expect((await octoberBudgets()).single.status, BudgetStatus.ok);
      await spend('t2', '0.01', '2026-10-11');
      expect((await octoberBudgets()).single.status, BudgetStatus.warning);
      await budgets.save(categoryId: Catalog.comida, limit: Money.parse('400'), alertPercent: 50);
      expect((await octoberBudgets()).single.status, BudgetStatus.warning); // 200 de 400 = 50 %
    });

    test('solo cuentan los gastos de la categoría dentro del mes; no los eliminados, de otras categorías ni de otros meses', () async {
      await budgets.save(categoryId: Catalog.comida, limit: Money.parse('1000'));
      await spend('oct-1', '100', '2026-10-01');
      await spend('oct-31', '50', '2026-10-31');
      await spend('sep-30', '999', '2026-09-30');
      await spend('nov-1', '999', '2026-11-01');
      await spend('otra', '999', '2026-10-15', category: Catalog.vivienda);
      await spend('borrado', '999', '2026-10-15');
      await h.store.delete('transactions', 'borrado');
      final b = (await octoberBudgets()).single;
      expect([b.spent.cents, b.limit.cents, b.percent, b.remaining.cents], [15000, 100000, 15, 85000]);
    });

    test('guardar de nuevo el presupuesto de una categoría lo edita (mismo id) y no crea otro', () async {
      final id = await budgets.save(categoryId: Catalog.comida, limit: Money.parse('1000'));
      final again = await budgets.save(categoryId: Catalog.comida, limit: Money.parse('2500.50'), alertPercent: 90);
      expect(again, id);
      final b = (await octoberBudgets()).single;
      expect([b.limit.cents, b.alertPercent], [250050, 90]);
    });

    test('validaciones: categoría de gastos existente, límite > 0, umbral de 1 a 100', () async {
      Future<void> bad(Future<void> f) => expectLater(f, throwsA(isA<ValidationException>()));
      await bad(budgets.save(categoryId: 'no-existe', limit: Money.parse('10')));
      await bad(budgets.save(categoryId: Catalog.salario, limit: Money.parse('10'))); // de ingresos
      await bad(budgets.save(categoryId: Catalog.comida, limit: Money.zero));
      await bad(budgets.save(categoryId: Catalog.comida, limit: Money.parse('-5')));
      await bad(budgets.save(categoryId: Catalog.comida, limit: Money.parse('10'), alertPercent: 0));
      await bad(budgets.save(categoryId: Catalog.comida, limit: Money.parse('10'), alertPercent: 101));
      await bad(budgets.delete('no-existe'));
      expect(await octoberBudgets(), isEmpty);
    });

    test('se ordenan del más gastado al menos; uno cuya categoría se eliminó en otro dispositivo no aparece', () async {
      await budgets.save(categoryId: Catalog.comida, limit: Money.parse('1000'));
      await budgets.save(categoryId: Catalog.vivienda, limit: Money.parse('1000'));
      await spend('c', '100', '2026-10-05');
      await spend('v', '600', '2026-10-05', category: Catalog.vivienda);
      expect([for (final b in await octoberBudgets()) b.categoryName], ['Vivienda', 'Alimentación']);
      await h.db.customStatement("UPDATE categories SET deleted_at = '2026-10-20T00:00:00.000000Z' WHERE id = '${Catalog.vivienda}'");
      h.db.markTablesUpdated({h.db.categories}); // el SQL a mano no avisa a los flujos de drift
      await Future<void>.delayed(Duration.zero);
      expect([for (final b in await octoberBudgets()) b.categoryName], ['Alimentación']);
    });

    test('eliminar la categoría se lleva su presupuesto (primero el hijo, para el servidor)', () async {
      final custom = await CategoriesRepository(h.store).create(kind: 'expense', name: 'Mascotas');
      final id = await budgets.save(categoryId: custom, limit: Money.parse('300'));
      await CategoriesRepository(h.store).delete(custom);
      expect(await octoberBudgets(), isEmpty);
      final queued = {for (final e in await h.outbox()) e.recordId};
      expect(queued.contains(id) || (await h.db.select(h.db.budgets).get()).every((b) => b.id != id), isTrue);
      expect((await h.db.select(h.db.budgets).get()).where((b) => b.deletedAt == null), isEmpty);
    });

    test('la edición y la baja quedan en la outbox para subirse', () async {
      final id = await budgets.save(categoryId: Catalog.comida, limit: Money.parse('1000'));
      expect((await h.outbox()).where((e) => e.entity == 'budgets' && e.recordId == id), hasLength(1));
      await budgets.delete(id);
      expect(await octoberBudgets(), isEmpty);
    });
  });

  group('aviso al cruzar el umbral', () {
    BudgetProgress progress(String spent, {String limit = '1000'}) => BudgetProgress(
        id: 'b', categoryId: 'c', categoryName: 'Comida', limit: Money.parse(limit), spent: Money.parse(spent), alertPercent: 80, pending: false);

    test('avisa solo cuando el estado empeora, no en cada gasto', () {
      expect(budgetAlertFor(null, progress('900'))?.status, BudgetStatus.warning); // no había estado previo: se avisa
      expect(budgetAlertFor(null, progress('100')), isNull);
      expect(budgetAlertFor(progress('100'), progress('200')), isNull); // sigue en orden
      expect(budgetAlertFor(progress('700'), progress('850'))?.status, BudgetStatus.warning);
      expect(budgetAlertFor(progress('850'), progress('900')), isNull); // ya estaba en aviso
      expect(budgetAlertFor(progress('850'), progress('1100'))?.status, BudgetStatus.exceeded);
      expect(budgetAlertFor(progress('1100'), progress('1200')), isNull); // ya estaba excedido
      expect(budgetAlertFor(progress('1100'), progress('100')), isNull); // mejora
      expect(budgetAlertFor(progress('100'), null), isNull);
    });

    test('budgetProgressFor mide el mes de la fecha del gasto', () async {
      await budgets.save(categoryId: Catalog.comida, limit: Money.parse('500'));
      await spend('oct', '300', '2026-10-20');
      await spend('sep', '100', '2026-09-20');
      expect((await h.db.budgetProgressFor(Catalog.comida, '2026-10-02'))!.spent.cents, 30000);
      expect((await h.db.budgetProgressFor(Catalog.comida, '2026-09-30'))!.spent.cents, 10000);
      expect(await h.db.budgetProgressFor(Catalog.vivienda, '2026-10-02'), isNull);
    });
  });

  group('reportes', () {
    test('gastos por categoría: del mayor al menor, solo gastos del rango; las categorías eliminadas se juntan en "Sin categoría"', () async {
      await spend('a', '100', '2026-10-02');
      await spend('b', '50.50', '2026-10-03');
      await spend('c', '300', '2026-10-04', category: Catalog.vivienda);
      await spend('ing', '9999', '2026-10-04', category: Catalog.salario, type: 'income');
      await spend('sep', '777', '2026-09-30');
      await spend('nov', '777', '2026-11-01');
      var list = await h.db.watchExpensesByCategory('2026-10-01', '2026-11-01').first;
      expect([for (final c in list) (c.name, c.total.cents)], [('Vivienda', 30000), ('Alimentación', 15050)]);

      await h.store.saveCategory(id: 'extra-1', kind: 'expense', name: 'Extra 1');
      await h.store.saveCategory(id: 'extra-2', kind: 'expense', name: 'Extra 2');
      await spend('x1', '10', '2026-10-05', category: 'extra-1');
      await spend('x2', '20', '2026-10-05', category: 'extra-2');
      await h.db.customStatement("UPDATE categories SET deleted_at = '2026-10-20T00:00:00.000000Z' WHERE id IN ('extra-1', 'extra-2')");
      list = await h.db.watchExpensesByCategory('2026-10-01', '2026-11-01').first;
      final orphan = list.last;
      expect([orphan.name, orphan.categoryId, orphan.total.cents], ['Sin categoría', null, 3000]); // una sola fila con las dos
      expect(list, hasLength(3));
    });

    test('tendencia de 3 meses: del más viejo al más nuevo, con ceros en meses sin movimientos y cruzando el año', () async {
      await spend('nov', '100', '2026-11-15');
      await spend('nov-i', '1000', '2026-11-01', category: Catalog.salario, type: 'income');
      await spend('ene', '40', '2027-01-03');
      await spend('ene-i', '500', '2027-01-04', category: Catalog.salario, type: 'income');
      await spend('oct', '999', '2026-10-31'); // fuera de la ventana nov–ene
      await spend('feb', '999', '2027-02-01');
      final trend = await h.db.watchMonthlyTrend(2027, 1).first;
      expect([for (final p in trend) '${p.year}-${p.month}'], ['2026-11', '2026-12', '2027-1']);
      expect([for (final p in trend) (p.income.cents, p.expense.cents)], [(100000, 10000), (0, 0), (50000, 4000)]);
      expect(trend.last.net.cents, 46000);
    });

    test('la tendencia ignora lo eliminado', () async {
      await spend('a', '100', '2026-10-10');
      await spend('b', '50', '2026-10-11');
      await h.store.delete('transactions', 'b');
      final trend = await h.db.watchMonthlyTrend(2026, 10).first;
      expect(trend.last.expense.cents, 10000);
    });
  });
}
