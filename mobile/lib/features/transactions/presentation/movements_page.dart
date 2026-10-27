import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/db/queries.dart';
import '../../../core/format/dates.dart';
import '../../../core/ui/fit_trailing.dart';
import '../../../core/router/app_router.dart';
import '../../../core/sync/sync_controller.dart';
import '../../cards/presentation/cards_list.dart';
import '../../subscriptions/presentation/subscriptions_list.dart';
import 'transaction_tile.dart';

/// Movimientos (spec 4.3/4.4/5.6/5.7): ingresos y gastos con filtros por categoría y cuenta, búsqueda
/// por descripción y total del mes. Se llega desde Inicio ("Ver todos"). Gastos suma las secciones
/// Suscripciones y Tarjetas (pagos de tarjeta de crédito), como pide el spec 5.7.
class MovementsPage extends StatefulWidget {
  const MovementsPage({super.key, this.initialTab = 1});

  /// 0 = Ingresos, 1 = Gastos.
  final int initialTab;

  @override
  State<MovementsPage> createState() => _MovementsPageState();
}

class _MovementsPageState extends State<MovementsPage> {
  /// 0 = Generales, 1 = Suscripciones, 2 = Tarjetas (solo aplica a la pestaña Gastos).
  final _section = ValueNotifier<int>(0);

  @override
  void dispose() {
    _section.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      initialIndex: widget.initialTab,
      child: Builder(builder: (context) {
        final tabs = DefaultTabController.of(context);
        return Scaffold(
          appBar: AppBar(
            title: const Text('Movimientos'),
            actions: [
              IconButton(
                key: const Key('exportar-movimientos'),
                tooltip: 'Exportar a Excel o PDF',
                icon: const Icon(Icons.ios_share),
                onPressed: () => context.push(AppRoutes.export),
              ),
            ],
            bottom: const TabBar(tabs: [Tab(text: 'Ingresos'), Tab(text: 'Gastos')]),
          ),
          floatingActionButton: FloatingActionButton.extended(
            heroTag: null, // varias pantallas con FAB conviven (pestañas + rutas); sin etiqueta no chocan en la transición
            key: const Key('agregar-movimiento'),
            onPressed: () {
              final route = tabs.index == 0
                  ? AppRoutes.transactionNew('income')
                  : switch (_section.value) {
                      1 => AppRoutes.subscriptionNew,
                      2 => AppRoutes.cardNew,
                      _ => AppRoutes.transactionNew('expense'),
                    };
              context.push(route);
            },
            icon: const Icon(Icons.add),
            label: const Text('Agregar'),
          ),
          body: TabBarView(children: [const _MovementList(type: 'income'), _ExpensesTab(section: _section)]),
        );
      }),
    );
  }
}

/// Pestaña Gastos: gastos generales, suscripciones y pagos de tarjeta de crédito.
class _ExpensesTab extends StatelessWidget {
  const _ExpensesTab({required this.section});

  final ValueNotifier<int> section;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: section,
      builder: (context, current, _) => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Wrap(spacing: 8, runSpacing: 4, children: [
              for (final (i, label, key) in const [
                (0, 'Generales', 'seccion-generales'),
                (1, 'Suscripciones', 'seccion-suscripciones'),
                (2, 'Tarjetas', 'seccion-tarjetas'),
              ])
                ChoiceChip(key: Key(key), label: Text(label), selected: current == i, onSelected: (_) => section.value = i),
            ]),
          ),
        ),
        Expanded(
          child: IndexedStack(index: current, children: const [_MovementList(type: 'expense'), SubscriptionsList(), CardsList()]),
        ),
      ]),
    );
  }
}

class _MovementList extends ConsumerStatefulWidget {
  const _MovementList({required this.type});

  final String type;

  @override
  ConsumerState<_MovementList> createState() => _MovementListState();
}

class _MovementListState extends ConsumerState<_MovementList> with AutomaticKeepAliveClientMixin {
  late int _year = DateTime.now().year;
  late int _month = DateTime.now().month;
  bool _allTime = false;
  String? _categoryId;
  String? _accountId;
  final _search = TextEditingController();

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  TransactionFilter get _filter {
    final range = _allTime ? null : monthRange(_year, _month);
    final q = _search.text.trim();
    return TransactionFilter(
      type: widget.type,
      categoryId: _categoryId,
      accountId: _accountId,
      query: q.isEmpty ? null : q,
      from: range?.from,
      to: range?.to,
    );
  }

  bool get _hasFilters => _categoryId != null || _accountId != null || _search.text.trim().isNotEmpty;

  void _shiftMonth(int delta) => setState(() {
        final next = delta < 0 ? previousMonth(_year, _month) : nextMonth(_year, _month);
        _year = next.year;
        _month = next.month;
      });

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final isIncome = widget.type == 'income';
    final filter = _filter;
    final list = ref.watch(transactionsProvider(filter));
    final totals = ref.watch(totalsProvider(filter)).value;
    final categories = ref.watch(categoriesProvider(widget.type)).value ?? const [];
    final accounts = ref.watch(accountsProvider).value ?? const <AccountView>[];
    final total = totals == null ? null : (isIncome ? totals.income : totals.expense);

