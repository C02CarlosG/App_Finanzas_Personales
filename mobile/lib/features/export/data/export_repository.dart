import '../../../core/db/app_database.dart';
import '../../../core/db/queries.dart';
import '../../../core/format/dates.dart';
import '../../../core/money/money.dart';
import '../../../core/data/validation_exception.dart';
import 'export_models.dart';

/// Arma los datos de una exportación a partir de la base local (funciona sin conexión).
class ExportRepository {
  ExportRepository(this._db);

  final AppDatabase _db;

  Future<ExportData> load(ExportRequest request, {required String userName, required String userEmail, required DateTime now}) async {
    if (request.from.compareTo(request.to) >= 0) {
      throw const ValidationException('La fecha final debe ser igual o posterior a la inicial');
    }
    final rows = await _db.transactionsFor(TransactionFilter(
      type: request.type,
      accountId: request.accountId,
      categoryId: request.categoryId,
      from: request.from,
      to: request.to,
    ));
    // Del más antiguo al más reciente; a igual fecha, el orden de captura (la consulta viene del más nuevo al más viejo,
    // así que se invierte). `List.sort` no es estable: el índice original desempata para que dos exportaciones iguales
    // salgan idénticas.
    final captured = rows.reversed.toList();
    final order = [for (var i = 0; i < captured.length; i++) i]
      ..sort((a, b) {
        final byDate = captured[a].occurredOn.compareTo(captured[b].occurredOn);
        return byDate != 0 ? byDate : a.compareTo(b);
      });
    final ordered = [for (final i in order) captured[i]];

    var income = 0;
    var expense = 0;
    // Los movimientos de una categoría borrada van aparte de cualquier categoría que se llame «Sin categoría».
    final byCategory = <(String, String?), ({int cents, int count})>{};
    for (final r in ordered) {
      if (r.isIncome) {
        income += r.amount.cents;
      } else {
        expense += r.amount.cents;
      }
      final key = (r.type, r.categoryName);
      final prev = byCategory[key];
      byCategory[key] = (cents: (prev?.cents ?? 0) + r.amount.cents, count: (prev?.count ?? 0) + 1);
    }
    final categories = [
      for (final e in byCategory.entries)
        CategoryTotal(kind: e.key.$1, name: e.key.$2 ?? 'Sin categoría', total: Money(e.value.cents), count: e.value.count),
    ]..sort((a, b) {
        if (a.kind != b.kind) return a.kind == 'income' ? -1 : 1;
        final byTotal = b.total.cents.compareTo(a.total.cents);
        return byTotal != 0 ? byTotal : a.name.compareTo(b.name);
      });

    return ExportData(
      userName: userName,
      userEmail: userEmail,
      generatedAt: now,
      from: request.from,
      lastDay: isoDate(parseIsoDate(request.to).subtract(const Duration(days: 1))),
      rows: ordered,
      totals: Totals(income: Money(income), expense: Money(expense)),
      byCategory: categories,
      typeLabel: switch (request.type) { 'income' => 'Solo ingresos', 'expense' => 'Solo gastos', _ => null },
      accountLabel: request.accountId == null ? null : await _accountLabel(request.accountId!),
      categoryLabel: request.categoryId == null ? null : await _categoryLabel(request.categoryId!),
    );
  }

  Future<String?> _accountLabel(String id) async {
    final row = await (_db.select(_db.accounts)..where((a) => a.id.equals(id))).getSingleOrNull();
    return row?.name;
  }

  Future<String?> _categoryLabel(String id) async {
    final row = await (_db.select(_db.categories)..where((c) => c.id.equals(id))).getSingleOrNull();
    return row?.name;
  }
}
