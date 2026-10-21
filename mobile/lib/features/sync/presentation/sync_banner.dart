import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/router/app_router.dart';
import '../../../core/sync/sync_controller.dart';

/// Franja sobre la barra inferior con el estado del sync. Una sola a la vez, por prioridad:
/// sesión expirada > cambios con problemas > sin conexión / por enviar.
class SyncBanner extends ConsumerWidget {
  const SyncBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncControllerProvider);
    final problems = ref.watch(outboxProblemsProvider).value?.length ?? 0;
    final pending = ref.watch(pendingCountProvider).value ?? 0;
    final scheme = Theme.of(context).colorScheme;

    Widget bar(Key key, Color bg, Color fg, IconData icon, String text, {String? action, VoidCallback? onAction}) {
      return Material(
        key: key,
        color: bg,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(children: [
            Icon(icon, size: 18, color: fg),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: TextStyle(color: fg, fontSize: 13))),
            if (action != null) TextButton(onPressed: onAction, child: Text(action)),
          ]),
        ),
      );
    }

    if (status.phase == SyncPhase.sessionExpired) {
      return bar(
        const Key('banner-sesion-expirada'),
        scheme.errorContainer,
        scheme.onErrorContainer,
        Icons.lock_outline,
        'Tu sesión expiró. Tus datos siguen guardados en este dispositivo.',
        action: 'Iniciar sesión',
        onAction: () => context.push(AppRoutes.reauth),
      );
    }
    if (problems > 0) {
      return bar(
        const Key('banner-problemas'),
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
        Icons.warning_amber_rounded,
        problems == 1 ? '1 cambio con problemas' : '$problems cambios con problemas',
        action: 'Revisar',
        onAction: () => context.push(AppRoutes.problems),
      );
    }
    if (status.phase == SyncPhase.offline || (status.phase == SyncPhase.error && pending > 0)) {
      final suffix = pending > 0 ? ' · ${pending == 1 ? '1 cambio por enviar' : '$pending cambios por enviar'}' : '';
      return bar(
        const Key('banner-offline'),
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
        Icons.cloud_off,
        'Sin conexión$suffix',
      );
    }
    return const SizedBox.shrink();
  }
}
