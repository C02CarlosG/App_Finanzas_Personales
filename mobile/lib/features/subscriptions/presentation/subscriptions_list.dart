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
import 'subscription_labels.dart';

/// Suscripciones (spec 4.4): qué servicios recurrentes hay contratados y cuándo se renuevan.
class SubscriptionsList extends ConsumerWidget {
  const SubscriptionsList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subs = ref.watch(subscriptionsProvider);
    final today = ref.watch(todayProvider);
    final theme = Theme.of(context);

    return subs.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('No se pudieron cargar las suscripciones: $e')),
      data: (list) {
        if (list.isEmpty) {
          return EmptyState(
            key: const Key('sin-suscripciones'),
            icon: Icons.subscriptions_outlined,
            title: 'Sin suscripciones',
            message: 'Anota tus servicios recurrentes (Netflix, Spotify, Amazon…) para no olvidar qué tienes contratado.',
            actionLabel: 'Agregar suscripción',
            onAction: () => context.push(AppRoutes.subscriptionNew),
          );
        }
        final active = list.where((s) => s.active).toList()
          ..sort((a, b) => nextRenewal(a.renewalDate, a.period, today).compareTo(nextRenewal(b.renewalDate, b.period, today)));
        final paused = list.where((s) => !s.active).toList();
        final monthly = Money(active.fold<int>(0, (sum, s) => sum + s.monthlyEquivalent.cents));

        return RefreshIndicator(
          onRefresh: () => ref.read(syncControllerProvider.notifier).syncNow(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            children: [
              Card(
                color: theme.colorScheme.errorContainer,
                child: ListTile(
                  title: const Text('Gasto mensual aproximado'),
                  subtitle: Text('${active.length} ${active.length == 1 ? 'suscripción activa' : 'suscripciones activas'}'),
                  trailing: FitTrailing(child: Text(monthly.format(), key: const Key('total-suscripciones'), style: theme.textTheme.titleLarge)),
                ),
              ),
              const SizedBox(height: 8),
              for (final s in [...active, ...paused]) _SubscriptionTile(sub: s, today: today),
            ],
          ),
        );
      },
    );
  }
}

class _SubscriptionTile extends StatelessWidget {
  const _SubscriptionTile({required this.sub, required this.today});

  final SubscriptionView sub;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = !sub.active;
    final detail = [
      periodLabel(sub.period),
      muted ? 'Pausada' : 'Renueva ${renewalText(sub.renewalDate, sub.period, today)}',
      if (sub.accountName != null) sub.accountName!,
    ].join(' · ');
    return Card(
      child: ListTile(
        key: Key('suscripcion-${sub.id}'),
        onTap: () => context.push(AppRoutes.subscription(sub.id)),
        leading: CircleAvatar(
          backgroundColor: scheme.secondaryContainer,
          child: Text(sub.name.isEmpty ? '?' : sub.name.characters.first.toUpperCase()),
        ),
        title: Text(sub.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: muted ? TextStyle(color: scheme.outline) : null),
        subtitle: Text(detail, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: FitTrailing(
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (sub.pending)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(Icons.cloud_upload_outlined, size: 16, color: scheme.outline, semanticLabel: 'Pendiente de enviar'),
              ),
            Text(sub.amount.format(), style: theme.textTheme.titleMedium?.copyWith(color: muted ? scheme.outline : null)),
          ]),
        ),
      ),
    );
  }
}
