import 'package:finanzas_personales/core/money/money.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Money.parse', () {
    test('convierte string decimal a centavos exactos', () {
      expect(Money.parse('1500.50').cents, 150050);
      expect(Money.parse('1500.5').cents, 150050);
      expect(Money.parse('1500').cents, 150000);
      expect(Money.parse('0.05').cents, 5);
      expect(Money.parse('-3.25').cents, -325);
      expect(Money.parse('  12.00 ').cents, 1200);
    });

    test('rechaza formatos inválidos y más de 2 decimales', () {
      for (final bad in ['', 'abc', '1.234', '1,5', '.5', '1.', '--1', '1e3', '9999999999999']) {
        expect(Money.tryParse(bad), isNull, reason: bad);
      }
      expect(() => Money.parse('1.234'), throwsFormatException);
    });
  });

  group('aritmética y formato', () {
    test('0.1 + 0.2 es exactamente 0.30 (sin coma flotante)', () {
      expect((Money.parse('0.10') + Money.parse('0.20')).toApiString(), '0.30');
      expect(Money.parse('0.10') + Money.parse('0.20'), Money.parse('0.3'));
    });

    test('suma y resta con signo', () {
      expect((Money.parse('100') - Money.parse('250.75')).toApiString(), '-150.75');
      expect((-Money.parse('5')).cents, -500);
    });

    test('toApiString con signo y relleno', () {
      expect(const Money(5).toApiString(), '0.05');
      expect(const Money(-5).toApiString(), '-0.05');
      expect(const Money(150050).toApiString(), '1500.50');
    });

    test('format agrega símbolo y separador de miles', () {
      expect(Money.zero.format(), r'$0.00');
      expect(Money.parse('1500.5').format(), r'$1,500.50');
      expect(Money.parse('1234567.89').format(), r'$1,234,567.89');
      expect(Money.parse('-3.05').format(), r'-$3.05');
      expect(Money.parse('999').format(), r'$999.00');
      expect(Money.parse('1000').format(), r'$1,000.00');
    });

    test('ida y vuelta con el formato del servidor', () {
      for (final s in ['0.00', '1.01', '99999999999.99', '-0.99']) {
        expect(Money.parse(s).toApiString(), s);
      }
    });
  });
}
