import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/db/queries_fase3.dart';
import '../../../core/sync/sync_controller.dart';
import '../../../core/ui/pickers.dart';
import '../../categories/presentation/category_editor.dart';
import 'budget_editor.dart';

/// Texto del estado de un presupuesto: lo que queda, el aviso o cuánto se excedió.
String budgetStatusText(BudgetProgress b) => switch (b.status) {
      BudgetStatus.ok => 'Quedan ${b.remaining.format()}',
      BudgetStatus.warning => 'Cerca del límite: llevas el ${b.percent} %',
      BudgetStatus.exceeded => 'Excedido por ${(-b.remaining).format()}',
    };

/// Aviso al guardar un gasto que cruza el umbral o el límite del presupuesto de su categoría.
String budgetAlertMessage(BudgetProgress b) => b.status == BudgetStatus.exceeded
    ? 'Excediste el presupuesto de ${b.categoryName} por ${(-b.remaining).format()} (${b.spent.format()} de ${b.limit.format()})'
    : 'Presupuesto de ${b.categoryName}: llevas el ${b.percent} % (${b.spent.format()} de ${b.limit.format()})';

/// Color de la barra según el estado.
Color budgetColor(BuildContext context, BudgetStatus s) {
  final scheme = Theme.of(context).colorScheme;
  return switch (s) {
    BudgetStatus.ok => Theme.of(context).brightness == Brightness.dark ? const Color(0xFF81C784) : const Color(0xFF2E7D32),
    BudgetStatus.warning => const Color(0xFFEF6C00),
    BudgetStatus.exceeded => scheme.error,
  };
}

/// Pestaña "Presupuestos" de Reportes: límite mensual por categoría de gastos y su avance en el mes elegido.
class BudgetsTab extends ConsumerWidget {
  const BudgetsTab({super.key, required this.range});

  final DateRange range;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final budgets = ref.watch(budgetsProvider(range));
    final theme = Theme.of(context);
    return budgets.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('No se pudieron cargar los presupuestos: $e')),
      data: (list) {
        if (list.isEmpty) {
          return EmptyState(
            key: const Key('sin-presupuestos'),
            icon: Icons.speed,
            title: 'Sin presupuestos',
            message: 'Pon un límite mensual a una categoría de gastos y te avisamos cuando te acerques o lo excedas.',
            actionLabel: 'Agregar presupuesto',
            onAction: () => showBudgetEditor(context, range: range),
          );
        }
        return RefreshIndicator(
          onRefresh: () => ref.read(syncControllerProvider.notifier).syncNow(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            children: [
              for (final b in list)
                Card(
                  child: InkWell(
                    key: Key('presupuesto-${b.categoryId}'),
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => showBudgetEditor(context, range: range, budget: b),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          CircleAvatar(radius: 8, backgroundColor: categoryDisplayColor(b.categoryColor, b.categoryName)),
                          const SizedBox(width: 8),
                          Expanded(child: Text(b.categoryName, style: theme.textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis)),
                          if (b.pending) Icon(Icons.cloud_upload_outlined, size: 16, color: theme.colorScheme.outline, semanticLabel: 'Pendiente de enviar'),
                        ]),
                        const SizedBox(height: 8),
                        Semantics(
                          label: 'Avance del presupuesto: ${b.percent} % del límite',
                          child: ExcludeSemantics(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                key: Key('barra-${b.categoryId}'),
                                minHeight: 10,
                                value: b.limit.cents == 0 ? 0 : (b.spent.cents / b.limit.cents).clamp(0.0, 1.0),
                                color: budgetColor(context, b.status),
                                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text('${b.spent.format()} de ${b.limit.format()}', key: Key('monto-${b.categoryId}')),
                        Text(
                          budgetStatusText(b),
                          key: Key('estado-${b.categoryId}'),
                          style: TextStyle(color: b.status == BudgetStatus.ok ? null : budgetColor(context, b.status), fontWeight: b.status == BudgetStatus.ok ? null : FontWeight.w600),
                        ),
                      ]),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
