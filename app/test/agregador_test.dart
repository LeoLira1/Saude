import 'package:flutter_test/flutter_test.dart';
import 'package:saude/saude/agregador.dart';

void main() {
  DateTime t(int dia, int h, [int m = 0]) => DateTime.utc(2026, 11, dia, h + 3, m); // hora de Brasília

  test('sono vai para o dia em que acordou e soma os estágios da sessão', () {
    final sessoes = [Amostra(t(21, 23), t(22, 7))]; // 8 h na cama
    final estagios = [
      EstagioSono(Estagio.leve, t(21, 23), t(22, 1)), // 120
      EstagioSono(Estagio.profundo, t(22, 1), t(22, 2, 30)), // 90
      EstagioSono(Estagio.rem, t(22, 2, 30), t(22, 4)), // 90
      EstagioSono(Estagio.acordado, t(22, 4), t(22, 4, 20)), // 20
      EstagioSono(Estagio.leve, t(22, 4, 20), t(22, 7)), // 160
    ];
    final s = agregarSono(sessoes, estagios);
    expect(s.keys, ['2026-11-22']);
    final n = s['2026-11-22']!;
    expect(n.total, 460);
    expect(n.leve, 280);
    expect(n.profundo, 90);
    expect(n.rem, 90);
    expect(n.acordado, 20);
  });

  test('sessão sem estágios: total = duração', () {
    final s = agregarSono([Amostra(t(22, 0), t(22, 6, 30))], const []);
    expect(s['2026-11-22']!.total, 390);
  });

  test('cochilo à tarde soma no mesmo dia', () {
    final s = agregarSono([Amostra(t(21, 23), t(22, 6)), Amostra(t(22, 14), t(22, 14, 40))], const []);
    expect(s['2026-11-22']!.total, 420 + 40);
  });

  test('FC de repouso estimada = média dos 10% menores', () {
    final bpm = [for (var i = 0; i < 100; i++) 50.0 + i]; // 50..149
    expect(fcRepousoEstimada(bpm), closeTo(54.5, 1e-9)); // média de 50..59
    expect(fcRepousoEstimada([60, 70]), isNull);
  });

  test('montarDias junta tudo e converte SpO2 em fração', () {
    final dias = montarDias(
      datas: ['2026-11-22'],
      passos: {'2026-11-22': 8123},
      calorias: {'2026-11-22': 345.6},
      batimentos: [Amostra(t(22, 10), t(22, 10), 70), Amostra(t(22, 11), t(22, 11), 80)],
      fcRepouso: [Amostra(t(22, 6), t(22, 6), 58)],
      spo2: [Amostra(t(22, 3), t(22, 3), 0.96), Amostra(t(22, 4), t(22, 4), 98)],
      sono: agregarSono([Amostra(t(21, 23), t(22, 6))], const []),
    );
    final d = dias.single;
    expect(d.passos, 8123);
    expect(d.calorias, 346);
    expect(d.fcMedia, 75);
    expect(d.fcRepouso, 58);
    expect(d.spo2Medio, 97);
    expect(d.sonoMin, 420);
  });

  test('dia sem nada fica vazio', () {
    final d = montarDias(datas: ['2026-11-20'], passos: {}, calorias: {}, batimentos: [], fcRepouso: [], spo2: [], sono: {}).single;
    expect(d.vazio, isTrue);
  });
}
