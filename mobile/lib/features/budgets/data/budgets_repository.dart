import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/data/validation_exception.dart';
import '../../../core/data/validators.dart';
import '../../../core/db/app_database.dart';
import '../../../core/db/local_store.dart';
import '../../../core/money/money.dart';

/// Presupuestos mensuales por categoría de gastos (spec 4.7). Uno por categoría: guardar de nuevo el de una
/// categoría que ya lo tiene lo edita.
class BudgetsRepository {
  BudgetsRepository(this._store, {String Function()? newId}) : _newId = newId ?? (() => const Uuid().v4());

  final LocalStore _store;
  final String Function() _newId;
  AppDatabase get _db => _store.db;

  /// Umbrales de aviso que ofrece la pantalla; el servidor acepta cualquier entero de 1 a 100.
  static const alertChoices = [50, 70, 80, 90, 100];

  Future<String> save({required String categoryId, required Money limit, int alertPercent = 80}) async {
    final category = await (_db.select(_db.categories)..where((c) => c.id.equals(categoryId) & c.deletedAt.isNull())).getSingleOrNull();
    if (category == null) throw const ValidationException('Elige una categoría');
    if (category.kind != 'expense') throw const ValidationException('Un presupuesto es de una categoría de gastos');
    if (alertPercent < 1 || alertPercent > 100) throw const ValidationException('El aviso debe estar entre 1 % y 100 %');
    final money = positiveMoney(limit);
    // Normalmente hay uno solo. Si una sincronización dejó dos vivos para la categoría, se conserva el que ya está en
    // el servidor (o el primero) y se quitan los demás: así se corrige solo al guardar.
    final live = await (_db.select(_db.budgets)..where((b) => b.categoryId.equals(categoryId) & b.deletedAt.isNull())).get();
    final keeper = live.where((b) => b.updatedAt != null).firstOrNull ?? live.firstOrNull;
    final id = keeper?.id ?? _newId();
    await _db.transaction(() async {
      for (final extra in live.where((b) => b.id != keeper?.id)) {
        await _store.delete('budgets', extra.id);
      }
      await _store.saveBudget(id: id, categoryId: categoryId, monthlyLimit: money, alertPercent: alertPercent);
    });
    return id;
  }

  Future<void> delete(String id) async {
    final row = await (_db.select(_db.budgets)..where((b) => b.id.equals(id) & b.deletedAt.isNull())).getSingleOrNull();
    if (row == null) throw const ValidationException('El presupuesto ya no existe');
    await _store.delete('budgets', id);
  }
}
