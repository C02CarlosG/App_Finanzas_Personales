import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/data/validation_exception.dart';
import '../../../core/db/queries_fase2.dart';
import '../../../core/format/dates.dart';
import '../../../core/money/money.dart';
import '../../../core/ui/money_form_field.dart';
import '../../../core/ui/pickers.dart';
import 'subscription_labels.dart';

/// Alta o edición de una suscripción.
class SubscriptionFormPage extends ConsumerStatefulWidget {
  const SubscriptionFormPage({super.key, this.subscriptionId});

  final String? subscriptionId;

  @override
  ConsumerState<SubscriptionFormPage> createState() => _SubscriptionFormPageState();
}

class _SubscriptionFormPageState extends ConsumerState<SubscriptionFormPage> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _amount = TextEditingController();
  String _period = 'monthly';
  String? _renewal;
  String? _accountId;
  bool _active = true;
  bool _loaded = false;
  bool _busy = false;
  String? _error;

  bool get _editing => widget.subscriptionId != null;

  @override
  void initState() {
    super.initState();
    _renewal = isoDate(ref.read(todayProvider));
  }

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    super.dispose();
  }

  void _initFrom(SubscriptionView s) {
    if (_loaded) return;
    _loaded = true;
    _name.text = s.name;
    _amount.text = s.amount.toApiString();
    _period = s.period;
    _renewal = s.renewalDate;
    _accountId = s.accountId;
    _active = s.active;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(subscriptionsRepositoryProvider);
      final amount = MoneyFormField.read(_amount) ?? Money.zero;
      if (_editing) {
        await repo.update(widget.subscriptionId!, name: _name.text, amount: amount, renewalDate: _renewal!, period: _period, accountId: _accountId, active: _active);
      } else {
        await repo.create(name: _name.text, amount: amount, renewalDate: _renewal!, period: _period, accountId: _accountId);
      }
      if (mounted) context.pop();
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
        title: const Text('¿Eliminar esta suscripción?'),
        content: Text('Se eliminará "${_name.text}".'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(key: const Key('confirmar-eliminar'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Eliminar')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(subscriptionsRepositoryProvider).delete(widget.subscriptionId!);
      if (mounted) context.pop();
    } on ValidationException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_editing) {
      final subs = ref.watch(subscriptionsProvider);
      final sub = subs.value?.where((s) => s.id == widget.subscriptionId).firstOrNull;
      if (sub == null) {
        return Scaffold(
          appBar: AppBar(title: const Text('Suscripción')),
          body: Center(child: subs.isLoading ? const CircularProgressIndicator() : const Text('La suscripción ya no existe')),
        );
      }
      _initFrom(sub);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? 'Editar suscripción' : 'Nueva suscripción'),
        actions: [
          if (_editing) IconButton(key: const Key('eliminar-suscripcion'), tooltip: 'Eliminar', icon: const Icon(Icons.delete_outline), onPressed: _delete),
        ],
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextFormField(
                key: const Key('campo-nombre-suscripcion'),
                controller: _name,
                maxLength: 100,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Servicio', hintText: 'Netflix, Spotify…'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Escribe el nombre del servicio' : null,
              ),
              MoneyFormField(key: const Key('campo-monto-suscripcion'), controller: _amount, positiveOnly: true),
              const SizedBox(height: 12),
              Text('Se cobra', style: theme.textTheme.bodySmall),
              const SizedBox(height: 4),
              Wrap(spacing: 8, runSpacing: 4, children: [
                for (final p in ['weekly', 'monthly', 'yearly'])
                  ChoiceChip(key: Key('periodo-$p'), label: Text(periodLabel(p)), selected: _period == p, onSelected: (_) => setState(() => _period = p)),
              ]),
              const SizedBox(height: 4),
              DateTile(label: 'Próxima renovación', value: _renewal, onChanged: (v) => setState(() => _renewal = v ?? _renewal)),
              AccountDropdown(
                key: const Key('campo-cuenta-suscripcion'),
                label: 'Cuenta (opcional)',
                allowNone: true,
                value: _accountId,
                onChanged: (v) => setState(() => _accountId = v),
              ),
              if (_editing)
                SwitchListTile(
                  key: const Key('suscripcion-activa'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Activa'),
                  subtitle: const Text('Pausar la deja en la lista sin contarla en el gasto mensual'),
                  value: _active,
                  onChanged: (v) => setState(() => _active = v),
                ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, key: const Key('error-suscripcion'), style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 16),
              FilledButton(key: const Key('guardar-suscripcion'), onPressed: _busy ? null : _save, child: Text(_editing ? 'Guardar cambios' : 'Guardar suscripción')),
            ],
          ),
        ),
      ),
    );
  }
}
