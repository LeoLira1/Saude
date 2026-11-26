import '../data/modelos.dart';

/// Um registro lido do Health Connect, já simplificado (sem depender do pacote `health`).
class Amostra {
  final DateTime inicio;
  final DateTime fim;
  final double valor;
  const Amostra(this.inicio, this.fim, [this.valor = 0]);

  double get minutos => fim.difference(inicio).inMilliseconds / 60000.0;
}

enum Estagio { acordado, leve, profundo, rem, dormindo }

/// Sessão de sono do Health Connect. [id] = id do registro; [fonte] = pacote do app que gravou.
class SessaoSono extends Amostra {
  final String? id;
  final String? fonte;
  const SessaoSono(super.inicio, super.fim, {this.id, this.fonte});
}

/// Estágio de sono. [sessaoId] = id da sessão a que pertence (o plugin manda o id da sessão em cada estágio).
class EstagioSono extends Amostra {
  final Estagio estagio;
  final String? sessaoId;
  final String? fonte;
  const EstagioSono(this.estagio, DateTime inicio, DateTime fim, {this.sessaoId, this.fonte}) : super(inicio, fim);
}

/// Brasília (America/Sao_Paulo): UTC−3 o ano todo (sem horário de verão desde 2019).
const fusoBrasilia = Duration(hours: 3);

/// O mesmo instante, com os campos (ano, mês, dia, hora) no relógio de Brasília.
DateTime emBrasilia(DateTime d) => d.toUtc().subtract(fusoBrasilia);

/// "AAAA-MM-DD" do dia em Brasília a que o instante pertence (não depende do fuso do celular).
String dataBrasilia(DateTime d) {
  final l = emBrasilia(d);
  return '${l.year}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')}';
}

/// 00:00 em Brasília do dia que contém o instante.
DateTime inicioDiaBrasilia(DateTime d) {
  final l = emBrasilia(d);
  return DateTime.utc(l.year, l.month, l.day).add(fusoBrasilia);
}

double? _media(Iterable<double> v) {
  final l = v.toList();
  if (l.isEmpty) return null;
  return l.reduce((a, b) => a + b) / l.length;
}

double? _r(double? v, [int casas = 1]) {
  if (v == null || v.isNaN || v.isInfinite) return null;
  final f = casas == 0 ? 1 : (casas == 1 ? 10 : 100);
  return (v * f).roundToDouble() / f;
}

/// Sono de uma noite (já somado por estágio). [total] = tempo dormindo (sem o tempo acordado).
class Noite {
  double total = 0, profundo = 0, leve = 0, rem = 0, acordado = 0;

  /// Fonte (pacote do app) usada em cada episódio de sono do dia; as outras fontes foram descartadas.
  final List<String> fontes = [];
}

String? _fonteDe(Amostra a) => a is SessaoSono ? a.fonte : (a is EstagioSono ? a.fonte : null);

/// Um pedaço de sono: uma sessão com os estágios dela, ou um estágio solto (sem sessão).
class _Bloco {
  _Bloco(this.inicio, this.fim, this.fonte, {this.temSessao = true});
  DateTime inicio, fim;
  final String fonte;
  final bool temSessao;
  final List<EstagioSono> estagios = [];
}

/// Na mesma fatia de tempo, se houver estágios sobrepostos da mesma fonte, vale o de maior prioridade
/// (acordado primeiro: na dúvida não infla o sono).
const _prioridade = [Estagio.acordado, Estagio.profundo, Estagio.rem, Estagio.leve, Estagio.dormindo];

