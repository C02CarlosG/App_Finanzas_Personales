import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router/app_router.dart';
import 'core/sync/sync_controller.dart';

class FinanzasApp extends ConsumerStatefulWidget {
  const FinanzasApp({super.key});

  @override
  ConsumerState<FinanzasApp> createState() => _FinanzasAppState();
}

class _FinanzasAppState extends ConsumerState<FinanzasApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Al volver a la app se sincroniza (el motor evita ciclos simultáneos).
    _lifecycle = AppLifecycleListener(
      onResume: () => ref.read(syncControllerProvider.notifier).syncNow(),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Mantiene vivo el controlador: su arranque dispara el primer sync.
    ref.watch(syncControllerProvider);
    return MaterialApp.router(
      title: 'Finanzas Personales',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF1B7F5C), useMaterial3: true),
      darkTheme: ThemeData(
          colorSchemeSeed: const Color(0xFF1B7F5C), brightness: Brightness.dark, useMaterial3: true),
      routerConfig: ref.watch(routerProvider),
    );
  }
}