    return RefreshIndicator(
      onRefresh: () => ref.read(syncControllerProvider.notifier).syncNow(),
      // Lista perezosa: con "Todo el historial" puede haber miles de movimientos y solo se construyen los visibles.
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.only(top: 8),
            sliver: SliverToBoxAdapter(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // Mes
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: [
              IconButton(
                key: const Key('mes-anterior'),
                tooltip: 'Mes anterior',
                icon: const Icon(Icons.chevron_left),
                onPressed: _allTime ? null : () => _shiftMonth(-1),
              ),
              Expanded(
                child: Text(
                  _allTime ? 'Todo el historial' : monthLabel(_year, _month),
                  key: const Key('etiqueta-mes'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              IconButton(
                key: const Key('mes-siguiente'),
                tooltip: 'Mes siguiente',
                icon: const Icon(Icons.chevron_right),
                onPressed: _allTime ? null : () => _shiftMonth(1),
              ),
              IconButton(
                key: const Key('todo-historial'),
                tooltip: _allTime ? 'Ver por mes' : 'Ver todo el historial',
                icon: Icon(_allTime ? Icons.calendar_month : Icons.all_inclusive),
                onPressed: () => setState(() => _allTime = !_allTime),
              ),
            ]),
          ),
          // Resumen
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Card(
              color: isIncome ? theme.colorScheme.primaryContainer : theme.colorScheme.errorContainer,
              child: ListTile(
                title: Text(_hasFilters ? 'Total (con filtros)' : (_allTime ? 'Total' : 'Total del mes')),
                subtitle: Text(isIncome ? 'Ingresos' : 'Gastos'),
                trailing: FitTrailing(child: Text(total?.format() ?? '', key: const Key('total-movimientos'), style: theme.textTheme.titleLarge)),
              ),
            ),
          ),
          // Búsqueda y filtros
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: TextField(
              key: const Key('buscar-movimientos'),
              controller: _search,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Buscar por descripción o persona',
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(icon: const Icon(Icons.close), onPressed: () => setState(_search.clear)),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(children: [
              Expanded(
                child: DropdownButtonFormField<String?>(
                  key: ValueKey('filtro-categoria-$_categoryId-${categories.length}'),
                  isExpanded: true,
                  initialValue: categories.any((c) => c.id == _categoryId) ? _categoryId : null,
                  decoration: const InputDecoration(labelText: 'Categoría', isDense: true),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('Todas')),
                    for (final c in categories) DropdownMenuItem<String?>(value: c.id, child: Text(c.name, overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) => setState(() => _categoryId = v),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String?>(
                  key: ValueKey('filtro-cuenta-$_accountId-${accounts.length}'),
                  isExpanded: true,
                  initialValue: accounts.any((a) => a.id == _accountId) ? _accountId : null,
                  decoration: const InputDecoration(labelText: 'Cuenta', isDense: true),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('Todas')),
                    for (final a in accounts) DropdownMenuItem<String?>(value: a.id, child: Text(a.name, overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) => setState(() => _accountId = v),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 8),
              ]),
            ),
          ),
          ...list.when(
            loading: () => [const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())))],
            error: (e, _) => [SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(16), child: Text('No se pudieron cargar los movimientos: $e')))],
            data: (items) => items.isEmpty
                ? [
                    SliverToBoxAdapter(
                      child: _Empty(
                        filtered: _hasFilters,
                        isIncome: isIncome,
                        onClear: () => setState(() {
                          _categoryId = null;
                          _accountId = null;
                          _search.clear();
                        }),
                      ),
                    ),
                  ]
                : [
                    SliverPadding(
                      padding: const EdgeInsets.only(bottom: 96),
                      sliver: SliverList.builder(
                        itemCount: items.length,
                        itemBuilder: (context, i) {
                          final t = items[i];
                          return TransactionTile(key: ValueKey(t.id), tx: t, showYear: _allTime, onTap: () => context.push(AppRoutes.transaction(t.id)));
                        },
                      ),
                    ),
                  ],
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.filtered, required this.isIncome, required this.onClear});

  final bool filtered;
  final bool isIncome;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('sin-resultados'),
      padding: const EdgeInsets.all(32),
      child: Column(children: [
        Icon(Icons.receipt_long_outlined, size: 48, color: Theme.of(context).colorScheme.outline),
        const SizedBox(height: 12),
        Text(filtered ? 'Ningún movimiento coincide con los filtros' : (isIncome ? 'Sin ingresos en este periodo' : 'Sin gastos en este periodo'),
            textAlign: TextAlign.center),
        if (filtered) TextButton(key: const Key('limpiar-filtros'), onPressed: onClear, child: const Text('Limpiar filtros')),
      ]),
    );
  }
}
