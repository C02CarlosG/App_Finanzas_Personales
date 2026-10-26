import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/db/queries_fase2.dart';
import '../../../core/format/dates.dart';
import '../../../core/money/money.dart';
import '../../../core/router/app_router.dart';
import '../../../core/sync/sync_controller.dart';
import '../../../core/ui/fit_trailing.dart';
import '../../../core/ui/pickers.dart';
import '../../accounts/presentation/bank_avatar.dart';
import '../../subscriptions/presentation/subscription_labels.dart';

/// "Vence 10 nov · en 3 días" / "Vencida desde hace 2 días" / "Sin fecha de vencimiento".
String cardDueText(CreditCardView c, DateTime today) {
  final due = c.dueDate;
  if (due == null) return 'Sin fecha de vencimiento';
  final days = daysBetween(today, parseIsoDate(due));
  if (days < 0 && c.pendingBalance.cents > 0) return 'Vencida ${relativeDays(days)}';
  return 'Vence ${formatDateShort(due)} · ${relativeDays(days)}';
}

/// Pagos de tarjeta de crédito (spec 4.4): saldo pendiente, vencimiento y registro de pagos.
class CardsList extends ConsumerWidget {
  const CardsList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cards = ref.watch(creditCardsProvider);
    final today = ref.watch(todayProvider);
    final theme = Theme.of(context);

    return cards.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('No se pudieron cargar las tarjetas: $e')),
      data: (list) {
        if (list.isEmpty) {
          return EmptyState(
            key: const Key('sin-tarjetas'),
            icon: Icons.credit_card,
            title: 'Sin tarjetas de crédito',
            message: 'Registra tus tarjetas con su saldo pendiente y su fecha de vencimiento, y anota tus pagos.',
            actionLabel: 'Agregar tarjeta',
            onAction: () => context.push(AppRoutes.cardNew),
          );
        }
        final total = Money(list.fold<int>(0, (sum, c) => sum + c.pendingBalance.cents));
        return RefreshIndicator(
          onRefresh: () => ref.read(syncControllerProvider.notifier).syncNow(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            children: [
              Card(
                color: theme.colorScheme.errorContainer,
                child: ListTile(
                  title: const Text('Saldo pendiente total'),
                  trailing: FitTrailing(child: Text(total.format(), key: const Key('total-tarjetas'), style: theme.textTheme.titleLarge)),
                ),
              ),
              const SizedBox(height: 8),
              for (final c in list)
                Card(
                  child: ListTile(
                    key: Key('tarjeta-${c.id}'),
                    onTap: () => context.push(AppRoutes.card(c.id)),
                    leading: c.bankName == null
                        ? const CircleAvatar(child: Icon(Icons.credit_card))
                        : BankAvatar(name: c.bankName!, logoKey: c.logoKey, size: 40),
                    title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(cardDueText(c, today), maxLines: 2, overflow: TextOverflow.ellipsis),
                    trailing: FitTrailing(
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        if (c.pending)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: Icon(Icons.cloud_upload_outlined, size: 16, color: theme.colorScheme.outline, semanticLabel: 'Pendiente de enviar'),
                          ),
                        Text(c.pendingBalance.format(), style: theme.textTheme.titleMedium),
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
