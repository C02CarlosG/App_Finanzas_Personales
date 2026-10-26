import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/data/validation_exception.dart';
import '../../../core/db/queries_fase2.dart';
import '../../../core/format/dates.dart';
import '../../../core/money/money.dart';
import '../../../core/ui/money_form_field.dart';
import '../../../core/ui/pickers.dart';
import 'loan_labels.dart';

/// Abonar: cobro (te deben) o pago (debes). Mueve el saldo de la cuenta elegida.
Future<void> showLoanPaymentSheet(BuildContext context, LoanView loan) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _LoanMoneySheet(loan: loan, mode: _Mode.payment),
    );

/// Aumentar el monto (la persona presta más). No mueve saldos.
Future<void> showLoanIncreaseSheet(BuildContext context, LoanView loan) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _LoanMoneySheet(loan: loan, mode: _Mode.increase),
    );

/// Marcar como pagado: si queda pendiente, registra un último abono por ese saldo en la cuenta elegida.
Future<void> showMarkPaidSheet(BuildContext context, LoanView loan) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _LoanMoneySheet(loan: loan, mode: _Mode.settle),
    );

enum _Mode { payment, increase, settle }

class _LoanMoneySheet extends ConsumerStatefulWidget {
  const _LoanMoneySheet({required this.loan, required this.mode});

  final LoanView loan;
  final _Mode mode;

  @override
  ConsumerState<_LoanMoneySheet> createState() => _LoanMoneySheetState();
}

class _LoanMoneySheetState extends ConsumerState<_LoanMoneySheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _amount;
  String? _accountId;
  late String _date;
  bool _busy = false;
  String? _error;

  LoanView get _loan => widget.loan;
  bool get _needsAccount => widget.mode != _Mode.increase && !(widget.mode == _Mode.settle && _loan.remaining.cents == 0);

  @override
  void initState() {
    super.initState();
    _date = isoDate(ref.read(todayProvider));
    _amount = TextEditingController(text: widget.mode == _Mode.payment ? _loan.remaining.toApiString() : '');
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
      final repo = ref.read(loansRepositoryProvider);
      switch (widget.mode) {
        case _Mode.payment:
          await repo.addPayment(_loan.id, amount: MoneyFormField.read(_amount) ?? Money.zero, accountId: _accountId!, occurredOn: _date);
        case _Mode.increase:
          await repo.addIncrease(_loan.id, amount: MoneyFormField.read(_amount) ?? Money.zero, occurredOn: _date);
        case _Mode.settle:
          await repo.markPaid(_loan.id, accountId: _accountId, occurredOn: _date);
      }
      if (mounted) Navigator.of(context).pop();
    } on ValidationException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final verb = loanPaymentLabel(_loan); // cobro | pago
    final title = switch (widget.mode) {
      _Mode.payment => _loan.iOwe ? 'Registrar pago' : 'Registrar cobro',
      _Mode.increase => 'Aumentar monto',
      _Mode.settle => 'Marcar como pagado',
    };
    final settleInfo = _loan.remaining.cents > 0
        ? 'Quedan ${_loan.remaining.format()} por ${_loan.iOwe ? 'pagar' : 'cobrar'}. Se registrará un último $verb por ese monto en la cuenta que elijas.'
        : 'Ya no queda saldo pendiente: solo se marcará como pagado.';

    return SheetBody(
      title: title,
      children: [
        Form(
          key: _formKey,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (widget.mode == _Mode.settle) ...[
              Text(settleInfo, key: const Key('texto-liquidar')),
              const SizedBox(height: 8),
            ] else
              MoneyFormField(key: const Key('campo-monto-movimiento'), controller: _amount, positiveOnly: true, autofocus: true),
            if (_needsAccount) ...[
              const SizedBox(height: 8),
              AccountDropdown(
                key: const Key('campo-cuenta-movimiento'),
                label: _loan.iOwe ? 'Cuenta de la que pagas' : 'Cuenta donde recibes',
                value: _accountId,
                onChanged: (v) => setState(() => _accountId = v),
              ),
            ],
            DateTile(label: 'Fecha', value: _date, onChanged: (v) => setState(() => _date = v ?? _date)),
            if (widget.mode == _Mode.increase)
              Text('Aumentar el monto no mueve el saldo de tus cuentas.', style: theme.textTheme.bodySmall),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, key: const Key('error-movimiento-prestamo'), style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 12),
            FilledButton(
              key: const Key('confirmar-movimiento-prestamo'),
              onPressed: _busy ? null : _submit,
              child: Text(switch (widget.mode) {
                _Mode.payment => _loan.iOwe ? 'Registrar pago' : 'Registrar cobro',
                _Mode.increase => 'Aumentar',
                _Mode.settle => 'Marcar como pagado',
              }),
            ),
          ]),
        ),
      ],
    );
  }
}
