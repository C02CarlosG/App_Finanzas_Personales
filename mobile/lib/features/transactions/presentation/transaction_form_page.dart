import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/data/validation_exception.dart';
import '../../../core/db/queries.dart';
import '../../../core/format/dates.dart';
import '../../../core/money/money.dart';
import '../../../core/providers.dart';
import '../../../core/router/app_router.dart';
import '../../../core/ui/money_form_field.dart';

const _createAccountOption = '__crear_cuenta__';

/// Agregar o editar un ingreso o gasto (spec 5.3/5.4): monto, categoría, cuenta (con opción de crear
/// una nueva desde aquí), fecha y descripción. Con "Préstamo cobrado" también pide la persona.
class TransactionFormPage extends ConsumerStatefulWidget {
  const TransactionFormPage({super.key, this.type = 'expense', this.transactionId});

  /// `income` | `expense`. Al editar se toma del movimiento.
  final String type;
  final String? transactionId;

  @override
  ConsumerState<TransactionFormPage> createState() => _TransactionFormPageState();
}

class _TransactionFormPageState extends ConsumerState<TransactionFormPage> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _description = TextEditingController();
  final _person = TextEditingController();
  late String _type = widget.type;
  String? _categoryId;
  String? _accountId;
  late String _date = isoDate(DateTime.now());
  int _accountFieldEpoch = 0; // fuerza reconstruir el desplegable de cuentas (p. ej. al cancelar "crear cuenta")
  bool _loading = false;
  bool _busy = false;
  String? _error;

  bool get _editing => widget.transactionId != null;

  @override
  void initState() {
    super.initState();
    if (_editing) {
      _loading = true;
      _loadExisting();
    }
  }

  Future<void> _loadExisting() async {
    final tx = await ref.read(databaseProvider)?.findTransaction(widget.transactionId!);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (tx == null) {
        _error = 'El movimiento ya no existe';
        return;
      }
      _type = tx.type;
      _amount.text = tx.amount.toApiString();
      _categoryId = tx.categoryId;
      _accountId = tx.accountId;
      _date = tx.occurredOn;
      _description.text = tx.description ?? '';
      _person.text = tx.counterparty ?? '';
    });
  }

  @override
  void dispose() {
    _amount.dispose();
    _description.dispose();
    _person.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final current = parseIsoDate(_date);
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _date = isoDate(picked));
  }

  Future<void> _onAccountChanged(String? value) async {
    if (value != _createAccountOption) {
      setState(() => _accountId = value);
      return;
    }
    // Spec 5.3: crear un banco nuevo sin salir del formulario; la cuenta creada queda seleccionada.
    final id = await context.push<String>(AppRoutes.accountNew);
    if (!mounted) return;
    setState(() {
      // Al cancelar, el desplegable se queda mostrando "+ Crear…" y bloquearía el guardado: se reconstruye.
      if (id != null) _accountId = id;
      _accountFieldEpoch += 1;
    });
  }

  /// Con una sola cuenta se preselecciona (lo más común); con varias, el usuario elige.
  /// Se usa tanto para mostrar el desplegable como para guardar (si no, lo visible y lo guardado difieren).
  String? _effectiveAccountId(List<AccountView> accounts) =>
      accounts.any((a) => a.id == _accountId) ? _accountId : (accounts.length == 1 && !_editing ? accounts.first.id : null);

  Future<void> _save({required bool needsPerson}) async {
    if (!_formKey.currentState!.validate()) return;
    final accountId = _effectiveAccountId(ref.read(accountsProvider).value ?? const <AccountView>[]);
    setState(() {
      _busy = true;
      _error = null;
    });
    final repo = ref.read(transactionsRepositoryProvider);
    final amount = MoneyFormField.read(_amount) ?? Money.zero;
    try {
      if (_editing) {
        await repo.update(widget.transactionId!,
            type: _type,
            amount: amount,
            accountId: accountId ?? '',
            categoryId: _categoryId ?? '',
            occurredOn: _date,
            description: _description.text,
            counterparty: needsPerson ? _person.text : null);
      } else {
        await repo.add(
            type: _type,
            amount: amount,
            accountId: accountId ?? '',
            categoryId: _categoryId ?? '',
            occurredOn: _date,
            description: _description.text,
            counterparty: needsPerson ? _person.text : null);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_type == 'income' ? 'Ingreso guardado' : 'Gasto guardado')));
      context.pop();
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
        title: const Text('¿Eliminar este movimiento?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(key: const Key('confirmar-eliminar'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Eliminar')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(transactionsRepositoryProvider).delete(widget.transactionId!);
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final categories = ref.watch(categoriesProvider(_type)).value ?? const [];
    final accounts = ref.watch(accountsProvider).value ?? const <AccountView>[];

    final accountId = _effectiveAccountId(accounts);
    final category = categories.where((c) => c.id == _categoryId).firstOrNull;
    final needsPerson = _type == 'income' && (category?.isSystem ?? false);
    final isIncome = _type == 'income';

    if (_loading) {
      return Scaffold(appBar: AppBar(title: const Text('Movimiento')), body: const Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? (isIncome ? 'Editar ingreso' : 'Editar gasto') : (isIncome ? 'Nuevo ingreso' : 'Nuevo gasto')),
        actions: [
          if (_editing)
            IconButton(key: const Key('eliminar-movimiento'), tooltip: 'Eliminar', icon: const Icon(Icons.delete_outline), onPressed: _delete),
        ],
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              MoneyFormField(key: const Key('campo-monto'), controller: _amount, positiveOnly: true, autofocus: !_editing),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const Key('campo-categoria'),
                isExpanded: true,
                initialValue: categories.any((c) => c.id == _categoryId) ? _categoryId : null,
                decoration: const InputDecoration(labelText: 'Categoría'),
                items: [for (final c in categories) DropdownMenuItem(value: c.id, child: Text(c.name, overflow: TextOverflow.ellipsis))],
                onChanged: (v) => setState(() => _categoryId = v),
                validator: (v) => v == null ? 'Elige una categoría' : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey('campo-cuenta-${accounts.length}-$accountId-$_accountFieldEpoch'),
                isExpanded: true,
                initialValue: accountId,
                decoration: const InputDecoration(labelText: 'Cuenta'),
                items: [
                  for (final a in accounts) DropdownMenuItem(value: a.id, child: Text('${a.name} · ${a.balance.format()}', overflow: TextOverflow.ellipsis)),
                  const DropdownMenuItem(value: _createAccountOption, child: Text('+ Crear cuenta o banco nuevo', overflow: TextOverflow.ellipsis)),
                ],
                onChanged: _onAccountChanged,
                validator: (v) => (v == null || v == _createAccountOption) ? 'Elige una cuenta' : null,
              ),
              const SizedBox(height: 12),
              ListTile(
                key: const Key('campo-fecha'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event),
                title: const Text('Fecha'),
                subtitle: Text(formatDate(_date)),
                onTap: _pickDate,
              ),
              if (needsPerson) ...[
                TextFormField(
                  key: const Key('campo-persona'),
                  controller: _person,
                  maxLength: 100,
                  decoration: const InputDecoration(labelText: 'Persona que te pagó'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Escribe el nombre de la persona' : null,
                ),
                const SizedBox(height: 4),
              ],
              TextFormField(
                key: const Key('campo-descripcion'),
                controller: _description,
                maxLength: 500,
                decoration: const InputDecoration(labelText: 'Descripción (opcional)'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, key: const Key('error-movimiento'), style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('guardar-movimiento'),
                onPressed: _busy ? null : () => _save(needsPerson: needsPerson),
                child: const Text('Guardar'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
