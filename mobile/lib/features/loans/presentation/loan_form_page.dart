import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/data/validation_exception.dart';
import '../../../core/db/queries_fase2.dart';
import '../../../core/money/money.dart';
import '../../../core/ui/money_form_field.dart';
import '../../../core/ui/pickers.dart';

/// Alta o edición de un préstamo. El sentido (te debe / le debes) no se puede cambiar al editar.
class LoanFormPage extends ConsumerStatefulWidget {
  const LoanFormPage({super.key, this.loanId});

  final String? loanId;

  @override
  ConsumerState<LoanFormPage> createState() => _LoanFormPageState();
}

class _LoanFormPageState extends ConsumerState<LoanFormPage> {
  final _formKey = GlobalKey<FormState>();
  final _person = TextEditingController();
  final _amount = TextEditingController();
  final _notes = TextEditingController();
  String _direction = 'owed_to_me';
  String? _dueDate;
  bool _loaded = false;
  bool _busy = false;
  String? _error;

  bool get _editing => widget.loanId != null;

  @override
  void dispose() {
    _person.dispose();
    _amount.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _initFrom(LoanView l) {
    if (_loaded) return;
    _loaded = true;
    _person.text = l.personName;
    _amount.text = l.principal.toApiString();
    _notes.text = l.notes ?? '';
    _direction = l.direction;
    _dueDate = l.dueDate;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(loansRepositoryProvider);
      final amount = MoneyFormField.read(_amount) ?? Money.zero;
      if (_editing) {
        await repo.update(widget.loanId!, personName: _person.text, principal: amount, dueDate: _dueDate, notes: _notes.text);
        if (mounted) context.pop();
      } else {
        final id = await repo.create(personName: _person.text, direction: _direction, principal: amount, dueDate: _dueDate, notes: _notes.text);
        if (mounted) context.pop(id);
      }
    } on ValidationException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_editing) {
      final loan = ref.watch(loanProvider(widget.loanId!));
      final view = loan.value;
      if (view == null) {
        return Scaffold(
          appBar: AppBar(title: const Text('Préstamo')),
          body: Center(child: loan.isLoading ? const CircularProgressIndicator() : const Text('El préstamo ya no existe')),
        );
      }
      _initFrom(view);
    }

    return Scaffold(
      appBar: AppBar(title: Text(_editing ? 'Editar préstamo' : 'Nuevo préstamo')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Wrap(spacing: 8, runSpacing: 4, children: [
                ChoiceChip(
                  key: const Key('sentido-me-debe'),
                  label: const Text('Me debe'),
                  selected: _direction == 'owed_to_me',
                  onSelected: _editing ? null : (_) => setState(() => _direction = 'owed_to_me'),
                ),
                ChoiceChip(
                  key: const Key('sentido-le-debo'),
                  label: const Text('Le debo'),
                  selected: _direction == 'i_owe',
                  onSelected: _editing ? null : (_) => setState(() => _direction = 'i_owe'),
                ),
              ]),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('campo-persona-prestamo'),
                controller: _person,
                maxLength: 100,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Persona'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Escribe el nombre de la persona' : null,
              ),
              MoneyFormField(key: const Key('campo-monto-prestamo'), controller: _amount, label: _editing ? 'Monto original' : 'Monto', positiveOnly: true),
              const SizedBox(height: 4),
              DateTile(label: 'Plazo de pago (opcional)', hint: 'Sin plazo', value: _dueDate, clearable: true, onChanged: (v) => setState(() => _dueDate = v)),
              TextFormField(
                key: const Key('campo-notas-prestamo'),
                controller: _notes,
                maxLength: 500,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Notas (opcional)'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, key: const Key('error-prestamo'), style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 16),
              FilledButton(key: const Key('guardar-prestamo'), onPressed: _busy ? null : _save, child: Text(_editing ? 'Guardar cambios' : 'Guardar préstamo')),
            ],
          ),
        ),
      ),
    );
  }
}
