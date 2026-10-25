import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import 'app.dart';
import 'core/config/app_config.dart';
import 'core/db/app_database.dart';
import 'core/demo/demo_seed.dart';
import 'core/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Modo demo (solo desarrollo): base local con datos de ejemplo y sin servidor ni sync.
  final overrides = <Override>[];
  if (AppConfig.demoMode) {
    final db = AppDatabase.forUser('demo');
    await seedDemoData(db);
    overrides.add(databaseProvider.overrideWithValue(db));
  }
  runApp(ProviderScope(overrides: overrides, child: const FinanzasApp()));
}
