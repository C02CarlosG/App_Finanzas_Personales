import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/data/validation_exception.dart';
import '../../../core/db/queries_fase2.dart';
import '../../../core/format/dates.dart';
import '../../../core/money/money.dart';
import '../../../core/router/app_router.dart';
import '../../../core/ui/fit_trailing.dart';
import '../../../core/ui/money_form_field.dart';
import '../../../core/ui/pickers.dart';
import 'cards_list.dart';

/// Detalle de una tarjeta: saldo pendiente, vencimiento, historial de pagos y "Registrar pago".
class CardDetailPage extends ConsumerWidget {
  const CardDetailPage({super.key, required this.cardId});

  final String cardId;

  Future<void> _delete(BuildContext context, WidgetRef ref, CreditCardView card) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Eliminar esta tarjeta?'),
        content: const Text('Se eliminará la tarjeta y su historial de pagos. Los gastos que ya registraste en tus cuentas se conservan.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(key: const Key('confirmar-eliminar'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Eliminar')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(creditCardsRepositoryProvider).delete(card.id);
      if (context.mounted) context.pop();
    } on ValidationException catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _undo(BuildContext context, WidgetRef ref, CardPaymentView p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Deshacer este pago?'),
        content: Text('Se eliminará el pago de ${p.amount.format()} y su gasto en tu cuenta, y el monto volverá al saldo pendiente.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(key: const Key('confirmar-deshacer'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Deshacer')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(creditCardsRepositoryProvider).deletePayment(p.id);
    } on ValidationException catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cards = ref.watch(creditCardsProvider);
    final card = cards.value?.where((c) => c.id == cardId).firstOrNull;
    final payments = ref.watch(cardPaymentsProvider(cardId)).value ?? const [];
    final today = ref.watch(todayProvider);
    final theme = Theme.of(context);

    if (card == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Tarjeta')),
        body: Center(child: cards.isLoading ? const CircularProgressIndicator() : const Text('La tarjeta ya no existe')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(card.name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(key: const Key('editar-tarjeta'), tooltip: 'Editar', icon: const Icon(Icons.edit_outlined), onPressed: () => context.push(AppRoutes.cardEdit(card.id))),
          IconButton(key: const Key('eliminar-tarjeta'), tooltip: 'Eliminar', icon: const Icon(Icons.delete_outline), onPressed: () => _delete(context, ref, card)),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              color: theme.colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Saldo pendiente', style: theme.textTheme.labelLarge),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(card.pendingBalance.format(), key: const Key('saldo-tarjeta'), style: theme.textTheme.displaySmall),
                  ),
                  const SizedBox(height: 4),
                  Text(cardDueText(card, today), key: const Key('vencimiento-tarjeta')),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('pagar-tarjeta'),
              onPressed: card.pendingBalance.cents > 0 ? () => _showPaymentSheet(context, card) : null,
              icon: const Icon(Icons.payments_outlined),
              label: const Text('Registrar pago'),
            ),
            if (card.pendingBalance.cents == 0)
              const Padding(padding: EdgeInsets.only(top: 4), child: Text('Sin saldo pendiente. Si ya llegó tu estado de cuenta, actualiza el saldo con el lápiz.')),
            const SizedBox(height: 16),
            Text('Pagos', style: theme.textTheme.titleMedium),
            if (payments.isEmpty)
              const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Text('Aún no hay pagos registrados.', key: Key('sin-pagos-tarjeta')))
            else
              for (final p in payments)
                ListTile(
                  key: Key('pago-${p.id}'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.payments_outlined),
                  title: Text(formatDate(p.paidOn)),
                  subtitle: Text(p.accountName ?? 'Sin cuenta', maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: FitTrailing(
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (p.pending)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Icon(Icons.cloud_upload_outlined, size: 16, color: theme.colorScheme.outline, semanticLabel: 'Pendiente de enviar'),
                        ),
                      Text(p.amount.format(), style: theme.textTheme.titleSmall),
                      IconButton(key: Key('deshacer-${p.id}'), tooltip: 'Deshacer', icon: const Icon(Icons.undo), onPressed: () => _undo(context, ref, p)),
                    ]),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Future<void> _showPaymentSheet(BuildContext context, CreditCardView card) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => _CardPaymentSheet(card: card),
      );
}

class _CardPaymentSheet extends ConsumerStatefulWidget {
  const _CardPaymentSheet({required this.card});

  final CreditCardView card;

  @override
  ConsumerState<_CardPaymentSheet> createState() => _CardPaymentSheetState();
}

class _CardPaymentSheetState extends ConsumerState<_CardPaymentSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _amount;
  String? _accountId;
  late String _date;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _date = isoDate(ref.read(todayProvider));
    _amount = TextEditingController(text: widget.card.pendingBalance.toApiString());
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(creditCardsRepositoryProvider).addPayment(
            widget.card.id,
            amount: MoneyFormField.read(_amount) ?? Money.zero,
            accountId: _accountId!,
            paidOn: _date,
          );
      if (mounted) Navigator.of(context).pop();
    } on ValidationException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SheetBody(
      title: 'Registrar pago',
      children: [
        Form(
          key: _formKey,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            MoneyFormField(key: const Key('campo-monto-pago'), controller: _amount, positiveOnly: true, autofocus: true),
            const SizedBox(height: 8),
            AccountDropdown(key: const Key('campo-cuenta-pago'), label: 'Cuenta desde la que pagas', value: _accountId, onChanged: (v) => setState(() => _accountId = v)),
            DateTile(label: 'Fecha', value: _date, onChanged: (v) => setState(() => _date = v ?? _date)),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, key: const Key('error-pago-tarjeta'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 12),
            FilledButton(key: const Key('confirmar-pago-tarjeta'), onPressed: _busy ? null : _submit, child: const Text('Registrar pago')),
          ]),
        ),
      ],
    );
  }
}
