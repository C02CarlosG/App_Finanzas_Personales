import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../db/app_database.dart';
import '../format/dates.dart';
import '../sync/stamp.dart';

/// Datos de ejemplo para `DEMO_MODE` (solo desarrollo): catálogo de bancos, categorías, cuentas y
/// movimientos de los últimos 3 meses. Se siembran una sola vez y quedan como "ya sincronizados"
/// (sin outbox), porque en modo demo no hay servidor.
Future<void> seedDemoData(AppDatabase db, {DateTime? now}) async {
  if ((await db.select(db.banks).get()).isNotEmpty) return;
  final today = now ?? DateTime.now();
  final stamp = formatStamp(today);
  const uuid = Uuid();

  const banks = [
    ('BBVA México', 'bbva'), ('Santander', 'santander'), ('Banamex', 'banamex'), ('Banorte', 'banorte'),
    ('HSBC', 'hsbc'), ('Scotiabank', 'scotiabank'), ('Inbursa', 'inbursa'), ('Banco Azteca', 'azteca'),
    ('BanCoppel', 'bancoppel'), ('Afirme', 'afirme'), ('Banregio', 'banregio'), ('Nu México', 'nu'),
    ('Hey Banco', 'hey'), ('Mercado Pago', 'mercadopago'), ('Klar', 'klar'), ('Spin by OXXO', 'spin'),
  ];
  final bankIds = <String, String>{};
  await db.batch((b) {
    for (final (name, key) in banks) {
      final id = uuid.v4();
      bankIds[key] = id;
      b.insert(db.banks, BanksCompanion.insert(id: id, name: name, logoKey: key, updatedAt: Value(stamp)));
    }
  });

  const incomeNames = ['Salario / quincena', 'Freelance', 'Negocio propio', 'Inversiones', 'Bonificaciones', 'Regalos', 'Reembolsos'];
  const expenseNames = ['Vivienda', 'Transporte', 'Alimentación', 'Servicios', 'Entretenimiento', 'Educación', 'Salud'];
  const colors = ['#2E7D32', '#1565C0', '#EF6C00', '#6A1B9A', '#AD1457', '#00838F', '#C62828'];
  final cat = <String, String>{};
  Future<void> addCategory(String kind, String name, String? color, {bool system = false}) async {
    final id = uuid.v4();
    cat[name] = id;
    await db.into(db.categories).insert(CategoriesCompanion.insert(
          id: id, kind: kind, name: name, color: Value(color), isSystem: Value(system),
          updatedAt: Value(stamp), clientUpdatedAt: stamp));
  }

  for (var i = 0; i < incomeNames.length; i++) {
    await addCategory('income', incomeNames[i], colors[i % colors.length]);
  }
  await addCategory('income', 'Préstamo cobrado', '#AD1457', system: true);
  for (var i = 0; i < expenseNames.length; i++) {
    await addCategory('expense', expenseNames[i], colors[(i + 2) % colors.length]);
  }

  final accounts = {
    'nomina': (uuid.v4(), 'banco', bankIds['bbva'], 'Nómina BBVA', 'debito', 1200000),
    'credito': (uuid.v4(), 'banco', bankIds['santander'], 'Santander Crédito', 'credito', -350000),
    'efectivo': (uuid.v4(), 'efectivo', null, 'Efectivo', null, 600000),
  };
  for (final (id, type, bankId, name, card, initial) in accounts.values) {
    await db.into(db.accounts).insert(AccountsCompanion.insert(
          id: id, type: type, bankId: Value(bankId), name: name, cardType: Value(card),
          initialBalanceCents: Value(initial), updatedAt: Value(stamp), clientUpdatedAt: stamp));
  }

  // Movimientos de los últimos 3 meses, con fechas reales relativas a hoy (nunca en el futuro).
  var n = 0;
  Future<void> tx(DateTime day, String type, int cents, String account, String category, String description, {String? who}) async {
    if (day.isAfter(today)) return;
    n += 1;
    await db.into(db.transactions).insert(TransactionsCompanion.insert(
          id: uuid.v4(), type: type, amountCents: cents, accountId: accounts[account]!.$1, categoryId: cat[category]!,
          occurredOn: isoDate(day), description: Value(description), counterparty: Value(who),
          updatedAt: Value(stamp), clientUpdatedAt: stamp));
  }

  for (var back = 0; back < 3; back++) {
    final m = DateTime(today.year, today.month - back, 1);
    DateTime d(int day) => DateTime(m.year, m.month, day);
    await tx(d(1), 'income', 850000, 'nomina', 'Salario / quincena', 'Quincena');
    await tx(d(15), 'income', 850000, 'nomina', 'Salario / quincena', 'Quincena');
    await tx(d(2), 'expense', 550000, 'nomina', 'Vivienda', 'Renta');
    await tx(d(4), 'expense', 189050, 'nomina', 'Alimentación', 'Súper');
    await tx(d(6), 'expense', 45000, 'efectivo', 'Transporte', 'Gasolina');
    await tx(d(8), 'expense', 59900, 'credito', 'Entretenimiento', 'Cine y cena');
    await tx(d(10), 'expense', 82000, 'nomina', 'Servicios', 'Luz e internet');
    await tx(d(12), 'expense', 32000, 'efectivo', 'Alimentación', 'Tacos y mercado');
    await tx(d(18), 'expense', 120000, 'credito', 'Salud', 'Consulta y medicinas');
    await tx(d(22), 'expense', 27500, 'efectivo', 'Transporte', 'Taxi');
    if (back == 0) {
      await tx(d(5), 'income', 120000, 'efectivo', 'Préstamo cobrado', 'Pago parcial', who: 'Luis Pérez');
      await tx(d(9), 'income', 350000, 'nomina', 'Freelance', 'Diseño de logotipo');
    }
  }
  assert(n > 0);
}
