import 'dart:math';

import 'package:drift/drift.dart';

import '../db/app_database.dart';
import '../db/local_store.dart';
import '../network/api_exception.dart';
import 'stamp.dart';
import 'sync_api.dart';
import 'sync_tables.dart';

class SyncReport {
  int pushed = 0; // cambios enviados
  int pulled = 0; // registros recibidos
  int retained = 0; // cambios que siguen pendientes tras el ciclo (con error o bloqueados)

  @override
  String toString() => 'SyncReport(pushed: $pushed, pulled: $pulled, retained: $retained)';
}

/// Cliente del protocolo de docs/sync.md: **push y luego pull**, un solo ciclo a la vez.
class SyncEngine {
  SyncEngine({
    required this.db,
    required this.api,
    required this.store,
    required this.clock,
    Future<void> Function(Duration)? delay,
    DateTime Function()? now,
  })  : _delay = delay ?? Future.delayed,
        _now = now ?? DateTime.now {
    _tables = {
      for (final t in allSyncTables(db)) t.entity: t,
    };
  }

  static const maxBatch = 200;
  static const _maxTransientRetries = 3;

  final AppDatabase db;
  final SyncApi api;
  final LocalStore store;
  final StampClock clock;
  final Future<void> Function(Duration) _delay;
  final DateTime Function() _now;
  late final Map<String, SyncTable> _tables;

  Future<SyncReport>? _running;

  bool get isSyncing => _running != null;

  /// Si ya hay un ciclo en curso, devuelve ese mismo (nunca dos a la vez).
  Future<SyncReport> run() => _running ??= _run().whenComplete(() => _running = null);

  Future<SyncReport> _run() async {
    final report = SyncReport();
    final saved = await db.readState('clock_offset_ms');
    if (saved != null) clock.offset = Duration(milliseconds: int.parse(saved));
    await _push(report);
    await _pull(report);
    report.retained = (await _pendingEntries(const {}, includeAll: true)).length;
    return report;
  }

  // ---------------------------------------------------------------- push

  Future<void> _push(SyncReport report) async {
    var batchSize = maxBatch;
    var transientRetries = 0;
    final seen = <String>{}; // un registro se envía una sola vez por ciclo

    while (true) {
      final pending = await _pendingEntries(seen);
      if (pending.isEmpty) return;

      final batch = pending.take(batchSize).toList();
      final sent = <(OutboxEntry, Map<String, dynamic>)>[];
      for (final entry in batch) {
        final change = await _buildChange(entry);
        if (change == null) {
          await _removeOutbox(entry.entity, entry.recordId); // el registro ya no existe localmente
          seen.add(_key(entry));
        } else {
          sent.add((entry, change));
        }
      }
      if (sent.isEmpty) continue;

      // Persistente y ANTES de enviar: si la respuesta se pierde, el registro pudo haber llegado.
      await _markMaybeSent([for (final s in sent) s.$1]);

      final Map<String, dynamic> response;
      try {
        response = await api.push([for (final s in sent) s.$2]);
      } on ApiException catch (e) {
        if (e.code == 'batch_too_slow' && batchSize > 1) {
          batchSize = max(1, batchSize ~/ 2);
          continue;
        }
        if (e.code == 'retry_later' && transientRetries < _maxTransientRetries) {
          transientRetries += 1;
          await _delay(Duration(seconds: 1 << transientRetries));
          continue;
        }
        rethrow;
      }
      transientRetries = 0;
      await _learnClockOffset(response['server_time'] as String?);

      final results = (response['results'] as List).cast<Map<String, dynamic>>();
      for (var i = 0; i < sent.length; i++) {
        seen.add(_key(sent[i].$1));
        await _applyPushResult(sent[i].$1, results[i]);
      }
      report.pushed += sent.length;
    }
  }

  String _key(OutboxEntry e) => '${e.entity}:${e.recordId}';

  /// Altas/ediciones primero (padres → hijos), luego borrados (hijos → padres).
  Future<List<OutboxEntry>> _pendingEntries(Set<String> seen, {bool includeAll = false}) async {
    final rows = await (db.select(db.syncOutbox)..where((t) => t.blocked.equals(false) | Constant(includeAll))).get();
    final entries = rows.where((e) => includeAll || !seen.contains(_key(e))).toList();
    int order(OutboxEntry e) => syncEntities.indexOf(e.entity);
    entries.sort((a, b) {
      if (a.deleted != b.deleted) return a.deleted ? 1 : -1;
      final byEntity = a.deleted ? order(b).compareTo(order(a)) : order(a).compareTo(order(b));
      return byEntity != 0 ? byEntity : a.recordId.compareTo(b.recordId);
    });
    return entries;
  }

