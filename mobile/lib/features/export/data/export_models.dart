import '../../../core/db/queries.dart';
import '../../../core/money/money.dart';

/// Qué exportar: periodo `[from, to)` (fechas `YYYY-MM-DD`, como los filtros de los listados) y filtros opcionales.
class ExportRequest {
  const ExportRequest({required this.from, required this.to, this.type, this.accountId, this.categoryId});

  final String from;
  final String to;
  final String? type; // income | expense | null = ambos
  final String? accountId;
  final String? categoryId;
}

/// Total de una categoría en el periodo (ingresos y gastos van por separado aunque se llamen igual).
class CategoryTotal {
  const CategoryTotal({required this.kind, required this.name, required this.total, required this.count});

  final String kind; // income | expense
  final String name;
  final Money total;
  final int count;
}

/// Todo lo que necesitan los generadores de Excel y PDF; sin dependencias de interfaz ni de archivos.
class ExportData {
  const ExportData({
    required this.userName,
    required this.userEmail,
    required this.generatedAt,
    required this.from,
    required this.lastDay,
    required this.rows,
    required this.totals,
    required this.byCategory,
    this.typeLabel,
    this.accountLabel,
    this.categoryLabel,
  });

  final String userName;
  final String userEmail;
  final DateTime generatedAt;
  final String from;

  /// Último día incluido del periodo (`to` menos un día), para mostrarlo al usuario.
  final String lastDay;

  /// Movimientos del periodo, del más antiguo al más reciente.
  final List<TransactionView> rows;
  final Totals totals;
  final List<CategoryTotal> byCategory;

  /// Descripción de cada filtro aplicado; `null` = sin filtrar por eso.
  final String? typeLabel;
  final String? accountLabel;
  final String? categoryLabel;

  int get count => rows.length;

  /// Texto de los filtros activos para el encabezado («Todos los movimientos» si no hay ninguno).
  String get filtersDescription {
    final parts = [
      ?typeLabel,
      if (accountLabel != null) 'Cuenta: $accountLabel',
      if (categoryLabel != null) 'Categoría: $categoryLabel',
    ];
    return parts.isEmpty ? 'Todos los movimientos' : parts.join(' · ');
  }

  /// Nombre de archivo sin extensión, p. ej. `finanzas_2026-10-01_a_2026-10-31`.
  String get baseFileName => 'finanzas_${from}_a_$lastDay';
}
