/// Medição da balança (ou manual), no mesmo formato da tabela `medicoes` do Worker.
class Medicao {
  final String medidoEm; // "AAAA-MM-DD HH:MM:SS", horário local
  final double peso;
  final int? impedancia;
  final double? imc;
  final double? gorduraPct;
  final double? aguaPct;
  final double? musculoKg;
  final double? ossoKg;
  final double? visceral;
  final double? metabolismoKcal;
  final double? proteinaPct;
  final String origem;

  const Medicao({
    required this.medidoEm,
    required this.peso,
    this.impedancia,
    this.imc,
    this.gorduraPct,
    this.aguaPct,
    this.musculoKg,
    this.ossoKg,
    this.visceral,
    this.metabolismoKcal,
    this.proteinaPct,
    this.origem = 'balanca',
  });

  DateTime get data => DateTime.parse(medidoEm.replaceFirst(' ', 'T'));

  Map<String, dynamic> toJson() => {
        'medido_em': medidoEm,
        'peso': peso,
        'impedancia': impedancia,
        'imc': imc,
        'gordura_pct': gorduraPct,
        'agua_pct': aguaPct,
        'musculo_kg': musculoKg,
        'osso_kg': ossoKg,
        'visceral': visceral,
        'metabolismo_kcal': metabolismoKcal,
        'proteina_pct': proteinaPct,
        'origem': origem,
      };

  static double? _d(dynamic v) => v is num ? v.toDouble() : null;

  factory Medicao.fromJson(Map<String, dynamic> j) => Medicao(
        medidoEm: '${j['medido_em']}',
        peso: (j['peso'] as num).toDouble(),
        impedancia: (j['impedancia'] as num?)?.round(),
        imc: _d(j['imc']),
        gorduraPct: _d(j['gordura_pct']),
        aguaPct: _d(j['agua_pct']),
        musculoKg: _d(j['musculo_kg']),
        ossoKg: _d(j['osso_kg']),
        visceral: _d(j['visceral']),
        metabolismoKcal: _d(j['metabolismo_kcal']),
        proteinaPct: _d(j['proteina_pct']),
        origem: '${j['origem'] ?? 'balanca'}',
      );
}

/// Resumo de um dia da pulseira, no formato da tabela `atividade_diaria`.
/// O sono fica na data em que você acordou.
class AtividadeDia {
  final String data; // AAAA-MM-DD
  final int? passos;
  final double? calorias;
  final double? fcRepouso;

  /// true = FC de repouso calculada pelo app (o Mi Fitness não mandou a dele); false = a do Health Connect.
  final bool? fcRepousoEstimada;
  final double? fcMedia;
  final double? sonoMin;
  final double? sonoProfundoMin;
  final double? sonoLeveMin;
  final double? sonoRemMin;
  final double? acordadoMin;
  final double? spo2Medio;

  const AtividadeDia({
    required this.data,
    this.passos,
    this.calorias,
    this.fcRepouso,
    this.fcRepousoEstimada,
    this.fcMedia,
    this.sonoMin,
    this.sonoProfundoMin,
    this.sonoLeveMin,
    this.sonoRemMin,
    this.acordadoMin,
    this.spo2Medio,
  });

  /// Junta com o que já estava salvo: campo que veio vazio nesta leitura mantém o valor anterior
  /// (ex.: uma leitura em segundo plano que falhou só para passos não apaga os passos do dia).
  AtividadeDia mesclarSobre(AtividadeDia? antigo) {
    if (antigo == null) return this;
    final usaFcNova = fcRepouso != null;
    return AtividadeDia(
      data: data,
      passos: passos ?? antigo.passos,
      calorias: calorias ?? antigo.calorias,
      fcRepouso: usaFcNova ? fcRepouso : antigo.fcRepouso,
      fcRepousoEstimada: usaFcNova ? fcRepousoEstimada : antigo.fcRepousoEstimada,
      fcMedia: fcMedia ?? antigo.fcMedia,
      sonoMin: sonoMin ?? antigo.sonoMin,
      sonoProfundoMin: sonoMin != null ? sonoProfundoMin : antigo.sonoProfundoMin,
      sonoLeveMin: sonoMin != null ? sonoLeveMin : antigo.sonoLeveMin,
      sonoRemMin: sonoMin != null ? sonoRemMin : antigo.sonoRemMin,
      acordadoMin: sonoMin != null ? acordadoMin : antigo.acordadoMin,
      spo2Medio: spo2Medio ?? antigo.spo2Medio,
    );
  }

