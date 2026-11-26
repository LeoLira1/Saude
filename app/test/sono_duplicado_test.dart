import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saude/data/api.dart';
import 'package:saude/data/armazenamento.dart';
import 'package:saude/data/modelos.dart';
import 'package:saude/data/sincronizacao.dart';
import 'package:saude/saude/agregador.dart';

/// Sono gravado em dobro no Health Connect: mesma noite em duas sessões, por duas fontes,
/// sessões sobrepostas e várias noites na mesma janela de leitura.
void main() {
  DateTime t(int dia, int h, [int m = 0]) => DateTime.utc(2026, 11, dia, h + 3, m); // hora de Brasília
  const mi = 'com.mi.health';
  const fit = 'com.google.android.apps.fitness';

  /// Uma noite de 25→26/11 (23:00–06:58): 127 profundo + 342 leve + 17 acordado (469 dormindo).
  List<EstagioSono> noite(String sessao, String fonte) => [
        EstagioSono(Estagio.leve, t(25, 23), t(26, 1), sessaoId: sessao, fonte: fonte), // 120
        EstagioSono(Estagio.profundo, t(26, 1), t(26, 3, 7), sessaoId: sessao, fonte: fonte), // 127
        EstagioSono(Estagio.acordado, t(26, 3, 7), t(26, 3, 24), sessaoId: sessao, fonte: fonte), // 17
        EstagioSono(Estagio.leve, t(26, 3, 24), t(26, 6, 58), sessaoId: sessao, fonte: fonte), // 214
      ];
  SessaoSono sessao(String id, String fonte, [DateTime? ini, DateTime? fim]) =>
      SessaoSono(ini ?? t(25, 23), fim ?? t(26, 6, 58), id: id, fonte: fonte);

  void confereNoite(Noite n) {
    expect(n.profundo, 127);
    expect(n.leve, 334);
    expect(n.acordado, 17);
    expect(n.total, 461); // sem o acordado
    expect(n.total, lessThanOrEqualTo(1440));
  }

  test('caso do bug: duas fontes com a mesma noite — antes dava 4x (31h17), agora conta uma vez', () {
    final s = agregarSono(
      [sessao('a', mi), sessao('b', fit)],
      [...noite('a', mi), ...noite('b', fit)],
    );
    expect(s.keys, ['2026-11-26']);
    confereNoite(s['2026-11-26']!);
    expect(s['2026-11-26']!.fontes, hasLength(1));
  });

  test('mesma fonte gravou a noite duas vezes (ids diferentes) e repetiu estágios idênticos', () {
    final s = agregarSono(
      [sessao('a', mi), sessao('a2', mi), sessao('a', mi)],
      [...noite('a', mi), ...noite('a2', mi), ...noite('a', mi)],
    );
    confereNoite(s['2026-11-26']!);
  });

  test('sessões sobrepostas em parte (uma começa antes, outra termina depois): cada minuto conta uma vez', () {
    final s = agregarSono(
      [
        SessaoSono(t(25, 23), t(26, 3), id: 'x', fonte: mi),
        SessaoSono(t(26, 1), t(26, 7), id: 'y', fonte: mi),
      ],
      [
        EstagioSono(Estagio.leve, t(25, 23), t(26, 3), sessaoId: 'x', fonte: mi), // 240
        EstagioSono(Estagio.profundo, t(26, 1), t(26, 2), sessaoId: 'y', fonte: mi), // sobre o leve de x
        EstagioSono(Estagio.leve, t(26, 2), t(26, 7), sessaoId: 'y', fonte: mi),
      ],
    );
    final n = s['2026-11-26']!;
    expect(n.total, 8 * 60); // 23:00–07:00, sem dobrar 01:00–03:00
    expect(n.profundo, 60);
    expect(n.leve, 420);
  });

  test('fonte sem estágios perde para a que tem estágios; sem id, estágio liga pela janela da mesma fonte', () {
    final s = agregarSono(
      [
        SessaoSono(t(25, 22), t(26, 8), fonte: 'relogio.do.celular'), // 10 h "na cama", sem estágios
        sessao('a', mi),
      ],
      [for (final e in noite('a', mi)) EstagioSono(e.estagio, e.inicio, e.fim, fonte: mi)], // sem sessaoId
    );
    confereNoite(s['2026-11-26']!);
    expect(s['2026-11-26']!.fontes, [mi]);
  });

  test('janela com várias noites e cochilo: cada noite no dia em que acordou, cochilo soma no seu dia', () {
    final s = agregarSono(
      [
        SessaoSono(t(23, 23), t(24, 6), id: 'n24', fonte: mi),
        SessaoSono(t(24, 23), t(25, 6), id: 'n25', fonte: mi),
        sessao('a', mi),
        sessao('b', fit),
        SessaoSono(t(26, 14), t(26, 14, 40), id: 'cochilo', fonte: mi),
      ],
      [...noite('a', mi), ...noite('b', fit)],
    );
    expect(s.keys.toSet(), {'2026-11-24', '2026-11-25', '2026-11-26'});
    expect(s['2026-11-24']!.total, 420);
    expect(s['2026-11-25']!.total, 420);
    expect(s['2026-11-26']!.total, 461 + 40);
  });

  test('montarDias nunca solta sono > 24 h: tira o sono e registra o problema', () {
    final n = Noite()
      ..total = 1877
      ..profundo = 508
      ..leve = 1369
      ..acordado = 69;
    final problemas = <String>[];
    final d = montarDias(
      datas: ['2026-11-26'],
      passos: {'2026-11-26': 1200},
      calorias: {},
      batimentos: [],
      fcRepouso: [],
      spo2: [],
      sono: {'2026-11-26': n},
      problemas: problemas,
    ).single;
    expect(d.sonoMin, isNull);
    expect(d.passos, 1200);
    expect(problemas.single, contains('1877'));
  });

  group('fila', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('sono'));
    tearDown(() => dir.deleteSync(recursive: true));

    const ruim = AtividadeDia(
        data: '2026-11-26', passos: 1200, sonoMin: 1877, sonoProfundoMin: 508, sonoLeveMin: 1369, acordadoMin: 69);
    const bom = AtividadeDia(data: '2026-11-25', passos: 9000, sonoMin: 377, sonoProfundoMin: 98, sonoLeveMin: 279);

    test('sono inválido salvo é limpo e não volta na mescla; a leitura nova recalculada entra', () async {
      final a = await Armazenamento.abrir(pasta: dir);
      a.gravarAtividade([ruim]);
      expect(a.limparSonoInvalido(), ['2026-11-26']);
      expect(a.atividade['2026-11-26']!.sonoMin, isNull);
      expect(a.atividade['2026-11-26']!.passos, 1200);
      a.gravarAtividade([const AtividadeDia(data: '2026-11-26', sonoMin: 461, sonoProfundoMin: 127, sonoLeveMin: 334, acordadoMin: 17)]);
      expect(a.atividade['2026-11-26']!.sonoMin, 461);
      expect(a.atividade['2026-11-26']!.passos, 1200);
    });

    test('mescla: leitura sem sono não ressuscita o valor impossível', () async {
      final a = await Armazenamento.abrir(pasta: dir);
      a.gravarAtividade([ruim]);
      a.gravarAtividade([const AtividadeDia(data: '2026-11-26', passos: 1500)]);
      expect(a.atividade['2026-11-26']!.sonoMin, isNull);
    });

    test('relê as noites inválidas mesmo se a última leitura boa foi hoje', () {
      final agora = t(26, 7);
      expect(diasParaLer(t(26, 6), agora), 7);
      expect(diasParaLer(t(26, 6), agora, releer: ['2026-11-10']), 17);
    });

    test('um dia recusado não trava os outros: envia sem o sono inválido e, se o lote cair, manda um a um', () async {
      final a = await Armazenamento.abrir(pasta: dir);
      a
        ..apiUrl = 'https://x.dev'
        ..apiKey = 'k'
        ..historicoRecuperado = true;
      // Grava direto no armazenamento (como estava no celular, antes da correção).
      a.gravarAtividade([bom, ruim, const AtividadeDia(data: '2026-11-24', passos: 7000, fcMedia: 300)]);
      final enviados = <String>[];
      http.Response resp(String corpo, int status) =>
          http.Response(corpo, status, headers: {'content-type': 'application/json; charset=utf-8'});
      final api = ApiSaude('https://x.dev', 'k', cliente: MockClient((r) async {
        final dias = (jsonDecode(r.body)['dias'] as List).cast<Map<String, dynamic>>();
        for (final d in dias) {
          if ((d['sono_min'] ?? 0) > 1440) return resp('{"erro":"sono_min fora da faixa (0–1440): ${d['sono_min']}"}', 400);
          if ((d['fc_media'] ?? 0) > 250) return resp('{"erro":"fc_media fora da faixa (20–250): ${d['fc_media']}"}', 400);
        }
        enviados.addAll(dias.map((d) => '${d['data']}'));
        return resp('{"ok":true}', 200);
      }));
      final r = ResultadoSinc();
      await Sincronizacao(a, api: () => api).enviarPendentes(r);
      expect(enviados.toSet(), {'2026-11-25', '2026-11-26'}); // 26 foi sem o sono
      expect(r.erro, contains('2026-11-24'));
      expect(a.atividadePendente().map((d) => d.data), ['2026-11-24']); // só o recusado fica na fila
    });
  });
}
