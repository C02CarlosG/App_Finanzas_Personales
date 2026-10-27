import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/data/validation_exception.dart';
import '../../../core/db/queries.dart';
import '../../../core/format/dates.dart';
import '../../../core/providers.dart';
import '../../../core/ui/pickers.dart';
import '../data/export_models.dart';
import '../data/export_service.dart';
import '../export_providers.dart';

enum ExportPeriod {
  thisMonth('Este mes'),
  lastMonth('Mes anterior'),
  last3Months('Últimos 3 meses'),
  thisYear('Este año'),
  custom('Fechas…');

  const ExportPeriod(this.label);
  final String label;
}

/// Periodo `[from, to)` de un preset respecto a [today]; `custom` usa las fechas elegidas (ambas incluidas).
({String from, String to}) exportRange(ExportPeriod period, DateTime today, {String? customFrom, String? customTo}) {
  switch (period) {
    case ExportPeriod.thisMonth:
      return monthRange(today.year, today.month);
    case ExportPeriod.lastMonth:
      final p = previousMonth(today.year, today.month);
      return monthRange(p.year, p.month);
    case ExportPeriod.last3Months:
      final start = addMonths(DateTime(today.year, today.month, 1), -2);
      return (from: monthRange(start.year, start.month).from, to: monthRange(today.year, today.month).to);
    case ExportPeriod.thisYear:
      return (from: '${today.year}-01-01', to: '${today.year + 1}-01-01');
    case ExportPeriod.custom:
      final from = customFrom ?? isoDate(today);
      final last = customTo ?? from;
      return (from: from, to: isoDate(parseIsoDate(last).add(const Duration(days: 1))));
  }
}

/// Exportación a Excel o PDF (spec 4.8): se genera en el dispositivo, sin conexión, y se comparte con la hoja
/// del sistema (correo, WhatsApp, Drive…), p. ej. para entregárselo a un contador.
class ExportPage extends ConsumerStatefulWidget {
  const ExportPage({super.key});

  @override
  ConsumerState<ExportPage> createState() => _ExportPageState();
}

class _ExportPageState extends ConsumerState<ExportPage> {
  ExportPeriod _period = ExportPeriod.thisMonth;
  String? _customFrom;
  String? _customTo;
  String? _type; // income | expense | null
  String? _accountId;
  String? _categoryId;
  ExportFormat _format = ExportFormat.excel;
  bool _busy = false;
  String? _error;

  ({String from, String to}) get _range => exportRange(_period, ref.read(todayProvider), customFrom: _customFrom, customTo: _customTo);

  TransactionFilter _filter(({String from, String to}) r) =>
      TransactionFilter(type: _type, accountId: _accountId, categoryId: _categoryId, from: r.from, to: r.to);

  void _pickPeriod(ExportPeriod p) {
    setState(() {
      _period = p;
      _error = null;
      if (p == ExportPeriod.custom) {
        final today = isoDate(ref.read(todayProvider));
        _customFrom ??= '${today.substring(0, 8)}01';
        _customTo ??= today;
      }
    });
  }

  Future<void> _export() async {
    final service = ref.read(exportServiceProvider);
    if (service == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = ref.read(authControllerProvider).value;
      final range = _range;
      final data = await service.prepare(
        ExportRequest(from: range.from, to: range.to, type: _type, accountId: _accountId, categoryId: _categoryId),
        userName: session?.name ?? '',
        userEmail: session?.email ?? '',
        now: DateTime.now(),
      );
      // Deja pintar el indicador antes del trabajo pesado de generar el archivo.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final file = await service.exportAndShare(data, _format);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(key: const Key('aviso-exportacion'), content: Text('Listo: ${file.name}')));
      }
    } on ValidationException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'No se pudo generar o compartir el archivo. Intenta de nuevo.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final range = _range;
    final invalidRange = range.from.compareTo(range.to) >= 0;
    final filter = _filter(range);
    final accounts = ref.watch(accountsProvider).value ?? const [];
    final categories = ref.watch(categoriesProvider(_type)).value ?? const [];
    final count = invalidRange ? null : ref.watch(transactionsProvider(filter)).value?.length;
    final totals = invalidRange ? null : ref.watch(totalsProvider(filter)).value;
    final theme = Theme.of(context);
    final lastDay = invalidRange ? null : isoDate(parseIsoDate(range.to).subtract(const Duration(days: 1)));
    final canExport = !_busy && !invalidRange && (count ?? 0) > 0;

