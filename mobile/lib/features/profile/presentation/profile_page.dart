import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/data/data_providers.dart';
import '../../../core/providers.dart';

class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final pending = ref.read(pendingCountProvider).value ?? 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('dialogo-cerrar-sesion'),
        title: const Text('¿Cerrar sesión?'),
        content: Text(pending > 0
            ? 'Tienes $pending ${pending == 1 ? 'cambio' : 'cambios'} sin enviar al servidor. '
                'Se quedan guardados en este dispositivo y se enviarán cuando vuelvas a iniciar sesión con esta cuenta. '
                'Si desinstalas la app antes, se perderán.'
            : 'Tus datos siguen guardados en este dispositivo y en el servidor.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(key: const Key('confirmar-cerrar-sesion'), onPressed: () => Navigator.pop(context, true), child: const Text('Cerrar sesión')),
        ],
      ),
    );
    if (ok == true) await ref.read(authControllerProvider.notifier).logout();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(authControllerProvider).value;
    return Scaffold(
      appBar: AppBar(title: const Text('Perfil')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            leading: const CircleAvatar(child: Icon(Icons.person)),
            title: Text(session?.name ?? ''),
            subtitle: Text(session?.email ?? ''),
          ),
          // En modo demo no hay sesión real: cerrarla dejaría la app sin base local.
          if (!AppConfig.demoMode) ...[
            const Divider(),
            ListTile(
              key: const Key('cerrar-sesion'),
              leading: const Icon(Icons.logout),
              title: const Text('Cerrar sesión'),
              onTap: () => _confirmLogout(context, ref),
            ),
          ],
        ],
      ),
    );
  }
}
