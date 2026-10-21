import 'package:flutter/material.dart';

import '../../../core/ui/feature_placeholder.dart';

class ReportsPage extends StatelessWidget {
  const ReportsPage({super.key});

  @override
  Widget build(BuildContext context) => const FeaturePlaceholder(
        title: 'Reportes',
        icon: Icons.bar_chart,
        description: 'Ingresos contra gastos, desglose por categoría y tendencia.',
        plannedIn: 'Paso 6',
        items: ['Ingresos vs. gastos del mes', 'Pastel por categoría', 'Tendencia de 3 meses', 'Presupuestos y alertas'],
      );
}
