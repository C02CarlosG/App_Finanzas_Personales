import 'package:drift/drift.dart';

// Espejo local de las tablas sincronizadas del servidor (docs/sync.md).
// Marcas de tiempo: texto ISO con 6 decimales (ver core/sync/stamp.dart).
// Dinero: centavos enteros. Sin claves foráneas: las tablas llegan paginadas por separado.

@DataClassName('BankRow')
class Banks extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get logoKey => text()();
  TextColumn get updatedAt => text().nullable()();
  TextColumn get deletedAt => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('CategoryRow')
class Categories extends Table {
  TextColumn get id => text()();
  TextColumn get kind => text()(); // income | expense
  TextColumn get name => text()();
  TextColumn get icon => text().nullable()();
  TextColumn get color => text().nullable()();
  BoolColumn get isSystem => boolean().withDefault(const Constant(false))();
  TextColumn get updatedAt => text().nullable()(); // del servidor; null = nunca sincronizado
  TextColumn get clientUpdatedAt => text()();
  TextColumn get deletedAt => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('AccountRow')
class Accounts extends Table {
  TextColumn get id => text()();
  TextColumn get type => text()(); // banco | efectivo
  TextColumn get bankId => text().nullable()();
  TextColumn get name => text()();
  TextColumn get cardType => text().nullable()(); // debito | credito
  IntColumn get initialBalanceCents => integer().withDefault(const Constant(0))();
  TextColumn get updatedAt => text().nullable()();
  TextColumn get clientUpdatedAt => text()();
  TextColumn get deletedAt => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('TransactionRow')
class Transactions extends Table {
  TextColumn get id => text()();
  TextColumn get type => text()(); // income | expense
  IntColumn get amountCents => integer()();
  TextColumn get accountId => text()();
  TextColumn get categoryId => text()();
  TextColumn get occurredOn => text()(); // YYYY-MM-DD
  TextColumn get description => text().nullable()();
  TextColumn get counterparty => text().nullable()();
  TextColumn get updatedAt => text().nullable()();
  TextColumn get clientUpdatedAt => text()();
  TextColumn get deletedAt => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

// ---------- Fase 2 ----------

/// Préstamo o deuda. `principalCents` es el monto **original**: el pendiente se deriva de los
/// movimientos (`principal + aumentos − abonos`), así dos dispositivos convergen (docs/sync.md §2).
@DataClassName('LoanRow')
class Loans extends Table {
  TextColumn get id => text()();
  TextColumn get personName => text()();
  TextColumn get direction => text()(); // i_owe (le debo) | owed_to_me (me debe)
  IntColumn get principalCents => integer()();
  TextColumn get dueDate => text().nullable()(); // YYYY-MM-DD, plazo opcional
  TextColumn get status => text().withDefault(const Constant('active'))(); // active | paid
  TextColumn get notes => text().nullable()();
  TextColumn get updatedAt => text().nullable()();
  TextColumn get clientUpdatedAt => text()();
  TextColumn get deletedAt => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Abono (`payment`) o aumento (`increase`) de un préstamo. Un abono lleva su ingreso/gasto en
/// `transactionId`; un movimiento no se edita: se elimina y se vuelve a crear.
@DataClassName('LoanMovementRow')
class LoanMovements extends Table {
  TextColumn get id => text()();
  TextColumn get loanId => text()();
  TextColumn get kind => text()(); // payment | increase
  IntColumn get amountCents => integer()();
  TextColumn get occurredOn => text()();
  TextColumn get transactionId => text().nullable()();
  TextColumn get updatedAt => text().nullable()();
  TextColumn get clientUpdatedAt => text()();
  TextColumn get deletedAt => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('SubscriptionRow')
class Subscriptions extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get amountCents => integer()();
  TextColumn get renewalDate => text()(); // YYYY-MM-DD: una renovación conocida; las siguientes se derivan
  TextColumn get period => text()(); // weekly | monthly | yearly
  TextColumn get accountId => text().nullable()();
  BoolColumn get active => boolean().withDefault(const Constant(true))();
  TextColumn get updatedAt => text().nullable()();
  TextColumn get clientUpdatedAt => text()();
  TextColumn get deletedAt => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('CreditCardRow')
class CreditCards extends Table {
  TextColumn get id => text()();
  TextColumn get bankId => text().nullable()();
  TextColumn get name => text()();
  IntColumn get pendingBalanceCents => integer().withDefault(const Constant(0))();
  TextColumn get dueDate => text().nullable()();
  TextColumn get updatedAt => text().nullable()();
  TextColumn get clientUpdatedAt => text()();
  TextColumn get deletedAt => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('CreditCardPaymentRow')
class CreditCardPayments extends Table {
  TextColumn get id => text()();
  TextColumn get creditCardId => text()();
  TextColumn get accountId => text().nullable()();
  TextColumn get transactionId => text().nullable()();
  IntColumn get amountCents => integer()();
  TextColumn get paidOn => text()();
  TextColumn get updatedAt => text().nullable()();
  TextColumn get clientUpdatedAt => text()();
  TextColumn get deletedAt => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Cambios locales pendientes de subir. Un renglón por registro con su estado
/// más reciente (coalescencia); los datos se leen de la tabla de origen al enviar.
@DataClassName('OutboxEntry')
class SyncOutbox extends Table {
  TextColumn get entity => text()(); // ver syncEntities en local_store.dart
  TextColumn get recordId => text()();
  TextColumn get clientUpdatedAt => text()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();

  /// Se marca **antes** de cada envío y es persistente: si la respuesta se pierde (timeout, app
  /// cerrada), el registro pudo haber llegado al servidor aunque aquí siga sin `updated_at`.
  /// Un borrado posterior debe dejar tombstone y enviarse, no eliminar la fila (docs/sync.md §6).
  BoolColumn get maybeSent => boolean().withDefault(const Constant(false))();

  /// El servidor lo marcó inválido de forma permanente: no se reenvía hasta que
  /// la app (o el usuario) lo corrija. Ver docs/sync.md §4.
  BoolColumn get blocked => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {entity, recordId};
}

/// Pares clave/valor: `cursor` del pull, `clock_offset_ms`.
@DataClassName('SyncStateRow')
class SyncState extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}
