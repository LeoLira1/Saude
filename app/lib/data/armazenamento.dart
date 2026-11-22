import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/composicao.dart';
import 'modelos.dart';

/// Endereço padrão do Worker (o nome "saude" vem de worker/wrangler.jsonc).
const String apiPadrao = 'https://saude.dividendos03.workers.dev';

/// Tudo que o app guarda no celular, num arquivo JSON só (funciona sem internet e no segundo plano).
class Armazenamento {
  Armazenamento._(this._arquivo, this._dados);

  final File _arquivo;
  final Map<String, dynamic> _dados;

  static Future<Armazenamento> abrir({Directory? pasta}) async {
    final dir = pasta ?? await getApplicationSupportDirectory();
    final f = File('${dir.path}/saude.json');
    Map<String, dynamic> dados = {};
    if (await f.exists()) {
      try {
        dados = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      } catch (_) {
        // Arquivo corrompido: guarda uma cópia e começa do zero.
        await f.copy('${f.path}.corrompido');
      }
    }
    return Armazenamento._(f, dados);
  }

  Future<void> salvar() async {
    final tmp = File('${_arquivo.path}.tmp');
    await tmp.writeAsString(jsonEncode(_dados), flush: true);
    await tmp.rename(_arquivo.path);
  }

  // ── Perfil e configuração ────────────────────────────────────────────────
  Perfil? get perfil => Perfil.fromJson(_dados['perfil'] as Map<String, dynamic>?);
  set perfil(Perfil? p) => _dados['perfil'] = p?.toJson();

  String get apiUrl => (_dados['api_url'] as String?)?.trim().isNotEmpty == true ? _dados['api_url'] as String : apiPadrao;
  set apiUrl(String v) => _dados['api_url'] = v.trim().replaceAll(RegExp(r'/+$'), '');

  String get apiKey => (_dados['api_key'] as String?) ?? '';
  set apiKey(String v) => _dados['api_key'] = v.trim();

  bool get configurado => perfil != null;

