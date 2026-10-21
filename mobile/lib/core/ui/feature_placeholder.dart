import 'package:flutter/material.dart';

/// Pantalla provisional de una sección que se construye en un paso posterior.
class FeaturePlaceholder extends StatelessWidget {
  const FeaturePlaceholder({
    super.key,
    required this.title,
    required this.icon,
    required this.description,
    required this.plannedIn,
    this.items = const [],
  });

  final String title;
  final IconData icon;
  final String description;
  final String plannedIn;
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Icon(icon, size: 64, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text(description, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          for (final item in items)
            ListTile(dense: true, leading: const Icon(Icons.radio_button_unchecked), title: Text(item)),
          const SizedBox(height: 16),
          Center(child: Chip(label: Text('Pendiente: $plannedIn'))),
        ],
      ),
    );
  }
}
