import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/data/validation_exception.dart';
import '../../../core/db/queries.dart';
import '../../../core/money/money.dart';
import '../../../core/ui/money_form_field.dart';
import 'bank_avatar.dart';

/// Editar o eliminar una cuenta. El banco y el tipo (banco/efectivo) no cambian.
class EditAccountPage extends ConsumerStatefulWidget {
  const EditAccountPage({super.key, required this.accountId});

  final String accountId;

  @override
  ConsumerState<EditAccountPage> createState() => _EditAccountPageState();
}

class _EditAccountPageState extends ConsumerState<EditAccountPage> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _balance = TextEditingController();
  String? _cardType;
  bool _loaded = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _balance.dispose();
    super.dispose();
  }

  void _initFrom(AccountView a) {
    if (_loaded) return;
    _loaded = true;
    _name.text = a.name;
    _balance.text = a.initialBalance.toApiString();
    _cardType = a.cardType;
  }

  Future<void> _save(AccountView a) async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(accountsRepositoryProvider).update(
            a.id,
            name: _name.text,
            cardType: a.isCash ? null : _cardType,
            initialBalance: MoneyFormField.read(_balance) ?? Money.zero,
          );
      if (mounted) context.pop();
    } on ValidationException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(AccountView a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Eliminar esta cuenta?'),
        content: Text('Se eliminará "${a.name}".'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(key: const Key('confirmar-eliminar'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Eliminar')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(accountsRepositoryProvider).delete(a.id);
      if (mounted) context.pop();
    } on ValidationException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(accountsProvider);
    final account = accounts.value?.where((a) => a.id == widget.accountId).firstOrNull;
    final theme = Theme.of(context);

    if (account == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Cuenta')),
        body: Center(child: accounts.isLoading ? const CircularProgressIndicator() : const Text('La cuenta ya no existe')),
      );
    }
    _initFrom(account);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Editar cuenta'),
        actions: [
          IconButton(
            key: const Key('eliminar-cuenta'),
            tooltip: 'Eliminar',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _delete(account),
          ),
        ],
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(children: [
                account.isCash ? const CashAvatar(size: 52) : BankAvatar(name: account.bankName ?? account.name, logoKey: account.logoKey, size: 52),
                const SizedBox(width: 12),
                Expanded(child: Text(account.isCash ? 'Efectivo' : (account.bankName ?? 'Banco'), style: theme.textTheme.titleMedium)),
                Text(account.balance.format(), key: const Key('saldo-actual'), style: theme.textTheme.titleMedium),
              ]),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('campo-nombre-cuenta'),
                controller: _name,
                decoration: const InputDecoration(labelText: 'Nombre'),
                maxLength: 100,
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Escribe un nombre' : null,
              ),
              if (!account.isCash) ...[
                const SizedBox(height: 4),
                Wrap(spacing: 8, children: [
                  ChoiceChip(
                    key: const Key('tipo-debito'),
                    label: const Text('Débito'),
                    selected: _cardType == 'debito',
                    onSelected: (v) => setState(() => _cardType = v ? 'debito' : null),
                  ),
                  ChoiceChip(
                    key: const Key('tipo-credito'),
                    label: const Text('Crédito'),
                    selected: _cardType == 'credito',
                    onSelected: (v) => setState(() => _cardType = v ? 'credito' : null),
                  ),
                ]),
                const SizedBox(height: 12),
              ],
              MoneyFormField(key: const Key('campo-saldo-inicial'), controller: _balance, label: 'Saldo inicial'),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, key: const Key('error-cuenta'), style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 20),
              FilledButton(
                key: const Key('guardar-cuenta'),
                onPressed: _busy ? null : () => _save(account),
                child: const Text('Guardar cambios'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
