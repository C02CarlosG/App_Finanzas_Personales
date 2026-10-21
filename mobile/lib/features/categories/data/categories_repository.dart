import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/data/validation_exception.dart';
import '../../../core/db/app_database.dart';
import '../../../core/db/local_store.dart';

/// Colores disponibles para categorías (hex `#RRGGBB`, como valida el servidor).
const categoryColors = [
  '#1B7F5C', '#2E7D32', '#689F38', '#F9A825', '#EF6C00', '#D84315',
  '#C62828', '#AD1457', '#6A1B9A', '#4527A0', '#1565C0', '#00838F',
];

class CategoriesRepository {
  CategoriesRepository(this._store, {String Function()? newId}) : _newId = newId ?? (() => const Uuid().v4());

  final LocalStore _store;
  final String Function() _newId;
  AppDatabase get _db => _store.db;

  Future<String> create({required String kind, required String name, String? color}) async {
    _validKind(kind);
    final clean = await _validName(name, kind: kind);
    final id = _newId();
    await _store.saveCategory(id: id, kind: kind, name: clean, color: _validColor(color));
    return id;
  }

  /// Las categorías del sistema (p. ej. "Préstamo cobrado") solo cambian de color.
  Future<void> update(String id, {required String name, String? color}) async {
    final row = await _find(id);
    final clean = row.isSystem
        ? (name.trim() == row.name ? row.name : throw const ValidationException('Las categorías del sistema no se pueden renombrar'))
        : await _validName(name, kind: row.kind, exceptId: id);
    await _store.saveCategory(id: id, kind: row.kind, name: clean, icon: row.icon, color: _validColor(color));
  }

  Future<void> delete(String id) async {
    final row = await _find(id);
    if (row.isSystem) throw const ValidationException('Las categorías del sistema no se pueden eliminar');
    final used = await (_db.select(_db.transactions)
          ..where((t) => t.categoryId.equals(id) & t.deletedAt.isNull())
          ..limit(1))
        .get();
    if (used.isNotEmpty) {
      throw const ValidationException('Esta categoría tiene movimientos. Cámbialos a otra categoría primero.');
    }
    await _store.delete('categories', id);
  }

  Future<CategoryRow> _find(String id) async {
    final row = await (_db.select(_db.categories)..where((c) => c.id.equals(id) & c.deletedAt.isNull())).getSingleOrNull();
    if (row == null) throw const ValidationException('La categoría ya no existe');
    return row;
  }

  void _validKind(String kind) {
    if (kind != 'income' && kind != 'expense') throw const ValidationException('Tipo de categoría inválido');
  }

  /// Nombre único por tipo sin distinguir mayúsculas (igual que el índice del servidor).
  Future<String> _validName(String raw, {required String kind, String? exceptId}) async {
    final name = raw.trim();
    if (name.isEmpty) throw const ValidationException('Escribe un nombre');
    if (name.length > 60) throw const ValidationException('El nombre es demasiado largo (máx. 60)');
    final same = await (_db.select(_db.categories)..where((c) => c.kind.equals(kind) & c.deletedAt.isNull())).get();
    final taken = same.any((c) => c.id != exceptId && c.name.toLowerCase() == name.toLowerCase());
    if (taken) throw const ValidationException('Ya existe una categoría con ese nombre');
    return name;
  }

  String? _validColor(String? color) {
    if (color == null) return null;
    if (!RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(color)) throw const ValidationException('Color inválido');
    return color;
  }
}
