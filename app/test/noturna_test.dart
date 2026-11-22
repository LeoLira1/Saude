import 'package:flutter_test/flutter_test.dart';
import 'package:saude/data/background.dart';
import 'package:saude/saude/agregador.dart';

void main() {
  // Instantes em UTC. 23:00 em Brasília = 02:00 UTC do dia seguinte.
  group('próxima sincronização das 23:00 (Brasília)', () {
    test('de manhã: hoje às 23:00', () {
      expect(proximaNoturna(DateTime.utc(2026, 11, 23, 13)), DateTime.utc(2026, 11, 24, 2)); // 10:00 BRT
    });
    test('22:59 em Brasília: hoje às 23:00', () {
      expect(proximaNoturna(DateTime.utc(2026, 11, 24, 1, 59)), DateTime.utc(2026, 11, 24, 2));
    });
    test('exatamente 23:00 ou depois: amanhã às 23:00', () {
      expect(proximaNoturna(DateTime.utc(2026, 11, 24, 2)), DateTime.utc(2026, 11, 25, 2));
      expect(proximaNoturna(DateTime.utc(2026, 11, 24, 2, 7)), DateTime.utc(2026, 11, 25, 2)); // rodou 23:07
    });
    test('Android atrasou para depois da meia-noite: a próxima é a de hoje, 23:00', () {
      // 00:40 de 24/11 em Brasília = 03:40 UTC
      expect(proximaNoturna(DateTime.utc(2026, 11, 24, 3, 40)), DateTime.utc(2026, 11, 25, 2));
      expect(dataBrasilia(proximaNoturna(DateTime.utc(2026, 11, 24, 3, 40))), '2026-11-24');
    });
    test('virada de mês e de ano', () {
      expect(proximaNoturna(DateTime.utc(2026, 12, 31, 15)), DateTime.utc(2027, 1, 1, 2));
      expect(dataBrasilia(DateTime.utc(2027, 1, 1, 2)), '2026-12-31');
    });
  });

  group('dia em Brasília (independe do fuso do celular)', () {
    test('perto da meia-noite', () {
      expect(dataBrasilia(DateTime.utc(2026, 11, 23, 2, 59)), '2026-11-22'); // 23:59 BRT
      expect(dataBrasilia(DateTime.utc(2026, 11, 23, 3, 0)), '2026-11-23'); // 00:00 BRT
    });
    test('início do dia', () {
      expect(inicioDiaBrasilia(DateTime.utc(2026, 11, 23, 2, 59)), DateTime.utc(2026, 11, 22, 3));
      expect(inicioDiaBrasilia(DateTime.utc(2026, 11, 23, 3, 0)), DateTime.utc(2026, 11, 23, 3));
    });
    test('janela de dias para reler usa o dia de Brasília', () {
      // última leitura 22/11 23:30 BRT (02:30 UTC de 23/11); agora 30/11 08:00 BRT → 9 dias
      expect(diasParaLer(DateTime.utc(2026, 11, 23, 2, 30), DateTime.utc(2026, 11, 30, 11)), 9);
    });
  });
}
