import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/db/queries.dart';
import '../../../core/db/queries_fase3.dart';
import '../../../core/format/dates.dart';
import '../../../core/router/app_router.dart';
import '../../../core/sync/sync_controller.dart';
import '../../../core/ui/fit_trailing.dart';
import '../../../core/ui/month_navigator.dart';
import '../../budgets/presentation/budget_editor.dart';
import '../../budgets/presentation/budgets_tab.dart';
import '../../categories/presentation/category_editor.dart';
import 'charts.dart';

/// Reportes (spec 4.6/5.9) y presupuestos (spec 4.7): ingresos contra gastos del mes, gastos por categoría y
/// tendencia de 3 meses; en la segunda pestaña, los límites mensuales por categoría y su avance.
class ReportsPage extends ConsumerStatefulWidget {
  const ReportsPage({super.key, this.initialTab = 0, this.request = 0});

  /// 0 = Resumen, 1 = Presupuestos.
  final int initialTab;

  /// Cambia cada vez que se pide una pestaña (enlace `?t=`): tocar de nuevo el mismo aviso desde Inicio
  /// vuelve a llevar a Presupuestos aunque el usuario haya cambiado de pestaña a mano.
  final int request;

  @override
  ConsumerState<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends ConsumerState<ReportsPage> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this, initialIndex: widget.initialTab);
  late int _year;
  late int _month;

  @override
  void initState() {
    super.initState();
    final today = ref.read(todayProvider);
    _year = today.year;
    _month = today.month;
  }

  @override
  void didUpdateWidget(ReportsPage old) {
    super.didUpdateWidget(old);
    // Un enlace desde Inicio ("ver presupuestos") reutiliza esta pantalla con otra pestaña inicial.
    if (old.initialTab != widget.initialTab || old.request != widget.request) _tabs.animateTo(widget.initialTab);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _setMonth(int y, int m) => setState(() {
        _year = y;
        _month = m;
      });

  @override
  Widget build(BuildContext context) {
    final range = monthRange(_year, _month);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reportes'),
        actions: [
          IconButton(
            key: const Key('exportar-reportes'),
            tooltip: 'Exportar a Excel o PDF',
            icon: const Icon(Icons.ios_share),
            onPressed: () => context.push(AppRoutes.export),
          ),
        ],
        bottom: TabBar(controller: _tabs, tabs: const [Tab(text: 'Resumen'), Tab(text: 'Presupuestos')]),
      ),
      floatingActionButton: ListenableBuilder(
        listenable: _tabs,
        builder: (context, _) => _tabs.index == 1
            ? FloatingActionButton.extended(
                heroTag: null,
                key: const Key('agregar-presupuesto'),
                onPressed: () => showBudgetEditor(context, range: range),
                icon: const Icon(Icons.add),
                label: const Text('Agregar'),
              )
            : const SizedBox.shrink(),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: MonthNavigator(year: _year, month: _month, onChanged: _setMonth, keyPrefix: 'reporte-mes'),
        ),
        Expanded(
          child: TabBarView(controller: _tabs, children: [
            _SummaryTab(year: _year, month: _month),
            BudgetsTab(range: range),
          ]),
        ),
      ]),
    );
  }
}

class _SummaryTab extends ConsumerWidget {
  const _SummaryTab({required this.year, required this.month});

  final int year;
  final int month;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final range = monthRange(year, month);
    final totals = ref.watch(totalsProvider(TransactionFilter(from: range.from, to: range.to))).value;
    final spend = ref.watch(expensesByCategoryProvider(range)).value ?? const [];
    final trend = ref.watch(monthlyTrendProvider((year: year, month: month))).value ?? const [];
    final income = _incomeColor(theme);
    final expense = theme.colorScheme.error;
    final totalSpend = spend.fold<int>(0, (sum, c) => sum + c.total.cents);

    Color colorOf(CategorySpend c) => c.categoryId == null ? theme.colorScheme.outline : categoryDisplayColor(c.color, c.name);
    final slices = pieSlices(spend, colorOf: colorOf, otherColor: const Color(0xFF78909C)); // "Otras" (gris azulado) ≠ "Sin categoría" (gris)

    return RefreshIndicator(
      onRefresh: () => ref.read(syncControllerProvider.notifier).syncNow(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Card(
            color: theme.colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _Figure(label: 'Ingresos', value: totals?.income.format() ?? '', color: income, valueKey: const Key('resumen-ingresos'))),
                Expanded(child: _Figure(label: 'Gastos', value: totals?.expense.format() ?? '', color: expense, valueKey: const Key('resumen-gastos'))),
                Expanded(
                  child: _Figure(
                    label: 'Balance',
                    value: totals?.net.format() ?? '',
                    color: (totals?.net.isNegative ?? false) ? expense : null,
                    valueKey: const Key('resumen-balance'),
                  ),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 16),
          Text('Gastos por categoría', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (spend.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text('Sin gastos en este mes', key: const Key('sin-gastos-mes'), textAlign: TextAlign.center, style: TextStyle(color: theme.colorScheme.outline)),
            )
          else ...[
            Center(child: ExpensePie(slices: slices)),
            const SizedBox(height: 8),
            for (final c in spend)
              ListTile(
                key: Key('gasto-categoria-${c.categoryId ?? 'sin'}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(radius: 8, backgroundColor: colorOf(c)),
                title: Text(c.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: FitTrailing(
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(c.total.format(), style: theme.textTheme.titleSmall),
                    const SizedBox(width: 8),
                    Text('${percentOf(c.total.cents, totalSpend)} %', style: theme.textTheme.bodySmall),
                  ]),
                ),
              ),
          ],
          const SizedBox(height: 24),
          Text('Tendencia de ${trend.isEmpty ? 3 : trend.length} meses', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (trend.isNotEmpty) ...[
            Wrap(spacing: 16, runSpacing: 4, children: [
              _Legend(color: income, label: 'Ingresos'),
              _Legend(color: expense, label: 'Gastos'),
            ]),
            const SizedBox(height: 8),
            TrendChart(points: trend, incomeColor: income, expenseColor: expense),
            for (final p in trend)
              ListTile(
                key: Key('tendencia-${p.year}-${p.month}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(monthLabel(p.year, p.month)),
                subtitle: Text('Ingresos ${p.income.format()} · Gastos ${p.expense.format()}', maxLines: 3, overflow: TextOverflow.ellipsis),
                trailing: FitTrailing(
                  child: Text(p.net.format(), style: theme.textTheme.titleSmall?.copyWith(color: p.net.isNegative ? expense : null)),
                ),
              ),
          ],
        ],
      ),
    );
  }

  static Color _incomeColor(ThemeData theme) => theme.brightness == Brightness.dark ? const Color(0xFF81C784) : const Color(0xFF2E7D32);
}

class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value, required this.valueKey, this.color});

  final String label;
  final String value;
  final Key valueKey;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: theme.textTheme.labelLarge),
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(value, key: valueKey, style: theme.textTheme.titleLarge?.copyWith(color: color)),
      ),
    ]);
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        CircleAvatar(radius: 6, backgroundColor: color),
        const SizedBox(width: 6),
        Text(label),
      ]);
}
