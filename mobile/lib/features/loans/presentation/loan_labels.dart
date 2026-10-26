import '../../../core/db/queries_fase2.dart';
import '../../../core/format/dates.dart';

/// "Te debe" / "Le debes" según el sentido del préstamo.
String loanDirectionLabel(LoanView l) => l.iOwe ? 'Le debes' : 'Te debe';

/// Verbo del abono: cobrar lo que te deben, pagar lo que debes.
String loanPaymentLabel(LoanView l) => l.iOwe ? 'pago' : 'cobro';

/// Texto del plazo: "Sin plazo", "Plazo: 31 dic 2026" o "Vencido el 31 dic 2026" (en rojo en la pantalla).
({String text, bool overdue}) loanDueInfo(LoanView l, DateTime today) {
  final due = l.dueDate;
  if (due == null) return (text: 'Sin plazo', overdue: false);
  final overdue = !l.isPaid && parseIsoDate(due).isBefore(today);
  return (text: overdue ? 'Vencido el ${formatDate(due)}' : 'Plazo: ${formatDate(due)}', overdue: overdue);
}
