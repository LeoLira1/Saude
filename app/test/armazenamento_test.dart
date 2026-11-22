import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:saude/core/composicao.dart';
import 'package:saude/data/armazenamento.dart';
import 'package:saude/data/modelos.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('saude'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('medição: não duplica, entra na fila e persiste', () async {
    final a = await Armazenamento.abrir(pasta: dir);
    expect(a.adicionarMedicao(const Medicao(medidoEm: '2026-11-22 07:15:03', peso: 80.2)), isTrue);
    expect(a.adicionarMedicao(const Medicao(medidoEm: '2026-11-22 07:15:03', peso: 80.2)), isFalse);
    a.perfil = Perfil(alturaCm: 178, nascimento: DateTime(1990, 5, 2), masculino: true);
    a.apiKey = ' abc ';
    await a.salvar();

    final b = await Armazenamento.abrir(pasta: dir);
    expect(b.medicoes.length, 1);
    expect(b.filaMedicoes, ['2026-11-22 07:15:03']);
    expect(b.perfil!.alturaCm, 178);
    expect(b.apiKey, 'abc');
    expect(b.apiUrl, apiPadrao);
    b.tirarDaFila(['2026-11-22 07:15:03']);
    expect(b.filaMedicoes, isEmpty);
  });

  test('recusadas contam como vistas', () async {
    final a = await Armazenamento.abrir(pasta: dir);
    a.recusar('2026-11-22 08:00:00');
    expect(a.chavesVistas.contains('2026-11-22 08:00:00'), isTrue);
  });

  test('atividade: só reenvia o dia que mudou', () async {
    final a = await Armazenamento.abrir(pasta: dir);
    a.gravarAtividade([
      const AtividadeDia(data: '2026-11-21', passos: 5000),
      const AtividadeDia(data: '2026-11-22', passos: 1000),
    ]);
    expect(a.atividadePendente().length, 2);
    a.marcarAtividadeEnviada(a.atividadePendente());
    expect(a.atividadePendente(), isEmpty);
    a.gravarAtividade([const AtividadeDia(data: '2026-11-22', passos: 4000)]);
    expect(a.atividadePendente().map((d) => d.data), ['2026-11-22']);
  });

  test('mesclar do servidor não duplica', () async {
    final a = await Armazenamento.abrir(pasta: dir);
    a.adicionarMedicao(const Medicao(medidoEm: '2026-11-22 07:15:03', peso: 80.2));
    final n = a.mesclarMedicoes(const [
      Medicao(medidoEm: '2026-11-22 07:15:03', peso: 80.2),
      Medicao(medidoEm: '2026-11-20 07:00:00', peso: 81),
    ]);
    expect(n, 1);
    expect(a.medicoes.first.medidoEm, '2026-11-20 07:00:00'); // ordenado
  });
}
