import 'package:flutter/material.dart';

import '../../../core/ui/feature_placeholder.dart';

class CategoriesPage extends StatelessWidget {
  const CategoriesPage({super.key});

  @override
  Widget build(BuildContext context) => const FeaturePlaceholder(
        title: 'Categorías',
        icon: Icons.category,
        description: 'Categorías de ingresos y gastos, editables por ti.',
        plannedIn: 'Paso 4',
        items: ['Crear, editar y eliminar categorías', 'Categorías sembradas al registrarte'],
      );
}
