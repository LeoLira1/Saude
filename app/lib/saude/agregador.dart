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

class EstagioSono extends Amostra {
  final Estagio estagio;
  const EstagioSono(this.estagio, DateTime inicio, DateTime fim) : super(inicio, fim);
}

String dataLocal(DateTime d) {
  final l = d.toLocal();
  return '${l.year}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')}';
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

/// Sono de uma noite (já somado por estágio).
class Noite {
  double total = 0, profundo = 0, leve = 0, rem = 0, acordado = 0;
}

/// Soma o sono por data em que acordou.
/// Cada sessão vai para o dia em que terminou; os estágios contam na sessão que os contém.
Map<String, Noite> agregarSono(List<Amostra> sessoes, List<EstagioSono> estagios) {
  final porDia = <String, Noite>{};
  final usados = <EstagioSono>{};
  for (final s in sessoes) {
    if (s.minutos <= 0) continue;
    final dentro = estagios
        .where((e) =>
            !e.inicio.isBefore(s.inicio.subtract(const Duration(minutes: 1))) &&
            !e.fim.isAfter(s.fim.add(const Duration(minutes: 1))))
        .toList();
    usados.addAll(dentro);
    final n = porDia.putIfAbsent(dataLocal(s.fim), Noite.new);
    double prof = 0, lev = 0, rem = 0, acord = 0, dorm = 0;
    for (final e in dentro) {
      switch (e.estagio) {
        case Estagio.profundo:
          prof += e.minutos;
        case Estagio.leve:
          lev += e.minutos;
        case Estagio.rem:
          rem += e.minutos;
        case Estagio.acordado:
          acord += e.minutos;
        case Estagio.dormindo:
          dorm += e.minutos;
      }
    }
    final dormiu = prof + lev + rem + dorm;
    n.total += dormiu > 0 ? dormiu : (s.minutos - acord).clamp(0, 1440);
    n.profundo += prof;
    n.leve += lev;
    n.rem += rem;
    n.acordado += acord;
  }
  // Estágios sem sessão (alguns apps gravam só os estágios): agrupa pelo dia em que terminaram.
  for (final e in estagios.where((e) => !usados.contains(e))) {
    final n = porDia.putIfAbsent(dataLocal(e.fim), Noite.new);
    switch (e.estagio) {
      case Estagio.profundo:
        n.profundo += e.minutos;
        n.total += e.minutos;
      case Estagio.leve:
        n.leve += e.minutos;
        n.total += e.minutos;
      case Estagio.rem:
        n.rem += e.minutos;
        n.total += e.minutos;
      case Estagio.dormindo:
        n.total += e.minutos;
      case Estagio.acordado:
        n.acordado += e.minutos;
    }
  }
  return porDia;
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
int diasParaLer(DateTime? ultimaOk, DateTime agora) {
  if (ultimaOk == null) return 30;
  final a = DateTime(ultimaOk.year, ultimaOk.month, ultimaOk.day);
  final h = DateTime(agora.year, agora.month, agora.day);
  final desde = h.difference(a).inDays + 1;
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
}) {
  Map<String, List<double>> porDia(List<Amostra> l) {
    final m = <String, List<double>>{};
    for (final a in l) {
      m.putIfAbsent(dataLocal(a.inicio), () => []).add(a.valor);
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

  return [
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
}
