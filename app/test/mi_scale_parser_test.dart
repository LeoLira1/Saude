import 'package:flutter_test/flutter_test.dart';
import 'package:saude/core/mi_scale_parser.dart';

/// Monta um frame de 13 bytes como a balança manda.
List<int> frame({
  int c0 = 0x02,
  required int c1,
  int ano = 2026,
  int mes = 11,
  int dia = 22,
  int hora = 7,
  int min = 15,
  int seg = 3,
  int imp = 0,
  required int pesoRaw,
}) =>
    [c0, c1, ano & 0xFF, ano >> 8, mes, dia, hora, min, seg, imp & 0xFF, imp >> 8, pesoRaw & 0xFF, pesoRaw >> 8];

void main() {
  test('medição final em kg: estabilizada + impedância', () {
    // 80,25 kg × 200 = 16050; impedância 512
    final l = lerAnuncioMiScale2(frame(c1: 0x20 | 0x02 | 0x04, imp: 512, pesoRaw: 16050))!;
    expect(l.pesoKg, 80.25);
    expect(l.impedancia, 512);
    expect(l.estabilizado, isTrue);
    expect(l.removido, isFalse);
    expect(l.finalComImpedancia, isTrue);
    expect(l.chave, '2026-11-22 07:15:03');
  });

  test('frame real (bytes do anúncio): 02 a6 e9 07 0b 16 07 0f 03 00 02 b2 3e', () {
    // ano 0x07e9 = 2025, impedância 0x0200 = 512, peso 0x3eb2 = 16050 → 80,25 kg
    final l = lerAnuncioMiScale2([0x02, 0xa6, 0xe9, 0x07, 0x0b, 0x16, 0x07, 0x0f, 0x03, 0x00, 0x02, 0xb2, 0x3e])!;
    expect(l.pesoKg, 80.25);
    expect(l.impedancia, 512);
    expect(l.estabilizado, isTrue);
    expect(l.removido, isTrue); // 0xa6 tem o bit 7: já saiu da balança, mas a medição vale
    expect(l.finalComImpedancia, isTrue);
    expect(l.chave, '2025-11-22 07:15:03');
  });

  test('peso ao vivo (não estabilizado) não é final', () {
    final l = lerAnuncioMiScale2(frame(c1: 0x00, pesoRaw: 15000))!;
    expect(l.pesoKg, 75);
    expect(l.finalComImpedancia, isFalse);
  });

  test('estabilizado sem impedância não é final', () {
    final l = lerAnuncioMiScale2(frame(c1: 0x20, pesoRaw: 15000))!;
    expect(l.estabilizado, isTrue);
    expect(l.finalComImpedancia, isFalse);
  });

  test('impedância 0 ou ≥ 3000 conta como sem impedância', () {
    expect(lerAnuncioMiScale2(frame(c1: 0x22, imp: 0, pesoRaw: 15000))!.finalComImpedancia, isFalse);
    expect(lerAnuncioMiScale2(frame(c1: 0x22, imp: 0xFFFE, pesoRaw: 15000))!.finalComImpedancia, isFalse);
  });

  test('libras e catty', () {
    // 176,37 lb ≈ 80,00 kg
    expect(lerAnuncioMiScale2(frame(c0: 0x03, c1: 0x22, imp: 500, pesoRaw: 17637))!.pesoKg, 80.0);
    // 160 jin = 80 kg
    expect(lerAnuncioMiScale2(frame(c1: 0x62, imp: 500, pesoRaw: 16000))!.pesoKg, 80.0);
  });

  test('data inválida → sem chave', () {
    expect(lerAnuncioMiScale2(frame(c1: 0x22, ano: 0, mes: 0, dia: 0, imp: 500, pesoRaw: 16000))!.chave, isNull);
    expect(lerAnuncioMiScale2(frame(c1: 0x22, mes: 2, dia: 31, imp: 500, pesoRaw: 16000))!.chave, isNull);
  });

  test('tamanho errado → null', () {
    expect(lerAnuncioMiScale2([1, 2, 3]), isNull);
  });
}
