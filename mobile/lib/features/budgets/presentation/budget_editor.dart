import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/data/validation_exception.dart';
import '../../../core/db/queries_fase3.dart';
import '../../../core/money/money.dart';
import '../../../core/ui/money_form_field.dart';
import '../../../core/ui/pickers.dart';
import '../data/budgets_repository.dart';

/// Hoja para crear o editar un presupuesto. Al crear, ofrece las categorías de gastos que aún no tienen uno;
/// al editar, la categoría queda fija y se puede quitar el presupuesto.
Future<void> showBudgetEditor(BuildContext context, {required DateRange range, BudgetProgress? budget}) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _BudgetEditor(range: range, budget: budget),
    );

class _BudgetEditor extends ConsumerStatefulWidget {
  const _BudgetEditor({required this.range, this.budget});

  final DateRange range;
  final BudgetProgress? budget;

  @override
  ConsumerState<_BudgetEditor> createState() => _BudgetEditorState();
}

class _BudgetEditorState extends ConsumerState<_BudgetEditor> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _limit;
  String? _categoryId;
  late int _alert;
  bool _busy = false;
  String? _error;

  bool get _editing => widget.budget != null;

  @override
  void initState() {
    super.initState();
    _limit = TextEditingController(text: widget.budget?.limit.toApiString() ?? '');
    _categoryId = widget.budget?.categoryId;
    _alert = widget.budget?.alertPercent ?? 80;
  }

  @override
  void dispose() {
    _limit.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(budgetsRepositoryProvider).save(
            categoryId: _categoryId!,
            limit: MoneyFormField.read(_limit) ?? Money.zero,
            alertPercent: _alert,
          );
      if (mounted) Navigator.of(context).pop();
    } on ValidationException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Quitar este presupuesto?'),
        content: Text('Se quitará el límite de "${widget.budget!.categoryName}". Tus gastos no cambian.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(key: const Key('confirmar-quitar'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Quitar')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(budgetsRepositoryProvider).delete(widget.budget!.id);
      if (mounted) Navigator.of(context).pop();
    } on ValidationException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final categories = ref.watch(categoriesProvider('expense')).value ?? const [];
    final taken = {for (final b in ref.watch(budgetsProvider(widget.range)).value ?? const <BudgetProgress>[]) b.categoryId};
    final available = categories.where((c) => !taken.contains(c.id)).toList();

    return SheetBody(
      title: _editing ? 'Editar presupuesto' : 'Nuevo presupuesto',
      children: [
        Form(
          key: _formKey,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (_editing)
              ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.category_outlined), title: Text(widget.budget!.categoryName))
            else if (available.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('Todas tus categorías de gastos ya tienen presupuesto.', key: Key('sin-categorias-libres')),
              )
            else
              DropdownButtonFormField<String>(
                key: const Key('campo-categoria-presupuesto'),
                isExpanded: true,
                initialValue: available.any((c) => c.id == _categoryId) ? _categoryId : null,
                decoration: const InputDecoration(labelText: 'Categoría de gastos'),
                items: [for (final c in available) DropdownMenuItem(value: c.id, child: Text(c.name, overflow: TextOverflow.ellipsis))],
                onChanged: (v) => setState(() => _categoryId = v),
                validator: (v) => v == null ? 'Elige una categoría' : null,
              ),
            MoneyFormField(key: const Key('campo-limite'), controller: _limit, label: 'Límite mensual', positiveOnly: true, autofocus: !_editing),
            const SizedBox(height: 12),
            Text('Avisarme al llegar a', style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            Wrap(spacing: 8, runSpacing: 4, children: [
              for (final p in ({...BudgetsRepository.alertChoices, _alert}.toList()..sort()))
                ChoiceChip(key: Key('umbral-$p'), label: Text('$p %'), selected: _alert == p, onSelected: (_) => setState(() => _alert = p)),
            ]),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, key: const Key('error-presupuesto'), style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 12),
            FilledButton(
              key: const Key('guardar-presupuesto'),
              onPressed: (_busy || (!_editing && available.isEmpty)) ? null : _save,
              child: Text(_editing ? 'Guardar cambios' : 'Guardar presupuesto'),
            ),
            if (_editing) TextButton(key: const Key('quitar-presupuesto'), onPressed: _delete, child: const Text('Quitar presupuesto')),
          ]),
        ),
      ],
    );
  }
}