  // ── Medições ─────────────────────────────────────────────────────────────
  List<Medicao> get medicoes {
    final l = ((_dados['medicoes'] as List?) ?? const [])
        .map((e) => Medicao.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    l.sort((a, b) => a.medidoEm.compareTo(b.medidoEm));
    return l;
  }

  /// [m] repete [anterior]: peso e impedância idênticos e [anterior] até 30 min antes.
  static bool ehRepeticao(Medicao m, Medicao anterior) {
    if (m.peso != anterior.peso || m.impedancia != anterior.impedancia) return false;
    final dif = m.data.difference(anterior.data);
    return !dif.isNegative && dif <= const Duration(minutes: 30) && m.medidoEm != anterior.medidoEm;
  }

  /// Medições sem as repetições da balança (para telas e comparações).
  List<Medicao> get medicoesDistintas {
    final r = <Medicao>[];
    for (final m in medicoes) {
      if (m.origem != 'manual' && r.any((x) => ehRepeticao(m, x))) continue;
      r.add(m);
    }
    return r;
  }

  Medicao? get ultimaMedicao {
    final l = medicoes;
    return l.isEmpty ? null : l.last;
  }

  /// Chaves (medido_em) já tratadas: salvas ou recusadas ("não sou eu").
  Set<String> get chavesVistas => {
        ...medicoes.map((m) => m.medidoEm),
        ...((_dados['recusadas'] as List?) ?? const []).map((e) => '$e'),
      };

  /// Guarda a medição e põe na fila de envio. Devolve false se já existia ou se é
  /// repetição da balança (mesma regra do servidor: peso e impedância idênticos nos 30 min anteriores).
  bool adicionarMedicao(Medicao m) {
    final lista = ((_dados['medicoes'] as List?) ?? []).cast<dynamic>().toList();
    if (lista.any((e) => (e as Map)['medido_em'] == m.medidoEm)) return false;
    if (m.origem != 'manual' && medicoes.any((x) => ehRepeticao(m, x))) return false;
    lista.add(m.toJson());
    _dados['medicoes'] = lista;
    final fila = filaMedicoes.toList()..add(m.medidoEm);
    _dados['fila_medicoes'] = fila;
    return true;
  }

  void recusar(String chave) {
    final l = ((_dados['recusadas'] as List?) ?? []).map((e) => '$e').toList();
    if (!l.contains(chave)) l.add(chave);
    if (l.length > 200) l.removeRange(0, l.length - 200);
    _dados['recusadas'] = l;
  }

  void removerMedicaoLocal(String medidoEm) {
    final lista = ((_dados['medicoes'] as List?) ?? []).where((e) => (e as Map)['medido_em'] != medidoEm).toList();
    _dados['medicoes'] = lista;
    _dados['fila_medicoes'] = filaMedicoes.where((k) => k != medidoEm).toList();
  }

  /// Junta medições vindas do servidor (ex.: depois de reinstalar o app).
  int mesclarMedicoes(List<Medicao> doServidor) {
    final lista = ((_dados['medicoes'] as List?) ?? []).cast<dynamic>().toList();
    final existentes = lista.map((e) => (e as Map)['medido_em']).toSet();
    var n = 0;
    for (final m in doServidor) {
      if (existentes.add(m.medidoEm)) {
        lista.add(m.toJson());
        n++;
      }
    }
    _dados['medicoes'] = lista;
    return n;
  }

  List<String> get filaMedicoes => ((_dados['fila_medicoes'] as List?) ?? const []).map((e) => '$e').toList();

  void tirarDaFila(Iterable<String> enviadas) {
    final s = enviadas.toSet();
    _dados['fila_medicoes'] = filaMedicoes.where((k) => !s.contains(k)).toList();
  }

  // ── Atividade (pulseira) ─────────────────────────────────────────────────
  Map<String, AtividadeDia> get atividade {
    final m = (_dados['atividade'] as Map?) ?? const {};
    return {
      for (final e in m.entries) '${e.key}': AtividadeDia.fromJson(Map<String, dynamic>.from(e.value as Map)),
    };
  }

  void gravarAtividade(Iterable<AtividadeDia> dias) {
    final m = Map<String, dynamic>.from((_dados['atividade'] as Map?) ?? {});
    for (final d in dias) {
      m[d.data] = d.toJson();
    }
    _dados['atividade'] = m;
  }

  /// "Impressão digital" do que já foi enviado por dia: só reenvia o que mudou.
  Map<String, String> get enviadosAtividade => Map<String, String>.from((_dados['enviados_atividade'] as Map?) ?? {});

  void marcarAtividadeEnviada(Iterable<AtividadeDia> dias) {
    final m = enviadosAtividade;
    for (final d in dias) {
      m[d.data] = jsonEncode(d.toJson());
    }
    // Guarda só os últimos 120 dias.
    final chaves = m.keys.toList()..sort();
    if (chaves.length > 120) {
      for (final k in chaves.take(chaves.length - 120)) {
        m.remove(k);
      }
    }
    _dados['enviados_atividade'] = m;
  }

  List<AtividadeDia> atividadePendente() {
    final enviados = enviadosAtividade;
    return atividade.values.where((d) => !d.vazio && enviados[d.data] != jsonEncode(d.toJson())).toList()
      ..sort((a, b) => a.data.compareTo(b.data));
  }

  DateTime? get ultimaSincSaude => DateTime.tryParse('${_dados['ultima_sinc_saude']}');
  set ultimaSincSaude(DateTime? d) => _dados['ultima_sinc_saude'] = d?.toIso8601String();

  String? get ultimoErro => _dados['ultimo_erro'] as String?;
  set ultimoErro(String? e) => _dados['ultimo_erro'] = e;

  bool get historicoRecuperado => _dados['historico_recuperado'] == true;
  set historicoRecuperado(bool v) => _dados['historico_recuperado'] = v;
}