/// Soma o sono por data em que acordou, sem contar o mesmo intervalo duas vezes.
///
/// 1. Cada estágio pertence a UMA sessão: a do id que o Health Connect manda junto (ou, sem id, a primeira
///    sessão da mesma fonte que o contém). Estágio sem sessão vira um bloco solto.
/// 2. Blocos que se sobrepõem no tempo são o mesmo episódio de sono (mesma noite gravada duas vezes, por
///    duas fontes ou pela mesma). De cada episódio fica só uma fonte: a que tem mais tempo com estágio.
/// 3. Dentro da fonte escolhida, a linha do tempo é varrida em fatias: cada minuto conta uma vez só.
/// 4. O episódio vai para o dia (Brasília) em que terminou. Total = profundo + leve + REM + "dormindo";
///    o tempo acordado fica à parte.
Map<String, Noite> agregarSono(List<Amostra> sessoes, List<EstagioSono> estagios) {
  // Registros repetidos idênticos (mesma fonte, mesmo intervalo) contam uma vez.
  final vistosS = <String>{};
  final blocos = <_Bloco>[];
  final porId = <String, _Bloco>{};
  for (final s in sessoes) {
    if (s.minutos <= 0) continue;
    final fonte = _fonteDe(s) ?? '';
    if (!vistosS.add('$fonte|${s.inicio.toUtc()}|${s.fim.toUtc()}')) continue;
    final b = _Bloco(s.inicio, s.fim, fonte);
    blocos.add(b);
    final id = s is SessaoSono ? s.id : null;
    if (id != null && id.isNotEmpty) porId[id] = b;
  }
  final vistosE = <String>{};
  const folga = Duration(minutes: 1);
  for (final e in estagios) {
    if (e.minutos <= 0) continue;
    final fonte = e.fonte ?? '';
    if (!vistosE.add('$fonte|${e.estagio.name}|${e.inicio.toUtc()}|${e.fim.toUtc()}')) continue;
    var dono = e.sessaoId == null ? null : porId[e.sessaoId];
    dono ??= blocos.where((b) => b.temSessao && b.fonte == fonte).where((b) =>
        !e.inicio.isBefore(b.inicio.subtract(folga)) && !e.fim.isAfter(b.fim.add(folga))).firstOrNull;
    if (dono == null) {
      dono = _Bloco(e.inicio, e.fim, fonte, temSessao: false);
      blocos.add(dono);
    }
    dono.estagios.add(e);
    // O estágio pode passar um pouco da sessão (folga): o bloco cobre os dois.
    if (e.inicio.isBefore(dono.inicio)) dono.inicio = e.inicio;
    if (e.fim.isAfter(dono.fim)) dono.fim = e.fim;
  }

  // Episódios: blocos que se sobrepõem (de qualquer fonte).
  blocos.sort((a, b) => a.inicio.compareTo(b.inicio));
  final episodios = <List<_Bloco>>[];
  DateTime? fimAtual;
  for (final b in blocos) {
    if (fimAtual == null || !b.inicio.isBefore(fimAtual)) {
      episodios.add([b]);
      fimAtual = b.fim;
    } else {
      episodios.last.add(b);
      if (b.fim.isAfter(fimAtual)) fimAtual = b.fim;
    }
  }

  final porDia = <String, Noite>{};
  for (final ep in episodios) {
    final fontes = {for (final b in ep) b.fonte};
    final medidas = {for (final f in fontes) f: _medir(ep.where((b) => b.fonte == f).toList())};
    // Fonte escolhida: mais tempo com estágio; empate → mais tempo dormindo; depois ordem alfabética (estável).
    final f = (fontes.toList()..sort()).reduce((a, b) {
      final ma = medidas[a]!, mb = medidas[b]!;
      if (mb.comEstagio != ma.comEstagio) return mb.comEstagio > ma.comEstagio ? b : a;
      if (mb.n.total != ma.n.total) return mb.n.total > ma.n.total ? b : a;
      return a;
    });
    final m = medidas[f]!;
    if (m.n.total <= 0 && m.n.acordado <= 0) continue;
    final n = porDia.putIfAbsent(dataBrasilia(m.fim), Noite.new);
    n.total += m.n.total;
    n.profundo += m.n.profundo;
    n.leve += m.n.leve;
    n.rem += m.n.rem;
    n.acordado += m.n.acordado;
    if (f.isNotEmpty && !n.fontes.contains(f)) n.fontes.add(f);
  }
  return porDia;
}

/// Mede um episódio de uma fonte só, varrendo a linha do tempo: cada fatia conta uma vez.
/// Fatia com estágio → aquele estágio; sem estágio, mas dentro de uma sessão que não tem nenhum estágio →
/// "dormindo"; sem nada → não conta (buraco entre estágios não vira sono).
({Noite n, double comEstagio, DateTime fim}) _medir(List<_Bloco> bs) {
  final cortes = <DateTime>{};
  final estagios = <EstagioSono>[];
  final semEstagio = <_Bloco>[];
  var fim = bs.first.fim;
  for (final b in bs) {
    if (b.fim.isAfter(fim)) fim = b.fim;
    if (b.estagios.isEmpty) {
      semEstagio.add(b);
      cortes..add(b.inicio)..add(b.fim);
    }
    for (final e in b.estagios) {
      estagios.add(e);
      cortes..add(e.inicio)..add(e.fim);
    }
  }
  final pts = cortes.toList()..sort();
  final n = Noite();
  double comEstagio = 0;
  for (var i = 0; i + 1 < pts.length; i++) {
    final a = pts[i], b = pts[i + 1];
    final min = b.difference(a).inMilliseconds / 60000.0;
    if (min <= 0) continue;
    final aqui = estagios.where((e) => !e.inicio.isAfter(a) && !e.fim.isBefore(b)).map((e) => e.estagio).toSet();
    Estagio? est;
    if (aqui.isNotEmpty) {
      est = _prioridade.firstWhere(aqui.contains);
      comEstagio += min;
    } else if (semEstagio.any((s) => !s.inicio.isAfter(a) && !s.fim.isBefore(b))) {
      est = Estagio.dormindo;
    }
    switch (est) {
      case Estagio.profundo:
        n.profundo += min;
        n.total += min;
      case Estagio.leve:
        n.leve += min;
        n.total += min;
      case Estagio.rem:
        n.rem += min;
        n.total += min;
      case Estagio.dormindo:
        n.total += min;
      case Estagio.acordado:
        n.acordado += min;
      case null:
        break;
    }
  }
  return (n: n, comEstagio: comEstagio, fim: fim);
}

