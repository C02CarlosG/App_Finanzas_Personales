import 'package:flutter/foundation.dart';

/// Importe en pesos mexicanos (MXN) como centavos enteros. Nunca usa `double`.
///
/// El servidor intercambia dinero como string decimal (`"1500.50"`); aquí se
/// convierte con aritmética de enteros, sin pasar por coma flotante.
@immutable
class Money implements Comparable<Money> {
  const Money(this.cents);

  final int cents;

  static const zero = Money(0);

  // Hasta 12 enteros + 2 decimales (igual que NUMERIC(14,2) del servidor);
  // cabe en los 2^53 de un int en la web.
  static final _pattern = RegExp(r'^(-)?(\d{1,12})(?:\.(\d{1,2}))?$');

  /// Acepta `"1500"`, `"1500.5"`, `"1500.50"`, `"-3.25"`. Lanza [FormatException] si no es válido.
  factory Money.parse(String input) {
    final m = _pattern.firstMatch(input.trim());
    if (m == null) throw FormatException('Monto inválido', input);
    final whole = int.parse(m.group(2)!);
    final frac = int.parse((m.group(3) ?? '').padRight(2, '0'));
    final value = whole * 100 + frac;
    return Money(m.group(1) == null ? value : -value);
  }

  static Money? tryParse(String input) {
    try {
      return Money.parse(input);
    } on FormatException {
      return null;
    }
  }

  bool get isNegative => cents < 0;

  Money operator +(Money other) => Money(cents + other.cents);
  Money operator -(Money other) => Money(cents - other.cents);
  Money operator -() => Money(-cents);

  /// Formato del servidor: `"1500.50"`, `"-3.05"`.
  String toApiString() => '${isNegative ? '-' : ''}${_whole()}.${_fraction()}';

  /// Formato para mostrar: `$1,500.50`, `-$3.05`.
  String format({String symbol = r'$'}) =>
      '${isNegative ? '-' : ''}$symbol${_grouped(_whole())}.${_fraction()}';

  String _whole() => (cents.abs() ~/ 100).toString();
  String _fraction() => (cents.abs() % 100).toString().padLeft(2, '0');

  static String _grouped(String digits) {
    final out = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return out.toString();
  }

  @override
  int compareTo(Money other) => cents.compareTo(other.cents);

  @override
  bool operator ==(Object other) => other is Money && other.cents == cents;

  @override
  int get hashCode => cents.hashCode;

  @override
  String toString() => 'Money(${toApiString()})';
}
