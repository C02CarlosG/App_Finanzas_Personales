import 'package:drift/drift.dart';

import '../db/app_database.dart';
import 'validation_exception.dart';

/// Categorías de sistema que la app usa para los movimientos que genera sola. El servidor las siembra
/// y no se pueden renombrar ni borrar (docs/sync.md §2), así que se buscan por nombre.
abstract final class SystemCategory {
  static const loanCollected = (kind: 'income', name: 'Préstamo cobrado');
  static const loanPayment = (kind: 'expense', name: 'Pago de préstamo');
  static const cardPayment = (kind: 'expense', name: 'Pago de tarjeta');

  /// Id de la categoría; si todavía no llegó del servidor, pide sincronizar en lugar de crear otra.
  static Future<String> idOf(AppDatabase db, ({String kind, String name}) category) async {
    final row = await (db.select(db.categories)
          ..where((c) => c.kind.equals(category.kind) & c.name.equals(category.name) & c.isSystem.equals(true) & c.deletedAt.isNull())
          ..limit(1))
        .getSingleOrNull();
    if (row == null) {
      throw ValidationException('Falta la categoría "${category.name}". Conéctate a internet para sincronizar e inténtalo de nuevo.');
    }
    return row.id;
  }
}
