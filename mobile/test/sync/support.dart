import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:finanzas_personales/core/db/app_database.dart';
import 'package:finanzas_personales/core/db/local_store.dart';
import 'package:finanzas_personales/core/network/api_exception.dart';
import 'package:finanzas_personales/core/sync/stamp.dart';
import 'package:finanzas_personales/core/sync/sync_api.dart';
import 'package:finanzas_personales/core/sync/sync_engine.dart';

typedef PushHandler = Future<Map<String, dynamic>> Function(List<Map<String, dynamic>> changes);

/// Servidor falso con respuestas programadas por prueba.
class FakeSyncApi implements SyncApi {
  final pushes = <List<Map<String, dynamic>>>[];
  final pullCursors = <String?>[];
  final pullQueue = <Map<String, dynamic>>[];
  PushHandler? onPush;

  @override
  Future<Map<String, dynamic>> push(List<Map<String, dynamic>> changes) {
    pushes.add(changes);
    final handler = onPush;
    if (handler == null) throw StateError('onPush no configurado');
    return handler(changes);
  }

  @override
  Future<Map<String, dynamic>> pull({String? cursor, int limit = 500}) async {
    pullCursors.add(cursor);
    if (pullQueue.isEmpty) return pullPage();
    return pullQueue.removeAt(0);
  }
}

const serverTime = '2026-10-20T12:00:00.000Z';

Map<String, dynamic> pullPage({
  List<Map<String, dynamic>> banks = const [],
  List<Map<String, dynamic>> categories = const [],
  List<Map<String, dynamic>> accounts = const [],
  List<Map<String, dynamic>> transactions = const [],
  String next = 'cursor-1',
  bool hasMore = false,
}) =>
    {
      'changes': {'banks': banks, 'categories': categories, 'accounts': accounts, 'transactions': transactions},
      'next_cursor': next,
      'has_more': hasMore,
      'server_time': serverTime,
    };

Map<String, dynamic> pushResponse(List<Map<String, dynamic>> results) =>
    {'results': results, 'server_time': serverTime};

Map<String, dynamic> result(Map<String, dynamic> change, String status,
        {String? code, Map<String, dynamic>? record, Map<String, dynamic> extra = const {}}) =>
    {'table': change['table'], 'id': change['id'], 'status': status, 'code': ?code, 'record': record, ...extra};

/// Registro de transacción tal como lo entrega el servidor.
Map<String, dynamic> serverTx(String id,
        {String amount = '50.00',
        String accountId = 'acc-1',
        String categoryId = 'cat-1',
        String updatedAt = '2026-10-20T11:00:00.000000Z',
        String clientUpdatedAt = '2026-10-20T10:00:00.000000Z',
        String? deletedAt,
        String? description}) =>
    {
      'id': id,
      'type': 'expense',
      'amount': amount,
      'account_id': accountId,
      'category_id': categoryId,
      'occurred_on': '2026-10-19',
      'description': description,
      'counterparty': null,
      'updated_at': updatedAt,
      'client_updated_at': clientUpdatedAt,
      'deleted_at': deletedAt,
    };

Map<String, dynamic> serverCategory(String id, String name,
        {String kind = 'expense', String updatedAt = '2026-10-20T11:00:00.000000Z',
        String clientUpdatedAt = '2026-10-20T10:00:00.000000Z', String? deletedAt}) =>
    {
      'id': id,
      'kind': kind,
      'name': name,
      'icon': null,
      'color': null,
      'is_system': false,
      'updated_at': updatedAt,
      'client_updated_at': clientUpdatedAt,
      'deleted_at': deletedAt,
    };

Map<String, dynamic> serverAccount(String id, String name,
        {String updatedAt = '2026-10-20T11:00:00.000000Z',
        String clientUpdatedAt = '2026-10-20T10:00:00.000000Z', String? deletedAt}) =>
    {
      'id': id,
      'type': 'efectivo',
      'bank_id': null,
      'name': name,
      'card_type': null,
      'initial_balance': '100.00',
      'updated_at': updatedAt,
      'client_updated_at': clientUpdatedAt,
      'deleted_at': deletedAt,
    };

class Harness {
  Harness({DateTime? now, this.delays})
      : db = AppDatabase(NativeDatabase.memory()),
        api = FakeSyncApi() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    clock = StampClock(now: () => _now);
    _now = now ?? DateTime.utc(2026, 10, 20, 12);
    store = LocalStore(db, clock, isSyncing: () => engine.isSyncing);
    engine = SyncEngine(
      db: db,
      api: api,
      store: store,
      clock: clock,
      now: () => _now,
      delay: (d) async => delays?.add(d),
    );
  }

  final AppDatabase db;
  final FakeSyncApi api;
  final List<Duration>? delays;
  late final StampClock clock;
  late final LocalStore store;
  late final SyncEngine engine;
  late DateTime _now;

  /// Avanza el reloj del dispositivo para que los sellos de ediciones sucesivas difieran.
  void advance(Duration d) => _now = _now.add(d);

  /// Otro motor sobre la misma base y reloj, con una API distinta.
  SyncEngine engineWith(SyncApi other) =>
      SyncEngine(db: db, api: other, store: store, clock: clock, now: () => _now, delay: (d) async {});

  Future<List<OutboxEntry>> outbox() => db.select(db.syncOutbox).get();

  Future<TransactionRow> tx(String id) =>
      (db.select(db.transactions)..where((t) => t.id.equals(id))).getSingle();

  Future<void> close() => db.close();
}

ApiException apiError(String code, int status) => ApiException(code: code, message: code, status: status);

/// Respuesta `applied` verosímil para un cambio enviado (como la devolvería el servidor).
Map<String, dynamic> okRecord(Map<String, dynamic> change) {
  final data = (change['data'] as Map<String, dynamic>?) ?? const {};
  final id = change['id'] as String;
  final stamp = change['client_updated_at'] as String;
  switch (change['table']) {
    case 'categories':
      return {...serverCategory(id, data['name'] as String? ?? 'x', kind: data['kind'] as String? ?? 'expense', clientUpdatedAt: stamp)};
    case 'accounts':
      return {...serverAccount(id, data['name'] as String? ?? 'x', clientUpdatedAt: stamp)};
    default:
      return {
        ...serverTx(id,
            amount: data['amount'] as String? ?? '1.00',
            accountId: data['account_id'] as String? ?? 'acc-1',
            categoryId: data['category_id'] as String? ?? 'cat-1',
            clientUpdatedAt: stamp)
      };
  }
}

extension HarnessSeed on Harness {
  /// Siembra registros "ya sincronizados" aplicando una página de pull.
  Future<void> seedFromServer(Map<String, dynamic> page) async {
    api.pullQueue.add(page);
    await engine.run();
  }
}
