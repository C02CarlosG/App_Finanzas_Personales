import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/db/queries_fase3.dart';
import '../../../core/format/dates.dart';
import '../../../core/router/app_router.dart';
import 'budgets_tab.dart';

/// Inicio: los presupuestos del mes que ya están en aviso o excedidos (los demás no estorban).
class BudgetAlerts extends ConsumerWidget {
  const BudgetAlerts({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = ref.watch(todayProvider);
    final list = ref.watch(budgetsProvider(monthRange(today.year, today.month))).value ?? const <BudgetProgress>[];
    final alerts = list.where((b) => b.status != BudgetStatus.ok).take(3).toList();
    if (alerts.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 16),
      Text('Presupuestos', style: theme.textTheme.titleMedium),
      const SizedBox(height: 8),
      for (final b in alerts)
        Card(
          child: ListTile(
            key: Key('alerta-presupuesto-${b.categoryId}'),
            onTap: () => context.go(AppRoutes.budgets),
            leading: Icon(b.status == BudgetStatus.exceeded ? Icons.error_outline : Icons.warning_amber_rounded, color: budgetColor(context, b.status)),
            title: Text(b.categoryName, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${budgetStatusText(b)} · ${b.spent.format()} de ${b.limit.format()}', maxLines: 3, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.chevron_right),
          ),
        ),
    ]);
  }
}
