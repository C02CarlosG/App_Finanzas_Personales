import 'package:flutter/material.dart';

import '../format/dates.dart';

/// Selector de mes con flechas ("octubre 2026"). Las claves llevan [keyPrefix] para no repetirse entre pantallas.
class MonthNavigator extends StatelessWidget {
  const MonthNavigator({super.key, required this.year, required this.month, required this.onChanged, this.keyPrefix = 'mes'});

  final int year;
  final int month;
  final void Function(int year, int month) onChanged;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      IconButton(
        key: Key('$keyPrefix-anterior'),
        tooltip: 'Mes anterior',
        icon: const Icon(Icons.chevron_left),
        onPressed: () {
          final p = previousMonth(year, month);
          onChanged(p.year, p.month);
        },
      ),
      Expanded(
        child: Text(monthLabel(year, month), key: Key('$keyPrefix-etiqueta'), textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
      ),
      IconButton(
        key: Key('$keyPrefix-siguiente'),
        tooltip: 'Mes siguiente',
        icon: const Icon(Icons.chevron_right),
        onPressed: () {
          final n = nextMonth(year, month);
          onChanged(n.year, n.month);
        },
      ),
    ]);
  }
}
