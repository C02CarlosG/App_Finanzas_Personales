import 'package:finanzas_personales/core/money/money_input.dart';
import 'package:finanzas_personales/core/format/dates.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseMoneyInput', () {
    test('acepta símbolos, espacios y separador de miles', () {
      expect(parseMoneyInput(r'$1,500.50')?.cents, 150050);
      expect(parseMoneyInput(' 1,234,567.89 ')?.cents, 123456789);
      expect(parseMoneyInput('250')?.cents, 25000);
      expect(parseMoneyInput('250.5')?.cents, 25050);
      expect(parseMoneyInput('-30.25')?.cents, -3025);
    });

    test('una coma decimal de 1–2 dígitos se interpreta como decimal', () {
      expect(parseMoneyInput('12,5')?.cents, 1250);
      expect(parseMoneyInput('12,50')?.cents, 1250);
    });

    test('rechaza texto, vacíos y más de 2 decimales', () {
      for (final bad in ['', '  ', 'abc', '1.234', '1,2,3', r'$', '12..5']) {
        expect(parseMoneyInput(bad), isNull, reason: bad);
      }
    });
  });

  group('fechas', () {
    test('isoDate / parseIsoDate / formatDate', () {
      expect(isoDate(DateTime(2026, 10, 5)), '2026-10-05');
      expect(parseIsoDate('2026-10-05'), DateTime(2026, 10, 5));
      expect(formatDate('2026-10-05'), '5 oct 2026');
      expect(formatDateShort('2026-01-31'), '31 ene');
      expect(monthLabel(2026, 10), 'octubre 2026');
    });

    test('rangos de mes y navegación entre meses (con cambio de año)', () {
      expect(monthRange(2026, 10), (from: '2026-10-01', to: '2026-11-01'));
      expect(monthRange(2026, 12), (from: '2026-12-01', to: '2027-01-01'));
      expect(previousMonth(2026, 1), (year: 2025, month: 12));
      expect(nextMonth(2026, 12), (year: 2027, month: 1));
      expect(nextMonth(2026, 3), (year: 2026, month: 4));
    });
  });
}
