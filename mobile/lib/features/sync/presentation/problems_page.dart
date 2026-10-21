import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/db/app_database.dart';
import '../../../core/db/queries.dart';
import '../../../core/providers.dart';
import 'sync_messages.dart';

/// Cambios que el servidor rechazó o que no se han podido enviar. El usuario los revisa o elimina.
class ProblemsPage extends ConsumerWidget {
  const ProblemsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(outboxProblemsProvider).value ?? const <OutboxEntry>[];
    return Scaffold(
      appBar: AppBar(title: const Text('Problemas de sincronización')),
      body: entries.isEmpty
          ? const Center(key: Key('sin-problemas'), child: Text('Todo en orden'))
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: entries.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, i) => _ProblemTile(entry: entries[i]),
            ),
    );
  }
}

class _ProblemTile extends ConsumerWidget {
  const _ProblemTile({required this.entry});

  final OutboxEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(databaseProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          FutureBuilder<String>(
            future: db?.describeOutboxEntry(entry),
            builder: (_, snap) => Text(snap.data ?? '…', style: Theme.of(context).textTheme.titleSmall),
          ),
          const SizedBox(height: 6),
          Text(syncErrorMessage(entry.lastError, blocked: entry.blocked)),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton.icon(
              key: Key('eliminar-${entry.recordId}'),
              onPressed: () => _confirmDelete(context, ref),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Eliminar'),
            ),
          ]),
        ]),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Eliminar este cambio?'),
        content: const Text('Se descarta el cambio que no se pudo enviar.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Eliminar')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(localStoreProvider)?.delete(entry.entity, entry.recordId);
  }
}
