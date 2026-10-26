import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/db/queries.dart';
import '../../../core/money/money.dart';
import '../../../core/router/app_router.dart';
import '../../../core/sync/sync_controller.dart';
import '../../budgets/presentation/budget_alerts.dart';
import '../../transactions/presentation/transaction_tile.dart';
import 'upcoming_payments.dart';

const _recentFilter = TransactionFilter(limit: 10);

/// Inicio (spec 5.2): saldo total, botones de ingreso/gasto y últimos movimientos.
class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final total = ref.watch(totalBalanceProvider).value ?? Money.zero;
    final accounts = ref.watch(accountsProvider);
    final recent = ref.watch(transactionsProvider(_recentFilter));

    return Scaffold(
      appBar: AppBar(title: const Text('Inicio')),
      body: RefreshIndicator(
        onRefresh: () => ref.read(syncControllerProvider.notifier).syncNow(),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              color: theme.colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Saldo total', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    // El saldo grande se reduce en vez de partirse en dos líneas con texto del sistema muy grande.
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(total.format(),
                          key: const Key('saldo-total'),
                          style: theme.textTheme.displaySmall?.copyWith(color: total.isNegative ? theme.colorScheme.error : null)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('agregar-ingreso'),
                    onPressed: () => context.push(AppRoutes.transactionNew('income')),
                    icon: const Icon(Icons.add),
                    label: const Text('Agregar ingreso'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonalIcon(
                    key: const Key('agregar-gasto'),
                    onPressed: () => context.push(AppRoutes.transactionNew('expense')),
                    icon: const Icon(Icons.remove),
                    label: const Text('Agregar gasto'),
                  ),
                ),
              ],
            ),
            if (accounts.hasValue && accounts.value!.isEmpty) ...[
              const SizedBox(height: 12),
              Card(
                key: const Key('invitacion-cuenta'),
                child: ListTile(
                  leading: const Icon(Icons.account_balance),
                  title: const Text('Agrega tu primera cuenta'),
                  subtitle: const Text('Un banco o efectivo, para registrar tus movimientos.'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push(AppRoutes.accountNew),
                ),
              ),
            ],
            const BudgetAlerts(),
            const SizedBox(height: 24),
            Row(children: [
              Expanded(child: Text('Últimas transacciones', style: theme.textTheme.titleMedium)),
              TextButton(key: const Key('ver-todos'), onPressed: () => context.push(AppRoutes.movements), child: const Text('Ver todos')),
            ]),
            recent.when(
              loading: () => const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
              error: (e, _) => Text('No se pudieron cargar los movimientos: $e'),
              data: (list) => list.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text('Aún no hay movimientos',
                          key: const Key('sin-movimientos'), style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline)),
                    )
                  : Column(children: [
                      for (final t in list) TransactionTile(tx: t, onTap: () => context.push(AppRoutes.transaction(t.id))),
                    ]),
            ),
            const SizedBox(height: 16),
            const UpcomingPayments(),
          ],
        ),
      ),
    );
  }
}
