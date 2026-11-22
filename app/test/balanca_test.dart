import 'package:flutter_test/flutter_test.dart';
import 'package:saude/balanca/servico_balanca.dart';
import 'package:saude/core/mi_scale_parser.dart';

LeituraBalanca leitura({double peso = 80, int? imp = 500, bool estab = true, bool rem = false, DateTime? em}) =>
    LeituraBalanca(pesoKg: peso, impedancia: imp, estabilizado: estab, removido: rem, temImpedancia: imp != null, medidoEm: em);

void main() {
  test('a mesma medição repetida pela balança sai uma vez só', () async {
    final s = ServicoBalanca.instancia;
    final recebidas = <LeituraBalanca>[];
    final sub = s.medicoesFinais.listen(recebidas.add);
    final em = DateTime(2026, 11, 22, 7, 15, 3);
    s.processar(leitura(peso: 1, imp: null, estab: false)); // ao vivo
    s.processar(leitura(em: em));
    s.processar(leitura(em: em));
    s.processar(leitura(em: em, rem: true));
    await Future<void>.delayed(Duration.zero);
    expect(recebidas.length, 1);
    expect(s.ultimo.estado, EstadoBalanca.finalizado);

    // Chave já salva antes (app reaberto): não emite.
    s.marcarVistas(['2026-11-22 08:00:00']);
    s.processar(leitura(em: DateTime(2026, 11, 22, 8)));
    await Future<void>.delayed(Duration.zero);
    expect(recebidas.length, 1);

    // Relógio da balança inválido: mesmo peso+impedância em menos de 10 min não repete.
    final t0 = DateTime(2026, 11, 22, 9);
    s.processar(leitura(peso: 79.5, imp: 510), agora: t0);
    s.processar(leitura(peso: 79.5, imp: 510), agora: t0.add(const Duration(minutes: 2)));
    await Future<void>.delayed(Duration.zero);
    expect(recebidas.length, 2);
    await sub.cancel();
  });

  test('saiu antes da impedância mostra aviso', () {
    final s = ServicoBalanca.instancia;
    s.processar(leitura(peso: 70, imp: null, estab: false));
    expect(s.ultimo.estado, EstadoBalanca.medindo);
    s.processar(leitura(peso: 70, imp: null, estab: true));
    expect(s.ultimo.estado, EstadoBalanca.estabilizado);
    s.processar(leitura(peso: 70, imp: null, estab: true, rem: true));
    expect(s.ultimo.estado, EstadoBalanca.erro);
  });
}
