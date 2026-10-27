import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import 'data/export_repository.dart';
import 'data/export_service.dart';
import 'data/file_sharer.dart';

/// Hoja para compartir del sistema; las pruebas la sustituyen.
final fileSharerProvider = Provider<FileSharer>((ref) => const SharePlusFileSharer());

/// `null` sin base local (sin sesión).
final exportServiceProvider = Provider<ExportService?>((ref) {
  final db = ref.watch(databaseProvider);
  if (db == null) return null;
  return ExportService(repository: ExportRepository(db), sharer: ref.watch(fileSharerProvider));
});
