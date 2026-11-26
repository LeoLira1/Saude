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
  Sincronizacao(this.arm, {ApiSaude Function()? api}) : _criarApi = api;
  final Armazenamento arm;
  final ApiSaude Function()? _criarApi;

  ApiSaude get _api => _criarApi?.call() ?? ApiSaude(arm.apiUrl, arm.apiKey);

  /// [origem]: noturna, reserva diária, ao abrir, ao sair, manual. Fica registrada para os Ajustes.
  Future<ResultadoSinc> tudo({bool lerSaude = true, String? origem}) async {
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
          // Noites com sono impossível já salvas (ex.: 31 h): tira o valor e relê essas datas para recalcular.
          final releer = arm.limparSonoInvalido();
          final dias = diasParaLer(arm.ultimaSincSaude, DateTime.now(), releer: releer);
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
    if (origem != null) {
      arm.registrarSinc(
        origem: origem,
        ok: r.saudeOk && r.erro == null,
        erro: r.erro,
        diasLidos: r.diasLidos,
        diasEnviados: r.diasEnviados,
      );
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
      // Sono impossível nunca sai do app: limpa e manda o dia sem ele (o servidor mantém o que já tinha).
      arm.limparSonoInvalido();
      final pend = arm.atividadePendente();
      final recusados = <String>[];
      for (var i = 0; i < pend.length; i += 100) {
        final lote = pend.sublist(i, (i + 100).clamp(0, pend.length));
        try {
          await _api.enviarAtividade(lote);
          arm.marcarAtividadeEnviada(lote);
          r.diasEnviados += lote.length;
        } on ErroApi catch (e) {
          // Sem conexão ou chave errada: tenta tudo de novo na próxima.
          if (!e.mensagem.startsWith('Servidor:')) rethrow;
          // O servidor recusa o lote inteiro por um dia ruim: manda um a um para os outros passarem.
          if (lote.length == 1) {
            recusados.add('${lote.single.data}: ${e.mensagem}');
            continue;
          }
          for (final d in lote) {
            try {
              await _api.enviarAtividade([d]);
              arm.marcarAtividadeEnviada([d]);
              r.diasEnviados++;
            } on ErroApi catch (e1) {
              if (!e1.mensagem.startsWith('Servidor:')) rethrow;
              recusados.add('${d.data}: ${e1.mensagem}');
            }
          }
        }
      }
      if (recusados.isNotEmpty) throw ErroApi('Recusado pelo servidor — ${recusados.join('; ')}');
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
