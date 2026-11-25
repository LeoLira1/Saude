import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saude/data/api.dart';
import 'package:saude/data/modelos.dart';

void main() {
  test('envia com Bearer e no formato do Worker', () async {
    late http.Request pedido;
    final api = ApiSaude('https://x.dev', 'chave1', cliente: MockClient((r) async {
      pedido = r;
      return http.Response('{"ok":true,"inseridas":1,"duplicadas":0}', 200);
    }));
    await api.enviarMedicoes([const Medicao(medidoEm: '2026-11-22 07:15:03', peso: 80.2, impedancia: 500)]);
    expect(pedido.url.toString(), 'https://x.dev/medicao');
    expect(pedido.headers['Authorization'], 'Bearer chave1');
    final corpo = jsonDecode(pedido.body) as Map<String, dynamic>;
    expect((corpo['medicoes'] as List).single['medido_em'], '2026-11-22 07:15:03');
    expect((corpo['medicoes'] as List).single['origem'], 'balanca');
  });

  test('401 vira mensagem clara', () async {
    final api = ApiSaude('https://x.dev', 'errada', cliente: MockClient((_) async => http.Response('{"erro":"chave inválida"}', 401)));
    expect(() => api.ping(), throwsA(isA<ErroApi>().having((e) => e.mensagem, 'msg', contains('Chave'))));
  });

  test('sem chave nem tenta', () async {
    final api = ApiSaude('https://x.dev', '', cliente: MockClient((_) async => fail('não devia chamar')));
    expect(() => api.ping(), throwsA(isA<ErroApi>()));
  });

  test('GET /prato vira PratoDia (sem refeição: última = null)', () async {
    late http.Request pedido;
    final api = ApiSaude('https://x.dev', 'k', cliente: MockClient((r) async {
      pedido = r;
      return http.Response(
          '{"data":"2026-11-23","refeicoes":2,"kcal":1234.5,"ultima_refeicao":"2026-11-23 13:05:00","agua_ml":900,"meta_agua_ml":2500}', 200);
    }));
    final p = await api.baixarPrato('2026-11-23');
    expect(pedido.url.toString(), 'https://x.dev/prato?data=2026-11-23');
    expect(p.temRefeicao, isTrue);
    expect(p.kcal, 1234.5);
    expect(p.ultimaRefeicao, '2026-11-23 13:05:00');
    expect(p.metaAguaMl, 2500);
    final vazio = PratoDia.fromJson({'data': '2026-11-23', 'refeicoes': 0, 'kcal': 0, 'ultima_refeicao': null, 'agua_ml': 0, 'meta_agua_ml': null});
    expect(vazio.temRefeicao, isFalse);
    expect(vazio.metaAguaMl, isNull);
  });

  test('gasto estimado = basal + ativas', () {
    expect(gastoEstimado(basal: 1700, ativas: 450), 2150);
    expect(gastoEstimado(basal: 1700), 1700);
    expect(gastoEstimado(ativas: 450), isNull);
  });
}