  Future<Map<String, dynamic>?> _buildChange(OutboxEntry e) async {
    final base = {'table': e.entity, 'id': e.recordId, 'client_updated_at': e.clientUpdatedAt};
    if (e.deleted) return {...base, 'deleted': true};
    final data = await _tables[e.entity]!.dataFor(e.recordId);
    return data == null ? null : {...base, 'deleted': false, 'data': data};
  }

  Future<void> _applyPushResult(OutboxEntry sent, Map<String, dynamic> result) async {
    final status = result['status'] as String;
    final code = result['code'] as String?;
    final record = result['record'] as Map<String, dynamic>?;
    final table = _tables[sent.entity]!;

    switch (status) {
      case 'applied' || 'stale' || 'deleted':
        await _adopt(table, sent, record);
      case 'rejected':
        switch (code) {
          case 'in_use' || 'system_category':
            await _adopt(table, sent, record); // el servidor gana: el registro "resucita" localmente
          case 'duplicate_name':
            if (record != null) {
              await _adopt(table, sent, record); // renombre rechazado: se conserva la categoría
            } else {
              await _mergeDuplicateCategory(sent, result['conflicting_id'] as String);
            }
          default: // conflict u otro: se reintenta en el siguiente ciclo
            await _bumpAttempt(sent, code ?? status);
        }
      case 'invalid':
        if (code == 'invalid_reference') {
          await _bumpAttempt(sent, code!); // el padre puede estar pendiente; no se descarta
        } else {
          await _block(sent, '${code ?? 'invalid'}: ${result['message'] ?? ''}');
        }
      default:
        await _bumpAttempt(sent, 'estado desconocido: $status');
    }
  }

  /// Adopta la versión del servidor. Si el usuario volvió a editar el registro mientras
  /// el lote estaba en vuelo, **no** se sobrescribe la fila: solo se registra `updated_at`
  /// del servidor y la outbox conserva la edición más nueva (docs/sync.md §6).
  ///
  /// La comprobación y la escritura van en la **misma transacción**: así una edición del usuario
  /// no puede colarse entre la lectura de la outbox y el reemplazo de la fila.
  Future<void> _adopt(SyncTable table, OutboxEntry sent, Map<String, dynamic>? record) =>
      db.transaction(() async {
        final current = await _outbox(sent.entity, sent.recordId);
        final editedMeanwhile = current != null && current.clientUpdatedAt.compareTo(sent.clientUpdatedAt) > 0;

        if (record == null) {
          // El servidor no conoce el registro (borrado de algo que nunca subió): nada que conservar.
          if (!editedMeanwhile) {
            await table.removeLocal(sent.recordId);
            await _removeOutbox(sent.entity, sent.recordId);
          }
          return;
        }
        if (editedMeanwhile) {
          await table.markSynced(sent.recordId, record['updated_at'] as String);
          return;
        }
        await table.applyServerRecord(record);
        await _removeOutbox(sent.entity, sent.recordId);
      });

  /// `duplicate_name` sin `record` = alta rechazada: se reasignan las transacciones locales a
  /// la categoría que ya existe, se borra la local (nunca llegó al servidor) y se sale de la outbox.
  /// Si el usuario la editó (p. ej. la renombró) con el lote en vuelo, **no** se fusiona: esa edición
  /// es un cambio nuevo que se enviará en el siguiente ciclo.
  Future<void> _mergeDuplicateCategory(OutboxEntry sent, String conflictingId) => db.transaction(() async {
        final current = await _outbox(sent.entity, sent.recordId);
        if (current != null && current.clientUpdatedAt.compareTo(sent.clientUpdatedAt) > 0) return;
        final stamp = clock.stamp();
        final affected = await (db.select(db.transactions)..where((t) => t.categoryId.equals(sent.recordId))).get();
        for (final tx in affected) {
          await (db.update(db.transactions)..where((t) => t.id.equals(tx.id)))
              .write(TransactionsCompanion(categoryId: Value(conflictingId), clientUpdatedAt: Value(stamp)));
          await store.enqueue('transactions', tx.id, stamp, deleted: tx.deletedAt != null);
        }
        await _tables['categories']!.removeLocal(sent.recordId);
        await _removeOutbox(sent.entity, sent.recordId);
      });

