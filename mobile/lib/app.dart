import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router/app_router.dart';

class FinanzasApp extends ConsumerWidget {
  const FinanzasApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