    return Scaffold(
      appBar: AppBar(title: const Text('Exportar')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Se genera en tu teléfono, sin internet, y lo compartes por correo, WhatsApp, Drive…',
              style: theme.textTheme.bodyMedium),
          const SizedBox(height: 16),
          Text('Periodo', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final p in ExportPeriod.values)
              ChoiceChip(
                key: Key('periodo-${p.name}'),
                label: Text(p.label),
                selected: _period == p,
                onSelected: (_) => _pickPeriod(p),
              ),
          ]),
          if (_period == ExportPeriod.custom) ...[
            DateTile(
              key: const Key('fecha-desde'),
              label: 'Desde',
              value: _customFrom,
              onChanged: (v) => setState(() {
                _customFrom = v;
                _error = null;
              }),
            ),
            DateTile(
              key: const Key('fecha-hasta'),
              label: 'Hasta (incluida)',
              value: _customTo,
              onChanged: (v) => setState(() {
                _customTo = v;
                _error = null;
              }),
            ),
          ],
          if (lastDay != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Del ${formatDate(range.from)} al ${formatDate(lastDay)}',
                  key: const Key('periodo-elegido'), style: theme.textTheme.bodySmall),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('La fecha final debe ser igual o posterior a la inicial',
                  key: const Key('periodo-invalido'), style: TextStyle(color: theme.colorScheme.error)),
            ),
          const SizedBox(height: 16),
          Text('Qué incluir', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (key, label, value) in [('todos', 'Todo', null), ('ingresos', 'Solo ingresos', 'income'), ('gastos', 'Solo gastos', 'expense')])
              ChoiceChip(
                key: Key('tipo-$key'),
                label: Text(label),
                selected: _type == value,
                onSelected: (_) => setState(() {
                  _type = value;
                  _categoryId = null; // la categoría elegida puede no ser del tipo nuevo
                  _error = null;
                }),
              ),
          ]),
          const SizedBox(height: 8),
          DropdownButtonFormField<String?>(
            key: ValueKey('cuenta-${accounts.length}-$_accountId'),
            isExpanded: true,
            initialValue: accounts.any((a) => a.id == _accountId) ? _accountId : null,
            decoration: const InputDecoration(labelText: 'Cuenta'),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('Todas las cuentas')),
              for (final a in accounts) DropdownMenuItem<String?>(value: a.id, child: Text(a.name, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() => _accountId = v),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String?>(
            key: ValueKey('categoria-${categories.length}-$_type-$_categoryId'),
            isExpanded: true,
            initialValue: categories.any((c) => c.id == _categoryId) ? _categoryId : null,
            decoration: const InputDecoration(labelText: 'Categoría'),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('Todas las categorías')),
              for (final c in categories)
                DropdownMenuItem<String?>(
                  value: c.id,
                  child: Text(_type == null ? '${c.name} · ${c.kind == 'income' ? 'ingreso' : 'gasto'}' : c.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => setState(() => _categoryId = v),
          ),
          const SizedBox(height: 16),
          Text('Formato', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final f in ExportFormat.values)
              ChoiceChip(
                key: Key('formato-${f.extension}'),
                label: Text(f.label),
                selected: _format == f,
                onSelected: (_) => setState(() => _format = f),
              ),
          ]),
          const SizedBox(height: 4),
          Text(
            _format == ExportFormat.excel
                ? 'Hojas «Resumen» y «Movimientos»; los importes son números que Excel puede sumar.'
                : 'Documento listo para imprimir o enviar, con resumen por categoría y el detalle.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: invalidRange
                  ? const Text('Elige un periodo válido para ver cuántos movimientos se exportarán.')
                  : (count == null || totals == null)
                      ? const Text('Calculando…')
                      : count == 0
                          ? const Text('No hay movimientos con estos criterios.', key: Key('vista-previa-vacia'))
                          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('$count ${count == 1 ? 'movimiento' : 'movimientos'}', key: const Key('vista-previa-cuenta'), style: theme.textTheme.titleSmall),
                              const SizedBox(height: 4),
                              Text('Ingresos ${totals.income.format()}', key: const Key('vista-previa-ingresos')),
                              Text('Gastos ${totals.expense.format()}', key: const Key('vista-previa-gastos')),
                              Text('Neto ${totals.net.format()}', key: const Key('vista-previa-neto')),
                            ]),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, key: const Key('error-exportacion'), style: TextStyle(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('exportar-boton'),
            onPressed: canExport ? _export : null,
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.ios_share),
            label: const Text('Generar y compartir'),
          ),
        ],
      ),
    );
  }
}
