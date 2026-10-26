import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/db/queries_fase3.dart';
import '../../../core/format/dates.dart';
import '../../../core/money/money.dart';

/// Una porción del pastel: su etiqueta, monto en centavos y color.
class PieSlice {
  const PieSlice({required this.label, required this.cents, required this.color});

  final String label;
  final int cents;
  final Color color;
}

/// Porcentaje entero de [part] sobre [total] (solo para mostrar).
int percentOf(int part, int total) => total <= 0 ? 0 : (part * 100 / total).round();

/// Pastel (dona) de gastos por categoría. Dibujo propio, sin paquetes. La descripción para lectores de
/// pantalla enumera cada porción; la leyenda con montos va aparte, en texto.
class ExpensePie extends StatelessWidget {
  const ExpensePie({super.key, required this.slices, this.size = 180});

  final List<PieSlice> slices;
  final double size;

  @override
  Widget build(BuildContext context) {
    final total = slices.fold<int>(0, (sum, s) => sum + s.cents);
    final description = 'Gráfica de pastel de gastos por categoría: '
        '${[for (final s in slices) '${s.label} ${percentOf(s.cents, total)} %'].join(', ')}';
    return Semantics(
      label: description,
      image: true,
      child: ExcludeSemantics(
        child: SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            key: const Key('grafica-pastel'),
            painter: PiePainter(slices: slices, holeColor: Theme.of(context).colorScheme.surface),
          ),
        ),
      ),
    );
  }
}

class PiePainter extends CustomPainter {
  PiePainter({required this.slices, required this.holeColor});

  final List<PieSlice> slices;
  final Color holeColor;

  @override
  void paint(Canvas canvas, Size size) {
    final total = slices.fold<int>(0, (sum, s) => sum + s.cents);
    if (total <= 0) return;
    final rect = Offset.zero & size;
    final center = rect.center;
    final radius = math.min(size.width, size.height) / 2;
    var start = -math.pi / 2;
    for (final s in slices) {
      final sweep = 2 * math.pi * s.cents / total;
      canvas.drawArc(Rect.fromCircle(center: center, radius: radius), start, sweep, true, Paint()..color = s.color);
      start += sweep;
    }
    // Separadores finos y agujero central (dona).
    start = -math.pi / 2;
    final line = Paint()
      ..color = holeColor
      ..strokeWidth = 2;
    for (final s in slices) {
      canvas.drawLine(center, center + Offset(math.cos(start), math.sin(start)) * radius, line);
      start += 2 * math.pi * s.cents / total;
    }
    canvas.drawCircle(center, radius * 0.55, Paint()..color = holeColor);
  }

  @override
  bool shouldRepaint(PiePainter old) => old.holeColor != holeColor || !_same(old.slices, slices);

  static bool _same(List<PieSlice> a, List<PieSlice> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].cents != b[i].cents || a[i].color != b[i].color) return false;
    }
    return true;
  }
}

/// Tendencia de ingresos y gastos de los últimos meses (dos líneas). Dibujo propio; el detalle de montos va
/// en texto debajo, y esta descripción cubre a los lectores de pantalla.
class TrendChart extends StatelessWidget {
  const TrendChart({super.key, required this.points, required this.incomeColor, required this.expenseColor, this.height = 190});

  final List<MonthPoint> points;
  final Color incomeColor;
  final Color expenseColor;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final description = 'Gráfica de líneas de ingresos y gastos: '
        '${[for (final p in points) '${monthLabel(p.year, p.month)}, ingresos ${p.income.format()}, gastos ${p.expense.format()}'].join('; ')}';
    return Semantics(
      label: description,
      image: true,
      child: ExcludeSemantics(
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(
            key: const Key('grafica-tendencia'),
            painter: TrendPainter(
              points: points,
              incomeColor: incomeColor,
              expenseColor: expenseColor,
              gridColor: theme.colorScheme.outlineVariant,
              labelStyle: (theme.textTheme.labelSmall ?? const TextStyle(fontSize: 11)).copyWith(color: theme.colorScheme.onSurfaceVariant),
              textScaler: MediaQuery.textScalerOf(context),
            ),
          ),
        ),
      ),
    );
  }
}

class TrendPainter extends CustomPainter {
  TrendPainter({
    required this.points,
    required this.incomeColor,
    required this.expenseColor,
    required this.gridColor,
    required this.labelStyle,
    required this.textScaler,
  });

  final List<MonthPoint> points;
  final Color incomeColor;
  final Color expenseColor;
  final Color gridColor;
  final TextStyle labelStyle;
  final TextScaler textScaler;

  static const _months = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];

  TextPainter _text(String text) => TextPainter(
        text: TextSpan(text: text, style: labelStyle),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
        maxLines: 1,
      )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final labels = [for (final p in points) _text(_months[p.month - 1])];
    final labelHeight = labels.map((l) => l.height).fold<double>(0, math.max);
    const padX = 28.0;
    const padTop = 12.0;
    final bottom = size.height - labelHeight - 10;
    final plotWidth = math.max(1.0, size.width - padX * 2);
    final plotHeight = math.max(1.0, bottom - padTop);

    // La escala se calcula con enteros (centavos) y solo al dibujar pasa a coordenadas.
    final maxCents = points.fold<int>(1, (m, p) => math.max(m, math.max(p.income.cents, p.expense.cents)));
    double x(int i) => points.length == 1 ? padX + plotWidth / 2 : padX + plotWidth * i / (points.length - 1);
    double y(int cents) => bottom - plotHeight * cents / maxCents;

    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 0; i <= 2; i++) {
      final gy = bottom - plotHeight * i / 2;
      canvas.drawLine(Offset(padX / 2, gy), Offset(size.width - padX / 2, gy), grid);
    }

    void series(int Function(MonthPoint) value, Color color) {
      final path = Path();
      for (var i = 0; i < points.length; i++) {
        final o = Offset(x(i), y(value(points[i])));
        i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );
      for (var i = 0; i < points.length; i++) {
        canvas.drawCircle(Offset(x(i), y(value(points[i]))), 4.5, Paint()..color = color);
      }
    }

    series((p) => p.income.cents, incomeColor);
    series((p) => p.expense.cents, expenseColor);

    for (var i = 0; i < labels.length; i++) {
      labels[i].paint(canvas, Offset(x(i) - labels[i].width / 2, bottom + 6));
    }
  }

  @override
  bool shouldRepaint(TrendPainter old) {
    if (old.points.length != points.length || old.incomeColor != incomeColor || old.expenseColor != expenseColor) return true;
    for (var i = 0; i < points.length; i++) {
      if (old.points[i].income != points[i].income || old.points[i].expense != points[i].expense) return true;
    }
    return old.textScaler != textScaler || old.gridColor != gridColor;
  }
}

/// Convierte la lista de gastos por categoría en porciones: las 6 mayores y el resto junto en "Otras".
List<PieSlice> pieSlices(List<CategorySpend> spend, {required Color Function(CategorySpend) colorOf, required Color otherColor, int top = 6}) {
  final shown = spend.take(top).toList();
  final rest = spend.skip(top).fold<int>(0, (sum, c) => sum + c.total.cents);
  return [
    for (final c in shown) PieSlice(label: c.name, cents: c.total.cents, color: colorOf(c)),
    if (rest > 0) PieSlice(label: 'Otras', cents: rest, color: otherColor),
  ];
}

/// Texto "$1,234.50" para un total en centavos.
String moneyText(int cents) => Money(cents).format();
