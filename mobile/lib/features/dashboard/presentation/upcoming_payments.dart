import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/db/queries_fase2.dart';
import '../../../core/format/dates.dart';
import '../../../core/money/money.dart';
import '../../../core/router/app_router.dart';
import '../../../core/ui/fit_trailing.dart';
import '../../subscriptions/presentation/subscription_labels.dart';

/// Algo que vence o se renueva pronto (spec 5.2): una suscripción, el pago de una tarjeta o un préstamo con plazo.
class UpcomingItem {
  const UpcomingItem({required this.kind, required this.id, required this.title, required this.amount, required this.date, required this.days});

  final String kind; // subscription | card | loan
  final String id;
  final String title;
  final Money amount;
  final DateTime date;

  /// Días civiles desde hoy; negativo = ya venció.
  final int days;

  bool get overdue => days < 0;
}

/// Los próximos vencimientos dentro de [horizonDays] días (más los ya vencidos), del más urgente al más lejano.
/// Suscripciones pausadas, tarjetas sin saldo y préstamos pagados no cuentan.
List<UpcomingItem> buildUpcoming({
  required List<SubscriptionView> subscriptions,
  required List<CreditCardView> cards,
  required List<LoanView> loans,
  required DateTime today,
  int horizonDays = 30,
  int limit = 5,
}) {
  final items = <UpcomingItem>[];
  for (final s in subscriptions.where((s) => s.active)) {
    final next = nextRenewal(s.renewalDate, s.period, today);
    final days = daysBetween(today, next);
    if (days <= horizonDays) items.add(UpcomingItem(kind: 'subscription', id: s.id, title: s.name, amount: s.amount, date: next, days: days));
  }
  for (final c in cards.where((c) => c.dueDate != null && c.pendingBalance.cents > 0)) {
    final due = parseIsoDate(c.dueDate!);
    final days = daysBetween(today, due);
    if (days <= horizonDays) items.add(UpcomingItem(kind: 'card', id: c.id, title: 'Pago de ${c.name}', amount: c.pendingBalance, date: due, days: days));
  }
  for (final l in loans.where((l) => !l.isPaid && l.dueDate != null && l.remaining.cents > 0)) {
    final due = parseIsoDate(l.dueDate!);
    final days = daysBetween(today, due);
    if (days <= horizonDays) {
      items.add(UpcomingItem(kind: 'loan', id: l.id, title: l.iOwe ? 'Pagar a ${l.personName}' : 'Cobrar a ${l.personName}', amount: l.remaining, date: due, days: days));
    }
  }
  items.sort((a, b) {
    final byDays = a.days.compareTo(b.days);
    return byDays != 0 ? byDays : a.title.toLowerCase().compareTo(b.title.toLowerCase());
  });
  return items.take(limit).toList();
}

final upcomingProvider = Provider<AsyncValue<List<UpcomingItem>>>((ref) {
  final subs = ref.watch(subscriptionsProvider);
  final cards = ref.watch(creditCardsProvider);
  final loans = ref.watch(loansProvider);
  final today = ref.watch(todayProvider);
  if (subs.isLoading || cards.isLoading || loans.isLoading) return const AsyncLoading();
  return AsyncData(buildUpcoming(
    subscriptions: subs.value ?? const [],
    cards: cards.value ?? const [],
    loans: loans.value ?? const [],
    today: today,
  ));
});

/// Sección de Inicio "Suscripciones y pagos próximos".
class UpcomingPayments extends ConsumerWidget {
  const UpcomingPayments({super.key});

  String _route(UpcomingItem i) => switch (i.kind) {
        'subscription' => AppRoutes.subscription(i.id),
        'card' => AppRoutes.card(i.id),
        _ => AppRoutes.loan(i.id),
      };

  IconData _icon(UpcomingItem i) => switch (i.kind) {
        'subscription' => Icons.subscriptions_outlined,
        'card' => Icons.credit_card,
        _ => Icons.handshake_outlined,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final items = ref.watch(upcomingProvider).value ?? const <UpcomingItem>[];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Suscripciones y pagos próximos', style: theme.textTheme.titleMedium),
      const SizedBox(height: 8),
      if (items.isEmpty)
        Text('Nada pendiente', key: const Key('sin-proximos'), style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline))
      else
        for (final i in items)
          Card(
            child: ListTile(
              key: Key('proximo-${i.kind}-${i.id}'),
              onTap: () => context.push(_route(i)),
              leading: Icon(_icon(i), color: i.overdue ? theme.colorScheme.error : null),
              title: Text(i.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                i.overdue ? 'Vencido ${relativeDays(i.days)}' : '${formatDateShort(isoDate(i.date))} · ${relativeDays(i.days)}',
                style: i.overdue ? TextStyle(color: theme.colorScheme.error) : null,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: FitTrailing(child: Text(i.amount.format(), style: theme.textTheme.titleSmall)),
            ),
          ),
    ]);
  }
}
