import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../money/money.dart';
import '../money/money_input.dart';

/// Campo de monto en pesos: teclado decimal, acepta `$` y comas, valida hasta 2 decimales.
class MoneyFormField extends StatelessWidget {
  const MoneyFormField({
    super.key,
    required this.controller,
    this.label = 'Monto',
    this.positiveOnly = false,
    this.allowEmpty = false,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String label;

  /// Los movimientos exigen monto > 0; el saldo inicial de una cuenta puede ser cero o negativo.
  final bool positiveOnly;
  final bool allowEmpty;
  final bool autofocus;

  /// Valor del texto (o `null` si está vacío o es inválido).
  static Money? read(TextEditingController c) => parseMoneyInput(c.text);

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      autofocus: autofocus,
      decoration: InputDecoration(labelText: label, prefixText: r'$ '),
      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\-\s$]'))],
      validator: (v) {
        if (v == null || v.trim().isEmpty) return allowEmpty ? null : 'Escribe un monto';
        final m = parseMoneyInput(v);
        if (m == null) return 'Monto inválido (máximo 2 decimales)';
        if (positiveOnly && m.cents <= 0) return 'El monto debe ser mayor a 0';
        return null;
      },
    );
  }
}
