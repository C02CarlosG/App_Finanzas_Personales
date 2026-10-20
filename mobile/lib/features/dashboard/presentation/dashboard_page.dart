import 'package:flutter/material.dart';

import '../../../core/money/money.dart';

/// Inicio (spec 5.2). Estructura final de la pantalla; los datos reales llegan en el Paso 4.
class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Inicio')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: theme.colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Saldo total', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(Money.zero.format(),
                      key: const Key('saldo-total'), style: theme.textTheme.displaySmall),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _soon(context),
                  icon: const Icon(Icons.add),
                  label: const Text('Agregar ingreso'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () => _soon(context),
                  icon: const Icon(Icons.remove),
                  label: const Text('Agregar gasto'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const _Section(title: 'Últimas transacciones', empty: 'Aún no hay movimientos'),
          const SizedBox(height: 16),
          const _Section(title: 'Suscripciones y pagos próximos', empty: 'Nada pendiente'),
        ],
      ),
    );
  }

  void _soon(BuildContext context) => ScaffoldMessenger.of(context)
      .showSnackBar(const SnackBar(content: Text('Disponible en el Paso 4')));
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.empty});

  final String title;
  final String empty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(empty, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline)),
      ],
    );
  }
}
