import 'money.dart';

/// Interpreta lo que el usuario escribe en un campo de monto: acepta `$`, espacios y comas
/// como separador de miles (`1,500.50`); una coma sola seguida de 1–2 dígitos se toma como
/// decimal (`12,5` → 12.50). Devuelve `null` si no es un monto válido (máx. 2 decimales).
Money? parseMoneyInput(String raw) {
  var s = raw.trim().replaceAll(RegExp(r'[\s$]'), '');
  if (s.isEmpty) return null;
  if (RegExp(r'^-?\d{1,3}(,\d{3})+(\.\d+)?$').hasMatch(s)) {
    s = s.replaceAll(',', '');
  } else if (RegExp(r'^-?\d+,\d{1,2}$').hasMatch(s)) {
    s = s.replaceAll(',', '.');
  }
  return Money.tryParse(s);
}
