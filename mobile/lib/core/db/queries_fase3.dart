import 'package:drift/drift.dart';

import '../format/dates.dart';
import '../money/money.dart';
import 'app_database.dart';

// Consultas de la Fase 3: reportes y presupuestos. Todo se calcula de las transacciones locales (nunca se
// guarda un total), así que dos dispositivos siempre muestran lo mismo.

/// Gasto de un mes en una categoría. Los gastos de categorías que ya no existen se juntan en una sola fila
/// "Sin categoría" (`categoryId` y `color` null).
class CategorySpend {
  const CategorySpend({required this.categoryId, required this.name, required this.total, this.color});

  final String? categoryId;
  final String name;
  final String? color;
  final Money total;
}

/// Ingresos y gastos de un mes (para la tendencia).
class MonthPoint {
  const MonthPoint({required this.year, required this.month, required this.income, required this.expense});

  final int year;
  final int month;
  final Money income;
  final Money expense;
  Money get net => income - expense;
}

enum BudgetStatus {
  /// Por debajo del umbral de aviso.
  ok,

  /// Alcanzó el umbral de aviso (`alertPercent` del límite) sin pasar el límite.
  warning,

  /// Gastó más que el límite.
  exceeded,
}

/// Avance de un presupuesto en un mes: lo gastado en su categoría contra su límite.
class BudgetProgress {
  const BudgetProgress({
    required this.id,
    required this.categoryId,
    required this.categoryName,
    required this.limit,
    required this.spent,
    required this.alertPercent,
    required this.pending,
    this.categoryColor,
  });

  final String id;
  final String categoryId;
  final String categoryName;
  final String? categoryColor;
  final Money limit;
  final Money spent;
  final int alertPercent;
  final bool pending; // tiene cambios sin enviar

  /// Aritmética de enteros (sin decimales): `gastado × 100 ≥ límite × umbral`.
  BudgetStatus get status {
    if (spent.cents > limit.cents) return BudgetStatus.exceeded;
    if (spent.cents * 100 >= limit.cents * alertPercent) return BudgetStatus.warning;
    return BudgetStatus.ok;
  }

  /// Porcentaje del límite gastado, redondeado (puede pasar de 100).
  int get percent => limit.cents == 0 ? 0 : (spent.cents * 100 / limit.cents).round();

  /// Lo que falta para el límite; negativo si ya se excedió.
  Money get remaining => limit - spent;
}

/// El aviso al guardar un gasto: solo si el presupuesto cambió a un estado peor ([before] → [after]).
BudgetProgress? budgetAlertFor(BudgetProgress? before, BudgetProgress? after) {
  if (after == null || after.status == BudgetStatus.ok) return null;
  return before?.status == after.status ? null : after;
}

extension Fase3Queries on AppDatabase {
  /// Gastos del rango `[from, to)` por categoría, del mayor al menor.
  Stream<List<CategorySpend>> watchExpensesByCategory(String from, String to) => customSelect(
        '''
        SELECT c.id AS category_id, c.name, c.color, SUM(t.amount_cents) AS total
        FROM transactions t
        LEFT JOIN categories c ON c.id = t.category_id AND c.deleted_at IS NULL
        WHERE t.type = 'expense' AND t.deleted_at IS NULL AND t.occurred_on >= ? AND t.occurred_on < ?
        GROUP BY c.id
        ORDER BY total DESC, lower(COALESCE(c.name, ''))''',
        variables: [Variable.withString(from), Variable.withString(to)],
        readsFrom: {transactions, categories},
      ).watch().map((rows) => [
            for (final r in rows)
              CategorySpend(
                categoryId: r.readNullable<String>('category_id'),
                name: r.readNullable<String>('name') ?? 'Sin categoría',
                color: r.readNullable<String>('color'),
                total: Money(r.read<int>('total')),
              ),
          ]);

