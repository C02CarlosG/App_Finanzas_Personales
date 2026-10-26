import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/data/validation_exception.dart';
import '../../../core/db/queries_fase2.dart';
import '../../../core/money/money.dart';
import '../../../core/ui/money_form_field.dart';
import '../../../core/ui/pickers.dart';

/// Alta o edición de una tarjeta de crédito. Aquí se corrige el saldo pendiente (p. ej. al llegar el estado de cuenta).
class CardFormPage extends ConsumerStatefulWidget {
  const CardFormPage({super.key, this.cardId});

  final String? cardId;

  @override
  ConsumerState<CardFormPage> createState() => _CardFormPageState();
}

class _CardFormPageState extends ConsumerState<CardFormPage> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _balance = TextEditingController(text: '0');
  String? _bankId;
  String? _dueDate;
  bool _loaded = false;
  bool _busy = false;
  String? _error;

  bool get _editing => widget.cardId != null;

  @override
  void dispose() {
    _name.dispose();
    _balance.dispose();
    super.dispose();
  }

  void _initFrom(CreditCardView c) {
    if (_loaded) return;
    _loaded = true;
    _name.text = c.name;
    _balance.text = c.pendingBalance.toApiString();
    _bankId = c.bankId;
    _dueDate = c.dueDate;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(creditCardsRepositoryProvider);
      final balance = MoneyFormField.read(_balance) ?? Money.zero;
      if (_editing) {
        await repo.update(widget.cardId!, name: _name.text, bankId: _bankId, pendingBalance: balance, dueDate: _dueDate);
      } else {
        await repo.create(name: _name.text, bankId: _bankId, pendingBalance: balance, dueDate: _dueDate);
      }
      if (mounted) context.pop();
    } on ValidationException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final banks = ref.watch(banksProvider).value ?? const [];
    if (_editing) {
      final cards = ref.watch(creditCardsProvider);
      final card = cards.value?.where((c) => c.id == widget.cardId).firstOrNull;
      if (card == null) {
        return Scaffold(
          appBar: AppBar(title: const Text('Tarjeta')),
          body: Center(child: cards.isLoading ? const CircularProgressIndicator() : const Text('La tarjeta ya no existe')),
        );
      }
      _initFrom(card);
    }

    return Scaffold(
      appBar: AppBar(title: Text(_editing ? 'Editar tarjeta' : 'Nueva tarjeta')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextFormField(
                key: const Key('campo-nombre-tarjeta'),
                controller: _name,
                maxLength: 100,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Nombre', hintText: 'BBVA Azul, Nu…'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Escribe el nombre de la tarjeta' : null,
              ),
              DropdownButtonFormField<String?>(
                key: ValueKey('banco-tarjeta-${banks.length}-$_bankId'),
                isExpanded: true,
                initialValue: banks.any((b) => b.id == _bankId) ? _bankId : null,
                decoration: const InputDecoration(labelText: 'Banco (opcional)'),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('Sin banco')),
                  for (final b in banks) DropdownMenuItem<String?>(value: b.id, child: Text(b.name, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => setState(() => _bankId = v),
              ),
              const SizedBox(height: 4),
              MoneyFormField(key: const Key('campo-saldo-tarjeta'), controller: _balance, label: 'Saldo pendiente'),
              DateTile(label: 'Fecha de vencimiento (opcional)', hint: 'Sin fecha', value: _dueDate, clearable: true, onChanged: (v) => setState(() => _dueDate = v)),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, key: const Key('error-tarjeta'), style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 16),
              FilledButton(key: const Key('guardar-tarjeta'), onPressed: _busy ? null : _save, child: Text(_editing ? 'Guardar cambios' : 'Guardar tarjeta')),
            ],
          ),
        ),
      ),
    );
  }
}
