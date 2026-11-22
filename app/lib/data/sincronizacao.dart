import '../saude/agregador.dart';
import '../saude/health_sync.dart';
import 'api.dart';
import 'armazenamento.dart';

class ResultadoSinc {
  int medicoesEnviadas = 0;
  int diasEnviados = 0;
  int diasLidos = 0;
  String? erro;

  /// Leitura do Health Connect aconteceu e trouxe os dados principais (passos e sono) sem erro.
  bool saudeOk = false;
  @override
  String toString() => 'medições: $medicoesEnviadas, dias lidos: $diasLidos, dias enviados: $diasEnviados, erro: $erro';
}

/// Lê o Health Connect, guarda localmente e envia ao Worker só o que é novo.
/// Usada ao abrir o app e pela tarefa diária em segundo plano.
class Sincronizacao {
  Sincronizacao(this.arm);
  final Armazenamento arm;

  ApiSaude get _api => ApiSaude(arm.apiUrl, arm.apiKey);

  Future<ResultadoSinc> tudo({bool lerSaude = true, bool segundoPlano = false}) async {
    final r = ResultadoSinc();
    if (lerSaude) {
      try {
        final hs = HealthSync.instancia;
        if (!await hs.disponivel()) {
          r.erro = 'Health Connect não disponível';
        } else if (!await hs.temPermissao()) {
          r.erro = 'Sem permissão de leitura no Health Connect';
        } else {
          // Relê desde a última leitura boa (mín. 7, máx. 30 dias): recupera os dias em que nada sincronizou.
          final dias = diasParaLer(arm.ultimaSincSaude, DateTime.now());
          final lidos = await hs.lerDias(dias);
          arm.gravarAtividade(lidos.where((d) => !d.vazio));
          r.diasLidos = lidos.length;
          // Só conta como leitura boa se passos e sono vieram sem erro (senão, a próxima relê esses dias).
          final principais = hs.erros.where((e) => e.startsWith('STEPS') || e.startsWith('SLEEP'));
          r.saudeOk = principais.isEmpty;
          if (r.saudeOk) arm.ultimaSincSaude = DateTime.now();
          if (hs.erros.isNotEmpty) r.erro = 'Health Connect: ${hs.erros.first}${hs.erros.length > 1 ? ' (+${hs.erros.length - 1})' : ''}';
        }
      } catch (e) {
        r.erro = 'Health Connect: $e';
      }
    }
    await arm.salvar();
    await enviarPendentes(r);
    if (segundoPlano) {
      arm.statusSegundoPlano = {
        'quando': DateTime.now().toIso8601String(),
        'ok': r.saudeOk && r.erro == null,
        'dias_lidos': r.diasLidos,
        'dias_enviados': r.diasEnviados,
        'erro': r.erro,
      };
    }
    await arm.salvar();
    return r;
  }

  Future<void> enviarPendentes([ResultadoSinc? r]) async {
    r ??= ResultadoSinc();
    if (arm.apiKey.isEmpty) {
      r.erro ??= 'Chave da API não configurada';
      arm.ultimoErro = r.erro;
      return;
    }
    try {
      await recuperarHistorico();
      final fila = arm.filaMedicoes.toSet();
      final ms = arm.medicoes.where((m) => fila.contains(m.medidoEm)).toList();
      // Chaves que estão na fila mas cuja medição foi apagada: limpa.
      arm.tirarDaFila(fila.difference(ms.map((m) => m.medidoEm).toSet()));
      for (var i = 0; i < ms.length; i += 100) {
        final lote = ms.sublist(i, (i + 100).clamp(0, ms.length));
        await _api.enviarMedicoes(lote);
        arm.tirarDaFila(lote.map((m) => m.medidoEm));
        r.medicoesEnviadas += lote.length;
      }
      final pend = arm.atividadePendente();
      for (var i = 0; i < pend.length; i += 100) {
        final lote = pend.sublist(i, (i + 100).clamp(0, pend.length));
        await _api.enviarAtividade(lote);
        arm.marcarAtividadeEnviada(lote);
        r.diasEnviados += lote.length;
      }
      arm.ultimoErro = null;
    } catch (e) {
      r.erro = '$e';
      arm.ultimoErro = '$e';
    }
  }

  /// Uma vez só: se o celular está sem histórico (app reinstalado), baixa do servidor.
  Future<void> recuperarHistorico() async {
    if (arm.historicoRecuperado) return;
    final api = _api;
    if (arm.medicoes.isEmpty) {
      arm.mesclarMedicoes(await api.baixarMedicoes());
    }
    if (arm.atividade.isEmpty) {
      final dias = await api.baixarAtividade();
      arm.gravarAtividade(dias);
      arm.marcarAtividadeEnviada(dias);
    }
    arm.historicoRecuperado = true;
  }
}
