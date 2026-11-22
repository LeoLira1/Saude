import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:saude/data/armazenamento.dart';
import 'package:saude/data/modelos.dart';
import 'package:saude/saude/agregador.dart';

void main() {
  group('B: quantos dias reler', () {
    final agora = DateTime(2026, 11, 22, 10);
    test('primeira vez: 30', () => expect(diasParaLer(null, agora), 30));
    test('sincronizou hoje ou ontem: mínimo 7', () {
      expect(diasParaLer(DateTime(2026, 11, 22, 8), agora), 7);
      expect(diasParaLer(DateTime(2026, 11, 21, 23, 50), agora), 7);
    });
    test('12 dias sem sincronizar: relê 13 (inclui o dia da última, que pode ter ficado incompleto)', () {
      expect(diasParaLer(DateTime(2026, 11, 10, 9), agora), 13);
    });
    test('mais de 30 dias: limita em 30', () => expect(diasParaLer(DateTime(2026, 9, 1), agora), 30));
  });

  group('C: FC de repouso', () {
    DateTime t(int d, int h) => DateTime(2026, 11, d, h);
    final batimentos = [
      for (var i = 0; i < 40; i++) Amostra(t(21, 8), t(21, 8), 55.0 + i), // dia 21 (encerrado)
      for (var i = 0; i < 40; i++) Amostra(t(22, 8), t(22, 8), 70.0 + i), // dia 22 (hoje, incompleto)
    ];
    List<AtividadeDia> montar({List<Amostra> rhr = const []}) => montarDias(
          datas: ['2026-11-21', '2026-11-22'],
          passos: {},
          calorias: {},
          batimentos: batimentos,
          fcRepouso: rhr,
          spo2: [],
          sono: {},
          hoje: '2026-11-22',
        );

    test('dia encerrado sem a do Mi Fitness: estima e marca', () {
      final d = montar().first;
      expect(d.fcRepouso, 57); // média dos 4 menores (55..58) = 56,5 → 57
      expect(d.fcRepousoEstimada, isTrue);
    });
    test('hoje (dia incompleto): não estima', () {
      final d = montar().last;
      expect(d.fcRepouso, isNull);
      expect(d.fcRepousoEstimada, isNull);
      expect(d.fcMedia, isNotNull); // a média continua
    });
    test('com a do Mi Fitness: usa a real e marca false, inclusive hoje', () {
      final dias = montar(rhr: [Amostra(t(21, 6), t(21, 6), 61), Amostra(t(22, 6), t(22, 6), 62)]);
      expect(dias.first.fcRepouso, 61);
      expect(dias.first.fcRepousoEstimada, isFalse);
      expect(dias.last.fcRepouso, 62);
      expect(dias.last.fcRepousoEstimada, isFalse);
      expect(dias.first.toJson()['fc_repouso_estimada'], 0);
    });
  });

  group('A: leitura parcial não apaga o que já estava salvo', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('sinc'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('campo vazio mantém o anterior; campo novo substitui', () async {
      final a = await Armazenamento.abrir(pasta: dir);
      a.gravarAtividade([
        const AtividadeDia(data: '2026-11-21', passos: 8000, calorias: 300, sonoMin: 420, sonoProfundoMin: 80, fcRepouso: 57, fcRepousoEstimada: true),
      ]);
      // Segundo plano: passos falharam (null), sono e FC real vieram.
      a.gravarAtividade([const AtividadeDia(data: '2026-11-21', calorias: 310, fcRepouso: 60, fcRepousoEstimada: false)]);
      final d = a.atividade['2026-11-21']!;
      expect(d.passos, 8000);
      expect(d.calorias, 310);
      expect(d.sonoMin, 420);
      expect(d.sonoProfundoMin, 80);
      expect(d.fcRepouso, 60);
      expect(d.fcRepousoEstimada, isFalse);
    });

    test('status do segundo plano fica salvo', () async {
      final a = await Armazenamento.abrir(pasta: dir);
      a.statusSegundoPlano = {'quando': '2026-11-23T03:10:00', 'ok': false, 'erro': 'Health Connect: STEPS: permissão'};
      await a.salvar();
      final b = await Armazenamento.abrir(pasta: dir);
      expect(b.statusSegundoPlano!['ok'], isFalse);
      expect(b.statusSegundoPlano!['erro'], contains('STEPS'));
    });
  });

  test('D: noite que começou no dia anterior ao primeiro dia lido vai para o dia em que acordou', () {
    // Janela começa em 16/11; a noite começou 15/11 às 23:00 (antes do início). Agora a leitura parte de
    // 15/11 00:00, então a sessão é encontrada e fica em 16/11.
    final s = agregarSono([Amostra(DateTime(2026, 11, 15, 23), DateTime(2026, 11, 16, 6, 30))], const []);
    expect(s.keys, ['2026-11-16']);
    expect(s['2026-11-16']!.total, 450);
  });
}
