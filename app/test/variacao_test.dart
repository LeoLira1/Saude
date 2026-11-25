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
    // >30 min, mas igual à anterior gravada: reenvio da balança
    expect(a.adicionarMedicao(const Medicao(medidoEm: '2026-11-22 16:30:00', peso: 86.35, impedancia: 592)), isFalse);
    expect(a.adicionarMedicao(const Medicao(medidoEm: '2026-11-22 16:31:00', peso: 86.45, impedancia: 592)), isTrue); // peso diferente
    expect(a.adicionarMedicao(const Medicao(medidoEm: '2026-11-22 16:32:00', peso: 86.45, impedancia: 592, origem: 'manual')), isTrue);
  });

  test('reenvio da balança (exemplos reais de 23 e 24/11): descarta e registra no log; a pesagem real entra', () async {
    final a = await Armazenamento.abrir(pasta: dir);
    // Na ordem em que chegaram do Bluetooth.
    const chegadas = [
      ('2026-11-23 06:04:26', 86.7, 615, true),
      ('2026-11-23 17:49:28', 86.7, 615, false), // reenvio da de 06:04
      ('2026-11-23 17:49:38', 86.55, 549, true),
      ('2026-11-23 21:18:47', 86.55, 549, false), // reenvio da de 17:49
      ('2026-11-23 21:18:56', 87.3, 572, true),
      ('2026-11-23 21:39:25', 87.5, 564, true),
      ('2026-11-24 06:05:55', 87.5, 564, false), // reenvio da de 21:39
      ('2026-11-24 06:06:05', 86.5, 600, true),
    ];
    for (final (em, peso, imp, grava) in chegadas) {
      expect(a.adicionarMedicao(Medicao(medidoEm: em, peso: peso, impedancia: imp)), grava, reason: em);
    }
    expect(a.medicoes.map((m) => m.medidoEm), [
      '2026-11-23 06:04:26',
      '2026-11-23 17:49:38',
      '2026-11-23 21:18:56',
      '2026-11-23 21:39:25',
      '2026-11-24 06:06:05',
    ]);
    expect(a.descartadas.map((d) => d['medido_em']), ['2026-11-23 17:49:28', '2026-11-23 21:18:47', '2026-11-24 06:05:55']);
    expect(a.descartadas.first['motivo'], contains('2026-11-23 06:04:26'));
    expect(a.filaMedicoes.length, 5);
  });

  test('histórico antigo com reenvios gravados: telas não contam', () async {
    final a = await Armazenamento.abrir(pasta: dir);
    a.mesclarMedicoes(const [
      Medicao(medidoEm: '2026-11-22 22:08:10', peso: 87.2, impedancia: 619),
      Medicao(medidoEm: '2026-11-23 06:04:17', peso: 87.2, impedancia: 619), // reenvio
      Medicao(medidoEm: '2026-11-23 06:04:26', peso: 86.7, impedancia: 615),
      Medicao(medidoEm: '2026-11-23 17:49:28', peso: 86.7, impedancia: 615), // reenvio
      Medicao(medidoEm: '2026-11-23 17:49:38', peso: 86.55, impedancia: 549),
    ]);
    expect(a.medicoesDistintas.map((m) => m.medidoEm),
        ['2026-11-22 22:08:10', '2026-11-23 06:04:26', '2026-11-23 17:49:38']);
  });
}
