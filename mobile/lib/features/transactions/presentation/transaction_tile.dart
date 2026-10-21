import 'package:flutter/material.dart';

import '../../../core/db/queries.dart';
import '../../../core/format/dates.dart';
import '../../categories/presentation/category_editor.dart';

/// Renglón de un ingreso o gasto: categoría (con su color), descripción, cuenta, fecha e importe con signo.
class TransactionTile extends StatelessWidget {
  const TransactionTile({super.key, required this.tx, this.onTap, this.showYear = false});

  final TransactionView tx;
  final VoidCallback? onTap;
  final bool showYear;

  static const incomeColor = Color(0xFF2E7D32);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = (tx.description?.isNotEmpty ?? false) ? tx.description! : (tx.categoryName ?? 'Sin categoría');
    final person = (tx.counterparty?.isNotEmpty ?? false) ? ' · ${tx.counterparty}' : '';
    // La fecha va primero: si el texto se recorta, lo último en perderse es la cuenta, no la fecha.
    final subtitle = [
      showYear ? formatDate(tx.occurredOn) : formatDateShort(tx.occurredOn),
      tx.categoryName ?? 'Sin categoría',
      tx.accountName ?? 'Sin cuenta',
    ].join(' · ');
    final amountColor = tx.isIncome ? (theme.brightness == Brightness.dark ? const Color(0xFF81C784) : incomeColor) : scheme.error;

    return ListTile(
      key: Key('movimiento-${tx.id}'),
      onTap: onTap,
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: categoryColorOf(tx.categoryColor, scheme.outlineVariant),
        child: Icon(tx.isIncome ? Icons.south_west : Icons.north_east, size: 18, color: Colors.white),
      ),
      title: Text('$title$person', maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (tx.isOrphan)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Icon(Icons.warning_amber_rounded, size: 18, color: scheme.tertiary, semanticLabel: 'Falta la cuenta o la categoría'),
          ),
        if (tx.pending)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Icon(Icons.cloud_upload_outlined, size: 16, color: scheme.outline, semanticLabel: 'Pendiente de enviar'),
          ),
        Text(
          '${tx.isIncome ? '+' : '-'}${tx.amount.format()}',
          style: theme.textTheme.titleSmall?.copyWith(color: amountColor, fontWeight: FontWeight.w600),
        ),
      ]),
    );
  }
}
