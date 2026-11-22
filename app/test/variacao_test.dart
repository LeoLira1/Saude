import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:saude/data/armazenamento.dart';
import 'package:saude/data/modelos.dart';
import 'package:saude/ui/estado_app.dart';
import 'package:saude/ui/tema.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('var'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('delta arredonda só depois da subtração', () {
    expect(delta(86.45 - 86.35), '+0,1'); // 0,09999999999999432
    expect(delta(86.35 - 86.45), '−0,1');
    expect(delta(0.04), '0,0');
    expect(delta(0.05), '+0,1');
    expect(delta(-1.84), '−1,8');
  });

  test('"vs. anterior" pula a repetição da balança já gravada no celular', () async {
    final a = await Armazenamento.abrir(pasta: dir);
    // Celular antigo: gravou as repetições (antes da correção) direto na lista.
    a.mesclarMedicoes(const [
      Medicao(medidoEm: '2026-11-22 15:52:29', peso: 86.35, impedancia: 592),
      Medicao(medidoEm: '2026-11-22 15:53:10', peso: 86.45, impedancia: 593),
      Medicao(medidoEm: '2026-11-22 15:56:08', peso: 86.45, impedancia: 593), // repetida
    ]);
    final app = EstadoApp()..arm = a;
    expect(app.ultima!.medidoEm, '2026-11-22 15:53:10');
    expect(app.anterior!.peso, 86.35);
    expect(delta(app.ultima!.peso - app.anterior!.peso), '+0,1');
  });

  test('não grava de novo peso+impedância idênticos em até 30 min', () async {
    final a = await Armazenamento.abrir(pasta: dir);
    expect(a.adicionarMedicao(const Medicao(medidoEm: '2026-11-22 15:52:29', peso: 86.35, impedancia: 592)), isTrue);
    expect(a.adicionarMedicao(const Medicao(medidoEm: '2026-11-22 16:00:00', peso: 86.35, impedancia: 592)), isFalse);
    expect(a.adicionarMedicao(const Medicao(medidoEm: '2026-11-22 16:30:00', peso: 86.35, impedancia: 592)), isTrue); // >30 min
    expect(a.adicionarMedicao(const Medicao(medidoEm: '2026-11-22 16:31:00', peso: 86.45, impedancia: 592)), isTrue); // peso diferente
    expect(a.adicionarMedicao(const Medicao(medidoEm: '2026-11-22 16:32:00', peso: 86.45, impedancia: 592, origem: 'manual')), isTrue);
  });
}
