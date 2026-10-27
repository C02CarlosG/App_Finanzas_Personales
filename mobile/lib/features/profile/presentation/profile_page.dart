import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/data/data_providers.dart';
import '../../../core/providers.dart';
import 'action_dialog.dart';

String planLabel(String plan) => plan == 'premium' ? 'Premium' : 'Gratuito';

class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key});

  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage> {
  @override
  void initState() {
    super.initState();
    // Pone al día nombre, correo y plan si cambiaron en otro dispositivo; sin conexión no pasa nada.
    if (!AppConfig.demoMode) Future.microtask(() => ref.read(authControllerProvider.notifier).refreshProfile());
  }

  AuthController get _auth => ref.read(authControllerProvider.notifier);

  void _toast(String message) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), key: const Key('aviso-perfil')));

  Future<void> _editName() async {
    final current = ref.read(authControllerProvider).value?.name ?? '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => ActionDialog(
        title: 'Cambiar nombre',
        submitLabel: 'Guardar',
        submitKey: const Key('guardar-nombre'),
        fields: [
          ActionField(
            key: const Key('campo-nombre-perfil'),
            label: 'Nombre',
            initial: current,
            validator: (v, _) => v.trim().isEmpty ? 'Escribe tu nombre' : (v.trim().length > 100 ? 'Máximo 100 caracteres' : null),
          ),
        ],
        onSubmit: (values) => _auth.updateName(values[0].trim()),
      ),
    );
    if (ok == true && mounted) _toast('Nombre actualizado');
  }

  Future<void> _changeEmail() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => ActionDialog(
        title: 'Cambiar correo',
        intro: 'Con este correo inicias sesión. Por seguridad, confirma tu contraseña.',
        submitLabel: 'Guardar',
        submitKey: const Key('guardar-correo'),
        fields: [
          ActionField(
            key: const Key('campo-correo-nuevo'),
            label: 'Correo nuevo',
            keyboard: TextInputType.emailAddress,
            validator: (v, _) => RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v.trim()) ? null : 'Correo inválido',
          ),
          ActionField(
            key: const Key('campo-contrasena-actual'),
            label: 'Contraseña actual',
            obscure: true,
            validator: (v, _) => v.isEmpty ? 'Escribe tu contraseña' : null,
          ),
        ],
        onSubmit: (values) => _auth.changeEmail(email: values[0].trim(), password: values[1]),
      ),
    );
    if (ok == true && mounted) _toast('Correo actualizado');
  }

  Future<void> _changePassword() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => ActionDialog(
        title: 'Cambiar contraseña',
        intro: 'Se cerrará la sesión en tus otros dispositivos; en este seguirás dentro.',
        submitLabel: 'Cambiar',
        submitKey: const Key('guardar-contrasena'),
        fields: [
          ActionField(
            key: const Key('campo-contrasena-actual'),
            label: 'Contraseña actual',
            obscure: true,
            validator: (v, _) => v.isEmpty ? 'Escribe tu contraseña actual' : null,
          ),
          ActionField(
            key: const Key('campo-contrasena-nueva'),
            label: 'Contraseña nueva',
            obscure: true,
            validator: (v, all) => v.length < 8 ? 'Mínimo 8 caracteres' : (v == all[0] ? 'Debe ser distinta de la actual' : null),
          ),
          ActionField(
            key: const Key('campo-contrasena-confirmar'),
            label: 'Repite la contraseña nueva',
            obscure: true,
            validator: (v, all) => v != all[1] ? 'No coincide' : null,
          ),
        ],
        onSubmit: (values) => _auth.changePassword(current: values[0], next: values[1]),
      ),
    );
    if (ok == true && mounted) _toast('Contraseña actualizada');
  }

  Future<void> _confirmLogout() async {
    final pending = ref.read(pendingCountProvider).value ?? 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('dialogo-cerrar-sesion'),
        title: const Text('¿Cerrar sesión?'),
        scrollable: true,
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
    if (ok == true) await _auth.logout();
  }

  Future<void> _logoutEverywhere() async {
    final pending = ref.read(pendingCountProvider).value ?? 0;
    await showDialog<bool>(
      context: context,
      builder: (_) => ActionDialog(
        key: const Key('dialogo-cerrar-todos'),
        title: 'Cerrar sesión en todos los dispositivos',
        intro: 'Se cerrará tu sesión aquí y en cualquier otro teléfono donde hayas entrado; '
            'en cada uno tendrás que volver a iniciar sesión. Necesita conexión a internet.'
            '${pending > 0 ? ' Tienes $pending ${pending == 1 ? 'cambio' : 'cambios'} sin enviar: se quedan guardados en este dispositivo.' : ''}',
        submitLabel: 'Cerrar todas',
        submitKey: const Key('confirmar-cerrar-todos'),
        onSubmit: (_) => _auth.logoutEverywhere(),
      ),
    );
  }

  Future<void> _deleteAccount() async {
    await showDialog<bool>(
      context: context,
      builder: (_) => ActionDialog(
        key: const Key('dialogo-eliminar-cuenta'),
        title: 'Eliminar mi cuenta',
        intro: 'Se borrarán para siempre tu cuenta y todos tus datos (bancos, movimientos, préstamos, tarjetas, '
            'suscripciones y presupuestos), en el servidor y en este dispositivo. No se puede deshacer. '
            'Necesita conexión a internet.',
        submitLabel: 'Eliminar para siempre',
        submitKey: const Key('confirmar-eliminar-cuenta'),
        destructive: true,
        fields: [
          ActionField(
            key: const Key('campo-contrasena-eliminar'),
            label: 'Tu contraseña',
            obscure: true,
            validator: (v, _) => v.isEmpty ? 'Escribe tu contraseña para confirmar' : null,
          ),
        ],
        onSubmit: (values) => _auth.deleteAccount(values[0]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(authControllerProvider).value;
    final theme = Theme.of(context);
    // En modo demo no hay sesión ni servidor: nada de esto aplica.
    final online = !AppConfig.demoMode;
    return Scaffold(
      appBar: AppBar(title: const Text('Perfil')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            leading: const CircleAvatar(child: Icon(Icons.person)),
            title: Text(session?.name ?? '', key: const Key('perfil-nombre-actual')),
            subtitle: Text(session?.email ?? '', key: const Key('perfil-correo-actual')),
          ),
          const Divider(),
          if (online) ...[
            ListTile(
              key: const Key('perfil-nombre'),
              leading: const Icon(Icons.badge_outlined),
              title: const Text('Cambiar nombre'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _editName,
            ),
            ListTile(
              key: const Key('perfil-correo'),
              leading: const Icon(Icons.mail_outline),
              title: const Text('Cambiar correo'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _changeEmail,
            ),
            ListTile(
              key: const Key('perfil-contrasena'),
              leading: const Icon(Icons.lock_outline),
              title: const Text('Cambiar contraseña'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _changePassword,
            ),
          ],
          const ListTile(
            key: Key('perfil-moneda'),
            leading: Icon(Icons.payments_outlined),
            title: Text('Moneda'),
            subtitle: Text('Peso mexicano (MXN)'),
          ),
          ListTile(
            key: const Key('perfil-plan'),
            leading: const Icon(Icons.workspace_premium_outlined),
            title: const Text('Plan'),
            subtitle: Text(session?.plan == 'premium'
                ? 'Premium'
                : 'Gratuito · incluye todas las funciones por ahora'),
          ),
          if (online) ...[
            const Divider(),
            ListTile(
              key: const Key('cerrar-sesion'),
              leading: const Icon(Icons.logout),
              title: const Text('Cerrar sesión'),
              onTap: _confirmLogout,
            ),
            ListTile(
              key: const Key('cerrar-sesion-todos'),
              leading: const Icon(Icons.devices_other),
              title: const Text('Cerrar sesión en todos los dispositivos'),
              onTap: _logoutEverywhere,
            ),
            const Divider(),
            ListTile(
              key: const Key('eliminar-cuenta'),
              leading: Icon(Icons.delete_forever_outlined, color: theme.colorScheme.error),
              title: Text('Eliminar mi cuenta', style: TextStyle(color: theme.colorScheme.error)),
              onTap: _deleteAccount,
            ),
          ],
        ],
      ),
    );
  }
}
