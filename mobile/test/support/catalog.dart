import 'package:drift/drift.dart';
import 'package:finanzas_personales/core/db/app_database.dart';

/// Catálogo mínimo como lo dejaría un primer sync (filas con `updated_at` del servidor).
class Catalog {
  const Catalog();
  static const bbva = 'bank-bbva';
  static const santander = 'bank-santander';
  static const vivienda = 'cat-vivienda';
  static const comida = 'cat-comida';
  static const salario = 'cat-salario';
  static const prestamoCobrado = 'cat-prestamo';
  static const pagoPrestamo = 'cat-pago-prestamo';
  static const pagoTarjeta = 'cat-pago-tarjeta';
}

const _synced = '2026-10-01T00:00:00.000000Z';

Future<void> seedCatalog(AppDatabase db) async {
  for (final (id, name, key) in [
    (Catalog.bbva, 'BBVA México', 'bbva'),
    (Catalog.santander, 'Santander', 'santander'),
    ('bank-banamex', 'Banamex', 'banamex'),
  ]) {
    await db.into(db.banks).insert(BanksCompanion.insert(id: id, name: name, logoKey: key, updatedAt: const Value(_synced)));
  }
  for (final (id, kind, name, system) in [
    (Catalog.vivienda, 'expense', 'Vivienda', false),
    (Catalog.comida, 'expense', 'Alimentación', false),
    (Catalog.salario, 'income', 'Salario / quincena', false),
    (Catalog.prestamoCobrado, 'income', 'Préstamo cobrado', true),
  ]) {
    await db.into(db.categories).insert(CategoriesCompanion.insert(
          id: id,
          kind: kind,
          name: name,
          isSystem: Value(system),
          updatedAt: const Value(_synced),
          clientUpdatedAt: _synced,
        ));
  }
}

/// Las dos categorías de gasto de sistema de la Fase 2 (las siembra el servidor; llegan por pull).
Future<void> seedPhase2Categories(AppDatabase db) async {
  for (final (id, name) in [(Catalog.pagoPrestamo, 'Pago de préstamo'), (Catalog.pagoTarjeta, 'Pago de tarjeta')]) {
    await db.into(db.categories).insert(CategoriesCompanion.insert(
          id: id,
          kind: 'expense',
          name: name,
          isSystem: const Value(true),
          updatedAt: const Value(_synced),
          clientUpdatedAt: _synced,
        ));
  }
}
