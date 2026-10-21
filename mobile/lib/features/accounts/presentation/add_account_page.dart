import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/data/validation_exception.dart';
import '../../../core/money/money.dart';
import '../../../core/ui/money_form_field.dart';
import 'bank_avatar.dart';

/// Agregar cuenta (spec 5.5): banco (selector visual + saldo inicial + débito/crédito opcional) o efectivo.
/// Al guardar devuelve el id de la cuenta creada (para el formulario de movimientos, spec 5.3).
class AddAccountPage extends ConsumerStatefulWidget {
  const AddAccountPage({super.key});

  @override
  ConsumerState<AddAccountPage> createState() => _AddAccountPageState();
}

class _AddAccountPageState extends ConsumerState<AddAccountPage> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _balance = TextEditingController(text: '0');
  bool _bank = true;
  String? _bankId;
  String? _cardType; // null = sin especificar
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _balance.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_bank && _bankId == null) {
      setState(() => _error = 'Elige un banco de la lista');
      return;
    }
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final repo = ref.read(accountsRepositoryProvider);
    final balance = MoneyFormField.read(_balance) ?? Money.zero;
    try {
      final id = _bank
          ? await repo.createBankAccount(bankId: _bankId!, name: _name.text, cardType: _cardType, initialBalance: balance)
          : await repo.createCashAccount(name: _name.text, initialBalance: balance);
      if (mounted) context.pop(id);
    } on ValidationException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final banks = ref.watch(banksProvider).value ?? const [];
    final theme = Theme.of(context);
    final selected = banks.where((b) => b.id == _bankId).firstOrNull;

    return Scaffold(
      appBar: AppBar(title: const Text('Agregar cuenta')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SegmentedButton<bool>(
                key: const Key('tipo-cuenta'),
                segments: const [
                  ButtonSegment(value: true, label: Text('Banco'), icon: Icon(Icons.account_balance)),
                  ButtonSegment(value: false, label: Text('Efectivo'), icon: Icon(Icons.payments_outlined)),
                ],
                selected: {_bank},
                onSelectionChanged: (s) => setState(() {
                  _bank = s.first;
                  _error = null;
                }),
              ),
              const SizedBox(height: 16),
              if (_bank) ...[
                Text('Elige tu banco', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                if (banks.isEmpty)
                  const Text(
                    'Aún no se descarga el catálogo de bancos. Conéctate a internet para sincronizar y vuelve a intentar.',
                    key: Key('sin-catalogo-bancos'),
                  )
                else
                  GridView.count(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisCount: 4,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 0.82,
                    children: [
                      for (final b in banks)
                        _BankTile(
                          key: Key('banco-${b.logoKey}'),
                          name: b.name,
                          logoKey: b.logoKey,
                          selected: b.id == _bankId,
                          onTap: () => setState(() {
                            _bankId = b.id;
                            _error = null;
                          }),
                        ),
                    ],
                  ),
                const SizedBox(height: 16),
              ],
              TextFormField(
                key: const Key('campo-nombre-cuenta'),
                controller: _name,
                decoration: InputDecoration(
                  labelText: 'Nombre (opcional)',
                  hintText: _bank ? (selected?.name ?? 'Nombre del banco') : 'Efectivo',
                ),
                maxLength: 100,
              ),
              if (_bank) ...[
                const SizedBox(height: 4),
                Text('Tipo de cuenta (opcional)', style: theme.textTheme.bodySmall),
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
                onPressed: _busy ? null : _save,
                child: const Text('Guardar'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BankTile extends StatelessWidget {
  const _BankTile({super.key, required this.name, required this.logoKey, required this.selected, required this.onTap});

  final String name;
  final String logoKey;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? scheme.primary : scheme.outlineVariant, width: selected ? 2.5 : 1),
          color: selected ? scheme.primaryContainer.withValues(alpha: 0.5) : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            BankAvatar(name: name, logoKey: logoKey, size: 40),
            const SizedBox(height: 4),
            Text(name, maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
