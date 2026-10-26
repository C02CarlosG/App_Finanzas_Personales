import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/db/queries.dart';
import '../../../core/router/app_router.dart';
import '../../../core/sync/sync_controller.dart';
import '../../../core/ui/fit_trailing.dart';
import '../../loans/presentation/loans_tab.dart';
import 'bank_avatar.dart';

/// Bancos (spec 5.5): cuentas bancarias y de efectivo con su saldo actual; y, en la segunda pestaña,
/// los préstamos (decisión del 2026-10-26: viven junto a los saldos).
class AccountsPage extends StatefulWidget {
  const AccountsPage({super.key});

  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<AccountsPage> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bancos'),
        bottom: TabBar(controller: _tabs, tabs: const [Tab(text: 'Cuentas'), Tab(text: 'Préstamos')]),
      ),
      // El botón cambia con la pestaña: agregar cuenta o agregar préstamo.
      floatingActionButton: ListenableBuilder(
        listenable: _tabs,
        builder: (context, _) => _tabs.index == 0
            ? FloatingActionButton.extended(
                heroTag: null, // varias pantallas con FAB conviven (pestañas + rutas); sin etiqueta no chocan en la transición
                key: const Key('agregar-cuenta'),
                onPressed: () => context.push(AppRoutes.accountNew),
                icon: const Icon(Icons.add),
                label: const Text('Agregar'),
              )
            : FloatingActionButton.extended(
                heroTag: null,
                key: const Key('agregar-prestamo'),
                onPressed: () => context.push(AppRoutes.loanNew),
                icon: const Icon(Icons.add),
                label: const Text('Agregar'),
              ),
      ),
      body: TabBarView(controller: _tabs, children: const [_AccountsTab(), LoansTab()]),
    );
  }
}

class _AccountsTab extends ConsumerWidget {
  const _AccountsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider);
    final total = ref.watch(totalBalanceProvider).value;
    final theme = Theme.of(context);

    return accounts.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('No se pudieron cargar las cuentas: $e')),
      data: (list) {
        if (list.isEmpty) return const _EmptyState();
        return RefreshIndicator(
          onRefresh: () => ref.read(syncControllerProvider.notifier).syncNow(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            children: [
              Card(
                color: theme.colorScheme.primaryContainer,
                child: ListTile(
                  title: const Text('Saldo total'),
                  trailing: FitTrailing(
                    child: Text(
                      total?.format() ?? '',
                      key: const Key('bancos-saldo-total'),
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              for (final a in list) _AccountTile(account: a),
            ],
          ),
        );
      },
    );
  }
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({required this.account});

  final AccountView account;

  static String kindLabel(AccountView a) {
    if (a.isCash) return 'Efectivo en mano';
    final card = switch (a.cardType) { 'debito' => 'Débito', 'credito' => 'Crédito', _ => null };
    return card == null ? (a.bankName ?? 'Banco') : '${a.bankName ?? 'Banco'} · $card';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        key: Key('cuenta-${account.id}'),
        leading: account.isCash ? const CashAvatar() : BankAvatar(name: account.bankName ?? account.name, logoKey: account.logoKey),
        title: Text(account.name),
        subtitle: Text(kindLabel(account)),
        trailing: FitTrailing(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (account.pending)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(Icons.cloud_upload_outlined, size: 16, color: theme.colorScheme.outline, semanticLabel: 'Pendiente de enviar'),
                ),
              Text(
                account.balance.format(),
                style: theme.textTheme.titleMedium?.copyWith(color: account.balance.isNegative ? theme.colorScheme.error : null),
              ),
            ],
          ),
        ),
        onTap: () => context.push(AppRoutes.account(account.id)),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Con texto grande o pantalla baja el contenido puede no caber: se centra si cabe y se desplaza si no.
    return LayoutBuilder(
      key: const Key('sin-cuentas'),
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.account_balance, size: 64, color: theme.colorScheme.primary),
                  const SizedBox(height: 16),
                  Text('Aún no tienes cuentas', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  const Text('Agrega una cuenta bancaria o efectivo para empezar a registrar tus movimientos.', textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () => context.push(AppRoutes.accountNew),
                    icon: const Icon(Icons.add),
                    label: const Text('Agregar cuenta'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