  Future<void> _markMaybeSent(List<OutboxEntry> entries) => db.transaction(() async {
        for (final e in entries) {
          await (db.update(db.syncOutbox)
                ..where((t) => t.entity.equals(e.entity) & t.recordId.equals(e.recordId) & t.clientUpdatedAt.equals(e.clientUpdatedAt)))
              .write(const SyncOutboxCompanion(maybeSent: Value(true)));
        }
      });

  // Solo si el renglón sigue siendo el que se envió: una edición posterior es un cambio nuevo
  // y no debe heredar el error (ni quedar bloqueada) por el intento anterior.
  Future<void> _bumpAttempt(OutboxEntry e, String error) => (db.update(db.syncOutbox)
        ..where((t) => t.entity.equals(e.entity) & t.recordId.equals(e.recordId) & t.clientUpdatedAt.equals(e.clientUpdatedAt)))
      .write(SyncOutboxCompanion(attempts: Value(e.attempts + 1), lastError: Value(error)));

  Future<void> _block(OutboxEntry e, String error) => (db.update(db.syncOutbox)
        ..where((t) => t.entity.equals(e.entity) & t.recordId.equals(e.recordId) & t.clientUpdatedAt.equals(e.clientUpdatedAt)))
      .write(SyncOutboxCompanion(blocked: const Value(true), lastError: Value(error)));

  Future<OutboxEntry?> _outbox(String entity, String id) =>
      (db.select(db.syncOutbox)..where((t) => t.entity.equals(entity) & t.recordId.equals(id))).getSingleOrNull();

  Future<void> _removeOutbox(String entity, String id) =>
      (db.delete(db.syncOutbox)..where((t) => t.entity.equals(entity) & t.recordId.equals(id))).go();

  // ---------------------------------------------------------------- pull

  Future<void> _pull(SyncReport report) async {
    var cursor = await db.readState('cursor');
    while (true) {
      final res = await api.pull(cursor: cursor);
      await _learnClockOffset(res['server_time'] as String?);
      final changes = res['changes'] as Map<String, dynamic>;
      final next = res['next_cursor'] as String;

      // Una transacción local por página, con el cursor guardado en ella (docs/sync.md §6).
      await db.transaction(() async {
        for (final bank in ((changes['banks'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
          await db.into(db.banks).insertOnConflictUpdate(BanksCompanion(
            id: Value(bank['id'] as String),
            name: Value(bank['name'] as String),
            logoKey: Value(bank['logo_key'] as String),
            updatedAt: Value(bank['updated_at'] as String?),
            deletedAt: Value(bank['deleted_at'] as String?),
          ));
          report.pulled += 1;
        }
        for (final entity in syncEntities) {
          for (final record in ((changes[entity] as List?) ?? const []).cast<Map<String, dynamic>>()) {
            await _applyPulled(_tables[entity]!, record);
            report.pulled += 1;
          }
        }
        await db.writeState('cursor', next);
      });

      cursor = next;
      if (res['has_more'] != true) return;
    }
  }

  Future<void> _applyPulled(SyncTable table, Map<String, dynamic> record) async {
    final id = record['id'] as String;
    final pending = await _outbox(table.entity, id);

    if (record['deleted_at'] != null) {
      // El tombstone gana a cualquier edición: se descarta lo pendiente.
      await table.applyServerRecord(record);
      if (pending != null) await _removeOutbox(table.entity, id);
      return;
    }
    if (pending != null) {
      if (pending.deleted) return; // un borrado local pendiente gana, sin importar fechas
      if (pending.clientUpdatedAt.compareTo(record['client_updated_at'] as String) > 0) {
        return; // la edición local es más nueva: ganará al subirse
      }
    }
    await table.applyServerRecord(record);
    if (pending != null) await _removeOutbox(table.entity, id);
  }

  // ---------------------------------------------------------------- reloj

  Future<void> _learnClockOffset(String? serverTime) async {
    if (serverTime == null) return;
    final offset = DateTime.parse(serverTime).difference(_now().toUtc());
    clock.offset = offset;
    await db.writeState('clock_offset_ms', offset.inMilliseconds.toString());
  }
}
