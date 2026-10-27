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
  await addCategory('expense', 'Pago de préstamo', '#6A1B9A', system: true);
  await addCategory('expense', 'Pago de tarjeta', '#C62828', system: true);

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

  // Fase 2: un préstamo que te deben (con un cobro ya registrado), una deuda, suscripciones y tarjetas.
  String after(int days) => isoDate(DateTime(today.year, today.month, today.day + days));
  Future<void> row<T extends Table, D>(TableInfo<T, D> table, Insertable<D> companion) => db.into(table).insert(companion);

  final luis = uuid.v4();
  await row(db.loans, LoansCompanion.insert(
      id: luis, personName: 'Luis Pérez', direction: 'owed_to_me', principalCents: 300000, dueDate: Value(after(12)),
      notes: const Value('Para la camioneta'), updatedAt: Value(stamp), clientUpdatedAt: stamp));
  final cobroTx = uuid.v4();
  await row(db.transactions, TransactionsCompanion.insert(
      id: cobroTx, type: 'income', amountCents: 120000, accountId: accounts['efectivo']!.$1, categoryId: cat['Préstamo cobrado']!,
      occurredOn: after(-5), counterparty: const Value('Luis Pérez'), updatedAt: Value(stamp), clientUpdatedAt: stamp));
  await row(db.loanMovements, LoanMovementsCompanion.insert(
      id: uuid.v4(), loanId: luis, kind: 'payment', amountCents: 120000, occurredOn: after(-5), transactionId: Value(cobroTx),
      updatedAt: Value(stamp), clientUpdatedAt: stamp));
  await row(db.loans, LoansCompanion.insert(
      id: uuid.v4(), personName: 'Mamá', direction: 'i_owe', principalCents: 80000,
      updatedAt: Value(stamp), clientUpdatedAt: stamp));

  for (final (name, cents, period, nextIn, account) in [
    ('Netflix', 19900, 'monthly', 3, 'credito'),
    ('Spotify', 12900, 'monthly', 9, 'credito'),
    ('Amazon Prime', 99900, 'yearly', 140, 'nomina'),
    ('Gimnasio', 40000, 'monthly', 18, null),
  ]) {
    await row(db.subscriptions, SubscriptionsCompanion.insert(
        id: uuid.v4(), name: name, amountCents: cents, renewalDate: after(nextIn), period: period,
        accountId: Value(account == null ? null : accounts[account]!.$1), updatedAt: Value(stamp), clientUpdatedAt: stamp));
  }

  // Fase 3: presupuestos del mes (uno tranquilo, uno en aviso y uno excedido con los gastos de ejemplo).
  for (final (category, cents, alert) in [
    ('Alimentación', 300000, 80),
    ('Transporte', 80000, 80),
    ('Entretenimiento', 50000, 90),
  ]) {
    await row(db.budgets, BudgetsCompanion.insert(
        id: uuid.v4(), categoryId: cat[category]!, monthlyLimitCents: cents, alertPercent: Value(alert),
        updatedAt: Value(stamp), clientUpdatedAt: stamp));
  }

  final azul = uuid.v4();
  await row(db.creditCards, CreditCardsCompanion.insert(
      id: azul, name: 'BBVA Azul', bankId: Value(bankIds['bbva']), pendingBalanceCents: const Value(485075),
      dueDate: Value(after(6)), updatedAt: Value(stamp), clientUpdatedAt: stamp));
  await row(db.creditCards, CreditCardsCompanion.insert(
      id: uuid.v4(), name: 'Nu', bankId: Value(bankIds['nu']), pendingBalanceCents: const Value(120000),
      dueDate: Value(after(21)), updatedAt: Value(stamp), clientUpdatedAt: stamp));
  final pagoTx = uuid.v4();
  await row(db.transactions, TransactionsCompanion.insert(
      id: pagoTx, type: 'expense', amountCents: 150000, accountId: accounts['nomina']!.$1, categoryId: cat['Pago de tarjeta']!,
      occurredOn: after(-14), description: const Value('Pago de tarjeta BBVA Azul'), updatedAt: Value(stamp), clientUpdatedAt: stamp));
  await row(db.creditCardPayments, CreditCardPaymentsCompanion.insert(
      id: uuid.v4(), creditCardId: azul, amountCents: 150000, paidOn: after(-14), accountId: Value(accounts['nomina']!.$1),
      transactionId: Value(pagoTx), updatedAt: Value(stamp), clientUpdatedAt: stamp));
}
