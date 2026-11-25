import 'dart:convert';

import 'package:http/http.dart' as http;

import 'modelos.dart';

class ErroApi implements Exception {
  final String mensagem;
  ErroApi(this.mensagem);
  @override
  String toString() => mensagem;
}

/// Cliente do Worker (POST /medicao, POST /atividade, GET /medicoes, GET /atividade, GET /prato).
class ApiSaude {
  ApiSaude(this.base, this.chave, {http.Client? cliente}) : _http = cliente ?? http.Client();

  final String base;
  final String chave;
  final http.Client _http;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $chave',
        'Content-Type': 'application/json',
      };

  Future<Map<String, dynamic>> _req(String metodo, String caminho, [Object? corpo]) async {
    if (chave.isEmpty) throw ErroApi('Chave da API não configurada (Ajustes).');
    final uri = Uri.parse('$base$caminho');
    final http.Response r;
    try {
      r = metodo == 'GET'
          ? await _http.get(uri, headers: _headers).timeout(const Duration(seconds: 25))
          : await _http.post(uri, headers: _headers, body: jsonEncode(corpo)).timeout(const Duration(seconds: 25));
    } catch (e) {
      throw ErroApi('Sem conexão com o servidor.');
    }
    Map<String, dynamic> j;
    try {
      j = jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      j = {'erro': r.body};
    }
    if (r.statusCode == 401) throw ErroApi('Chave da API recusada pelo servidor (confira em Ajustes).');
    if (r.statusCode >= 400) throw ErroApi('Servidor: ${j['erro'] ?? r.statusCode}');
    return j;
  }

  Future<void> ping() => _req('GET', '/ping');

  Future<Map<String, dynamic>> enviarMedicoes(List<Medicao> ms) =>
      _req('POST', '/medicao', {'medicoes': ms.map((m) => m.toJson()).toList()});

  Future<Map<String, dynamic>> enviarAtividade(List<AtividadeDia> dias) =>
      _req('POST', '/atividade', {'dias': dias.map((d) => d.toJson()).toList()});

  Future<List<Medicao>> baixarMedicoes({String desde = '1900-01-01'}) async {
    final j = await _req('GET', '/medicoes?desde=$desde');
    return ((j['medicoes'] as List?) ?? const [])
        .map((e) => Medicao.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// Refeições (kcal, última refeição) e água do dia [data] (AAAA-MM-DD, horário de Brasília).
  Future<PratoDia> baixarPrato(String data) async =>
      PratoDia.fromJson(await _req('GET', '/prato?data=$data'));

  Future<List<AtividadeDia>> baixarAtividade({String desde = '1900-01-01'}) async {
    final j = await _req('GET', '/atividade?desde=$desde');
    return ((j['dias'] as List?) ?? const [])
        .map((e) => AtividadeDia.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }
}
