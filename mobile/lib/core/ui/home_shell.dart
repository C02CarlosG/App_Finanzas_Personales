import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../features/sync/presentation/sync_banner.dart';
import '../config/app_config.dart';

/// Barra de navegación inferior (spec 5.1): Inicio, Bancos, Categorías, Reportes, Perfil.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key, required this.shell});

  final StatefulNavigationShell shell;

  static const destinations = [
    NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Inicio'),
    NavigationDestination(
        icon: Icon(Icons.account_balance_outlined), selectedIcon: Icon(Icons.account_balance), label: 'Bancos'),
    NavigationDestination(icon: Icon(Icons.category_outlined), selectedIcon: Icon(Icons.category), label: 'Categorías'),
    NavigationDestination(
        icon: Icon(Icons.bar_chart_outlined), selectedIcon: Icon(Icons.bar_chart), label: 'Reportes'),
    NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Perfil'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: shell,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (AppConfig.demoMode)
            Material(
              key: const Key('banner-demo'),
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(children: [
                  Icon(Icons.science_outlined, size: 16),
                  SizedBox(width: 8),
                  Expanded(child: Text('MODO DEMO · datos de ejemplo, sin servidor', style: TextStyle(fontSize: 12))),
                ]),
              ),
            ),
          const SyncBanner(),
          NavigationBar(
            selectedIndex: shell.currentIndex,
            destinations: destinations,
            // Tocar la pestaña activa vuelve a su raíz.
            onDestinationSelected: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
          ),
        ],
      ),
    );
  }
}
