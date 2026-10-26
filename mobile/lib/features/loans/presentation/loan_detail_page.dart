import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/data/validation_exception.dart';
import '../../../core/db/queries_fase2.dart';
import '../../../core/format/dates.dart';
import '../../../core/router/app_router.dart';
import '../../../core/ui/fit_trailing.dart';
import 'loan_actions.dart';
import 'loan_labels.dart';

/// Detalle de un préstamo (spec 5.8): saldo, historial de abonos y las acciones abonar / aumentar / marcar pagado.
class LoanDetailPage extends ConsumerWidget {
  const LoanDetailPage({super.key, required this.loanId});

  final String loanId;

  Future<void> _delete(BuildContext context, WidgetRef ref, LoanView loan) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Eliminar este préstamo?'),
        content: const Text(
          'Se eliminará el préstamo y su historial. Los ingresos y gastos que ya registraste en tus cuentas se conservan.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(key: const Key('confirmar-eliminar'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Eliminar')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(loansRepositoryProvider).delete(loan.id);
      if (context.mounted) context.pop();
    } on ValidationException catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _undo(BuildContext context, WidgetRef ref, LoanView loan, LoanMovementView m) async {
    final what = m.isPayment ? 'el ${loanPaymentLabel(loan)} de ${m.amount.format()} y su ${loan.iOwe ? 'gasto' : 'ingreso'} en tu cuenta' : 'el aumento de ${m.amount.format()}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Deshacer este movimiento?'),
        content: Text('Se eliminará $what.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(key: const Key('confirmar-deshacer'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Deshacer')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(loansRepositoryProvider).deleteMovement(m.id);
    } on ValidationException catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loanAsync = ref.watch(loanProvider(loanId));
    final loan = loanAsync.value;
    final movements = ref.watch(loanMovementsProvider(loanId)).value ?? const [];
    final today = ref.watch(todayProvider);
    final theme = Theme.of(context);

    if (loan == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Préstamo')),
        body: Center(child: loanAsync.isLoading ? const CircularProgressIndicator() : const Text('El préstamo ya no existe')),
      );
    }
    final due = loanDueInfo(loan, today);
    final accent = loan.iOwe ? theme.colorScheme.error : const Color(0xFF2E7D32);

    return Scaffold(
      appBar: AppBar(
        title: Text(loan.personName, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(key: const Key('editar-prestamo'), tooltip: 'Editar', icon: const Icon(Icons.edit_outlined), onPressed: () => context.push(AppRoutes.loanEdit(loan.id))),
          IconButton(key: const Key('eliminar-prestamo'), tooltip: 'Eliminar', icon: const Icon(Icons.delete_outline), onPressed: () => _delete(context, ref, loan)),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              color: theme.colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(loan.isPaid ? 'Pagado' : (loan.iOwe ? 'Le debes' : 'Te debe'), key: const Key('estado-prestamo'), style: theme.textTheme.labelLarge),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      loan.isPaid ? loan.total.format() : loan.remaining.format(),
                      key: const Key('saldo-prestamo'),
                      style: theme.textTheme.displaySmall?.copyWith(color: loan.isPaid ? theme.colorScheme.outline : accent),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text('Original ${loan.principal.format()}'
                      '${loan.increases.cents > 0 ? ' · Aumentos ${loan.increases.format()}' : ''}'
                      ' · ${loan.iOwe ? 'Pagado' : 'Cobrado'} ${loan.payments.format()}'),
                  const SizedBox(height: 4),
                  Text(due.text, key: const Key('plazo-prestamo'), style: due.overdue ? TextStyle(color: theme.colorScheme.error) : null),
                  if (loan.notes != null) ...[const SizedBox(height: 4), Text(loan.notes!)],
                ]),
              ),
            ),
            const SizedBox(height: 12),
            if (!loan.isPaid)
              FilledButton.icon(
                key: const Key('abonar'),
                onPressed: () => showLoanPaymentSheet(context, loan),
                icon: Icon(loan.iOwe ? Icons.north_east : Icons.south_west),
                label: Text(loan.iOwe ? 'Registrar pago' : 'Registrar cobro'),
              ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                key: const Key('aumentar'),
                onPressed: () => showLoanIncreaseSheet(context, loan),
                icon: const Icon(Icons.add),
                label: const Text('Aumentar monto'),
              ),
              if (!loan.isPaid)
                OutlinedButton.icon(
                  key: const Key('marcar-pagado'),
                  onPressed: () => showMarkPaidSheet(context, loan),
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Marcar como pagado'),
                ),
            ]),
            const SizedBox(height: 16),
            Text('Historial', style: theme.textTheme.titleMedium),
            if (movements.isEmpty)
              const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Text('Aún no hay abonos ni aumentos.', key: Key('sin-movimientos-prestamo')))
            else
              for (final m in movements) _MovementTile(loan: loan, movement: m, onUndo: () => _undo(context, ref, loan, m)),
          ],
        ),
      ),
    );
  }
}

class _MovementTile extends StatelessWidget {
  const _MovementTile({required this.loan, required this.movement, required this.onUndo});

  final LoanView loan;
  final LoanMovementView movement;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = movement;
    final label = m.isPayment ? (loan.iOwe ? 'Pago' : 'Cobro') : 'Aumento';
    final account = m.accountName == null ? '' : ' · ${m.accountName}';
    return ListTile(
      key: Key('movimiento-prestamo-${m.id}'),
      contentPadding: EdgeInsets.zero,
      leading: Icon(m.isPayment ? Icons.payments_outlined : Icons.add_circle_outline),
      title: Text(label),
      subtitle: Text('${formatDate(m.occurredOn)}$account', maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: FitTrailing(
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (m.pending)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Icon(Icons.cloud_upload_outlined, size: 16, color: theme.colorScheme.outline, semanticLabel: 'Pendiente de enviar'),
            ),
          Text(m.amount.format(), style: theme.textTheme.titleSmall),
          IconButton(key: Key('deshacer-${m.id}'), tooltip: 'Deshacer', icon: const Icon(Icons.undo), onPressed: onUndo),
        ]),
      ),
    );
  }
}