  /// Por que o sono deste dia é impossível (o servidor recusaria), ou null se está ok.
  /// Regras: cada campo entre 0 e 1440 min, e profundo + leve + REM não passa do total (tolerância de
  /// arredondamento). O total já não inclui o tempo acordado.
  String? get problemaSono {
    final campos = {
      'sono_min': sonoMin,
      'sono_profundo_min': sonoProfundoMin,
      'sono_leve_min': sonoLeveMin,
      'sono_rem_min': sonoRemMin,
      'acordado_min': acordadoMin,
    };
    for (final e in campos.entries) {
      final v = e.value;
      if (v != null && (v.isNaN || v < 0 || v > 1440)) return '${e.key} fora da faixa (0–1440): ${v.round()}';
    }
    final estagios = (sonoProfundoMin ?? 0) + (sonoLeveMin ?? 0) + (sonoRemMin ?? 0);
    if (sonoMin != null && estagios > sonoMin! + 3) {
      return 'estágios (${estagios.round()} min) passam do total (${sonoMin!.round()} min)';
    }
    return null;
  }

  /// O mesmo dia sem os campos de sono (os outros campos seguem).
  AtividadeDia semSono() => AtividadeDia(
        data: data,
        passos: passos,
        calorias: calorias,
        fcRepouso: fcRepouso,
        fcRepousoEstimada: fcRepousoEstimada,
        fcMedia: fcMedia,
        spo2Medio: spo2Medio,
      );

  bool get vazio =>
      passos == null &&
      calorias == null &&
      fcRepouso == null &&
      fcMedia == null &&
      sonoMin == null &&
      spo2Medio == null;

  Map<String, dynamic> toJson() => {
        'data': data,
        'passos': passos,
        'calorias': calorias,
        'fc_repouso': fcRepouso,
        'fc_repouso_estimada': fcRepousoEstimada == null ? null : (fcRepousoEstimada! ? 1 : 0),
        'fc_media': fcMedia,
        'sono_min': sonoMin,
        'sono_profundo_min': sonoProfundoMin,
        'sono_leve_min': sonoLeveMin,
        'sono_rem_min': sonoRemMin,
        'acordado_min': acordadoMin,
        'spo2_medio': spo2Medio,
      };

  static double? _d(dynamic v) => v is num ? v.toDouble() : null;

  factory AtividadeDia.fromJson(Map<String, dynamic> j) => AtividadeDia(
        data: '${j['data']}',
        passos: (j['passos'] as num?)?.round(),
        calorias: _d(j['calorias']),
        fcRepouso: _d(j['fc_repouso']),
        fcRepousoEstimada: j['fc_repouso_estimada'] == null ? null : (j['fc_repouso_estimada'] == 1 || j['fc_repouso_estimada'] == true),
        fcMedia: _d(j['fc_media']),
        sonoMin: _d(j['sono_min']),
        sonoProfundoMin: _d(j['sono_profundo_min']),
        sonoLeveMin: _d(j['sono_leve_min']),
        sonoRemMin: _d(j['sono_rem_min']),
        acordadoMin: _d(j['acordado_min']),
        spo2Medio: _d(j['spo2_medio']),
      );
}

/// Refeições e água de um dia, vindas do Worker (GET /prato). As refeições são as que o conector Saúde grava.
class PratoDia {
  const PratoDia({required this.data, required this.refeicoes, required this.kcal, this.ultimaRefeicao, this.aguaMl = 0, this.metaAguaMl});

  final String data; // AAAA-MM-DD
  final int refeicoes;
  final double kcal;

  /// "AAAA-MM-DD HH:MM:SS" da última refeição do dia (null se não houve).
  final String? ultimaRefeicao;
  final int aguaMl;
  final int? metaAguaMl;

  bool get temRefeicao => refeicoes > 0;

  factory PratoDia.fromJson(Map<String, dynamic> j) => PratoDia(
        data: '${j['data']}',
        refeicoes: (j['refeicoes'] as num?)?.round() ?? 0,
        kcal: (j['kcal'] as num?)?.toDouble() ?? 0,
        ultimaRefeicao: j['ultima_refeicao'] as String?,
        aguaMl: (j['agua_ml'] as num?)?.round() ?? 0,
        metaAguaMl: (j['meta_agua_ml'] as num?)?.round(),
      );
}

/// Gasto estimado do dia = metabolismo basal (última pesagem) + calorias ativas da pulseira.
/// Sem basal não há estimativa; sem pulseira conta só o basal.
double? gastoEstimado({double? basal, double? ativas}) => basal == null ? null : basal + (ativas ?? 0);
