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
    this.fcMedia,
    this.sonoMin,
    this.sonoProfundoMin,
    this.sonoLeveMin,
    this.sonoRemMin,
    this.acordadoMin,
    this.spo2Medio,
  });

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
        fcMedia: _d(j['fc_media']),
        sonoMin: _d(j['sono_min']),
        sonoProfundoMin: _d(j['sono_profundo_min']),
        sonoLeveMin: _d(j['sono_leve_min']),
        sonoRemMin: _d(j['sono_rem_min']),
        acordadoMin: _d(j['acordado_min']),
        spo2Medio: _d(j['spo2_medio']),
      );
}