/// FC de repouso quando o Health Connect não tem o registro próprio:
/// média dos 10% menores batimentos do dia (precisa de pelo menos 20 amostras).
double? fcRepousoEstimada(List<double> batimentos) {
  if (batimentos.length < 20) return null;
  final l = [...batimentos]..sort();
  final n = (l.length * 0.1).ceil();
  return _media(l.take(n));
}

/// Quantos dias reler: desde a última leitura bem-sucedida (incluindo aquele dia, que pode ter ficado
/// incompleto), no mínimo 7 e no máximo 30 (limite do Health Connect sem permissão de histórico).
/// [releer]: datas ("AAAA-MM-DD") que precisam ser relidas de qualquer jeito (ex.: sono inválido na fila).
int diasParaLer(DateTime? ultimaOk, DateTime agora, {Iterable<String> releer = const []}) {
  if (ultimaOk == null) return 30;
  var desde = inicioDiaBrasilia(agora).difference(inicioDiaBrasilia(ultimaOk)).inDays + 1;
  final hoje = DateTime.parse(dataBrasilia(agora));
  for (final d in releer) {
    final x = DateTime.tryParse(d);
    if (x != null) desde = desde < hoje.difference(x).inDays + 1 ? hoje.difference(x).inDays + 1 : desde;
  }
  return desde.clamp(7, 30);
}

/// Monta os dias a partir do que foi lido.
List<AtividadeDia> montarDias({
  required List<String> datas,
  required Map<String, int> passos,
  required Map<String, double> calorias,
  required List<Amostra> batimentos,
  required List<Amostra> fcRepouso,
  required List<Amostra> spo2,
  required Map<String, Noite> sono,
  /// "AAAA-MM-DD" de hoje: a FC de repouso NÃO é estimada para hoje (dia incompleto distorce).
  String? hoje,
  /// Recebe as mensagens dos dias cujo sono foi descartado por ser impossível.
  List<String>? problemas,
}) {
  Map<String, List<double>> porDia(List<Amostra> l) {
    final m = <String, List<double>>{};
    for (final a in l) {
      m.putIfAbsent(dataBrasilia(a.inicio), () => []).add(a.valor);
    }
    return m;
  }

  final hr = porDia(batimentos);
  final rhr = porDia(fcRepouso);
  final ox = porDia(spo2);

  ({double? valor, bool? estimada}) repouso(String d) {
    final real = _media(rhr[d] ?? const []);
    if (real != null) return (valor: _r(real, 0), estimada: false);
    if (hoje != null && d.compareTo(hoje) >= 0) return (valor: null, estimada: null);
    final est = fcRepousoEstimada(hr[d] ?? const []);
    return est == null ? (valor: null, estimada: null) : (valor: _r(est, 0), estimada: true);
  }

  final dias = [
    for (final d in datas)
      AtividadeDia(
        data: d,
        passos: passos[d],
        calorias: _r(calorias[d], 0),
        fcRepouso: repouso(d).valor,
        fcRepousoEstimada: repouso(d).estimada,
        fcMedia: _r(_media(hr[d] ?? const []), 0),
        sonoMin: sono[d] == null || sono[d]!.total <= 0 ? null : _r(sono[d]!.total, 0),
        sonoProfundoMin: sono[d] == null || sono[d]!.total <= 0 ? null : _r(sono[d]!.profundo, 0),
        sonoLeveMin: sono[d] == null || sono[d]!.total <= 0 ? null : _r(sono[d]!.leve, 0),
        sonoRemMin: sono[d] == null || sono[d]!.total <= 0 ? null : _r(sono[d]!.rem, 0),
        acordadoMin: sono[d] == null || sono[d]!.total <= 0 ? null : _r(sono[d]!.acordado, 0),
        // O Health Connect guarda SpO2 em %; se vier fração (0–1), converte.
        spo2Medio: _r(_media((ox[d] ?? const []).map((v) => v <= 1 ? v * 100 : v))),
      ),
  ];
  // Última barreira: sono impossível não sai do app (o servidor recusaria o lote inteiro).
  // O dia segue sem o sono e o problema vai para [problemas].
  for (var i = 0; i < dias.length; i++) {
    final p = dias[i].problemaSono;
    if (p == null) continue;
    problemas?.add('SLEEP ${dias[i].data}: $p');
    dias[i] = dias[i].semSono();
  }
  return dias;
}