  /// Ingresos y gastos de los [months] meses que terminan en `year-month`, del más viejo al más nuevo
  /// (los meses sin movimientos salen en cero).
  Stream<List<MonthPoint>> watchMonthlyTrend(int year, int month, {int months = 3}) {
    final first = addMonths(DateTime(year, month, 1), -(months - 1));
    final range = (from: isoDate(first), to: monthRange(year, month).to);
    return customSelect(
      '''
      SELECT substr(t.occurred_on, 1, 7) AS ym, t.type, SUM(t.amount_cents) AS total
      FROM transactions t
      WHERE t.deleted_at IS NULL AND t.occurred_on >= ? AND t.occurred_on < ?
      GROUP BY ym, t.type''',
      variables: [Variable.withString(range.from), Variable.withString(range.to)],
      readsFrom: {transactions},
    ).watch().map((rows) {
      final income = <String, int>{};
      final expense = <String, int>{};
      for (final r in rows) {
        (r.read<String>('type') == 'income' ? income : expense)[r.read<String>('ym')] = r.read<int>('total');
      }
      return [
        for (var i = 0; i < months; i++)
          () {
            final d = addMonths(first, i);
            final key = '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';
            return MonthPoint(year: d.year, month: d.month, income: Money(income[key] ?? 0), expense: Money(expense[key] ?? 0));
          }(),
      ];
    });
  }

  static const _budgetSelect = '''
    SELECT b.id, b.category_id, b.monthly_limit_cents, b.alert_percent, c.name AS category_name, c.color AS category_color,
           COALESCE((SELECT SUM(t.amount_cents) FROM transactions t
                     WHERE t.category_id = b.category_id AND t.type = 'expense' AND t.deleted_at IS NULL
                       AND t.occurred_on >= ?1 AND t.occurred_on < ?2), 0) AS spent_cents,
           EXISTS(SELECT 1 FROM sync_outbox o WHERE o.entity = 'budgets' AND o.record_id = b.id) AS pending
    FROM budgets b
    JOIN categories c ON c.id = b.category_id AND c.deleted_at IS NULL
    WHERE b.deleted_at IS NULL''';

  BudgetProgress _toBudgetProgress(QueryRow r) => BudgetProgress(
        id: r.read<String>('id'),
        categoryId: r.read<String>('category_id'),
        categoryName: r.read<String>('category_name'),
        categoryColor: r.readNullable<String>('category_color'),
        limit: Money(r.read<int>('monthly_limit_cents')),
        spent: Money(r.read<int>('spent_cents')),
        alertPercent: r.read<int>('alert_percent'),
        pending: r.read<int>('pending') == 1,
      );

  /// Presupuestos con su avance en el rango `[from, to)`, de mayor a menor porcentaje gastado.
  /// Un presupuesto cuya categoría se eliminó en otro dispositivo no aparece.
  Stream<List<BudgetProgress>> watchBudgets(String from, String to) => customSelect(
        _budgetSelect,
        variables: [Variable.withString(from), Variable.withString(to)],
        readsFrom: {budgets, categories, transactions, syncOutbox},
      ).watch().map((rows) {
        final list = [for (final r in rows) _toBudgetProgress(r)];
        list.sort((a, b) {
          final byPercent = b.percent.compareTo(a.percent);
          return byPercent != 0 ? byPercent : a.categoryName.toLowerCase().compareTo(b.categoryName.toLowerCase());
        });
        return list;
      });

  /// Texto de la pantalla de problemas para un cambio de presupuesto.
  Future<String> describeBudgetEntry(OutboxEntry e) async {
    final b = await (select(budgets)..where((x) => x.id.equals(e.recordId))).getSingleOrNull();
    if (b == null) return 'Presupuesto (eliminado)';
    final c = await (select(categories)..where((x) => x.id.equals(b.categoryId))).getSingleOrNull();
    return 'Presupuesto: ${c?.name ?? '(categoría eliminada)'}';
  }

  /// Avance del presupuesto de una categoría en el mes de [occurredOn] (`null` si no tiene presupuesto).
  /// Lectura única: la usan los formularios para avisar si un gasto cruza el umbral.
  Future<BudgetProgress?> budgetProgressFor(String categoryId, String occurredOn) async {
    final d = parseIsoDate(occurredOn);
    final range = monthRange(d.year, d.month);
    final rows = await customSelect(
      '$_budgetSelect AND b.category_id = ?3',
      variables: [Variable.withString(range.from), Variable.withString(range.to), Variable.withString(categoryId)],
      readsFrom: {budgets, categories, transactions, syncOutbox},
    ).get();
    return rows.isEmpty ? null : _toBudgetProgress(rows.first);
  }
}
