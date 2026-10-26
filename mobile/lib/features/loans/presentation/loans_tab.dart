import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/db/queries_fase2.dart';
import '../../../core/router/app_router.dart';
import '../../../core/sync/sync_controller.dart';
import '../../../core/ui/fit_trailing.dart';
import '../../../core/ui/pickers.dart';
import 'loan_labels.dart';

/// Pestaña "Préstamos" de Bancos (spec 5.8): lo que te deben y lo que debes.
class LoansTab extends ConsumerWidget {
  const LoansTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loans = ref.watch(loansProvider);
    final summary = ref.watch(loansSummaryProvider).value;
    final today = ref.watch(todayProvider);
    final theme = Theme.of(context);

    return loans.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('No se pudieron cargar los préstamos: $e')),
      data: (list) {
        if (list.isEmpty) {
          return EmptyState(
            key: const Key('sin-prestamos'),
            icon: Icons.handshake_outlined,
            title: 'Sin préstamos',
            message: 'Registra el dinero que prestaste o que te prestaron para no perderle la pista.',
            actionLabel: 'Agregar préstamo',
            onAction: () => context.push(AppRoutes.loanNew),
          );
        }
        return RefreshIndicator(
          onRefresh: () => ref.read(syncControllerProvider.notifier).syncNow(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            children: [
              if (summary != null)
                Card(
                  color: theme.colorScheme.primaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(children: [
                      Expanded(
                        child: _SummaryCell(label: 'Te deben', value: summary.owedToMe.format(), valueKey: const Key('resumen-te-deben')),
                      ),
                      Expanded(
                        child: _SummaryCell(label: 'Debes', value: summary.iOwe.format(), valueKey: const Key('resumen-debes')),
                      ),
                    ]),
                  ),
                ),
              const SizedBox(height: 8),
              for (final l in list) _LoanTile(loan: l, today: today),
            ],
          ),
        );
      },
    );
  }
}

class _SummaryCell extends StatelessWidget {
  const _SummaryCell({required this.label, required this.value, required this.valueKey});

  final String label;
  final String value;
  final Key valueKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: theme.textTheme.labelLarge),
      FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(value, key: valueKey, style: theme.textTheme.titleLarge)),
    ]);
  }
}

class _LoanTile extends StatelessWidget {
  const _LoanTile({required this.loan, required this.today});

  final LoanView loan;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final due = loanDueInfo(loan, today);
    final color = loan.iOwe ? scheme.error : const Color(0xFF2E7D32);
    return Card(
      child: ListTile(
        key: Key('prestamo-${loan.id}'),
        onTap: () => context.push(AppRoutes.loan(loan.id)),
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.15),
          child: Icon(loan.iOwe ? Icons.north_east : Icons.south_west, color: color),
        ),
        title: Text(loan.personName, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text.rich(
          TextSpan(children: [
            TextSpan(text: '${loanDirectionLabel(loan)} · '),
            TextSpan(text: loan.isPaid ? 'Pagado' : due.text, style: due.overdue ? TextStyle(color: scheme.error) : null),
          ]),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: FitTrailing(
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (loan.pending)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(Icons.cloud_upload_outlined, size: 16, color: scheme.outline, semanticLabel: 'Pendiente de enviar'),
              ),
            Text(
              loan.isPaid ? loan.total.format() : loan.remaining.format(),
              style: theme.textTheme.titleMedium?.copyWith(
                color: loan.isPaid ? scheme.outline : color,
                decoration: loan.isPaid ? TextDecoration.lineThrough : null,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
