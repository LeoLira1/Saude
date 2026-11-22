import 'mi_scale_lib.dart';

/// Dados do perfil usados nas fórmulas.
class Perfil {
  final double alturaCm;
  final DateTime nascimento;
  final bool masculino;

  const Perfil({required this.alturaCm, required this.nascimento, required this.masculino});

  int idadeEm(DateTime data) {
    var idade = data.year - nascimento.year;
    if (data.month < nascimento.month || (data.month == nascimento.month && data.day < nascimento.day)) idade--;
    return idade;
  }

  Map<String, dynamic> toJson() => {
        'altura_cm': alturaCm,
        'nascimento': nascimento.toIso8601String().substring(0, 10),
        'masculino': masculino,
      };

  static Perfil? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    final n = DateTime.tryParse('${j['nascimento']}');
    final a = (j['altura_cm'] as num?)?.toDouble();
    if (n == null || a == null) return null;
    return Perfil(alturaCm: a, nascimento: n, masculino: j['masculino'] != false);
  }
}

/// Resultado da composição corporal.
class Composicao {
  final double imc;
  final double gorduraPct;
  final double aguaPct;
  final double musculoKg;
  final double ossoKg;
  final double visceral;
  final double metabolismoKcal;
  final double proteinaPct;
  final double pesoIdeal;

  const Composicao({
    required this.imc,
    required this.gorduraPct,
    required this.aguaPct,
    required this.musculoKg,
    required this.ossoKg,
    required this.visceral,
    required this.metabolismoKcal,
    required this.proteinaPct,
    required this.pesoIdeal,
  });
}

double _r(double v, [int casas = 2]) {
  final f = [1, 10, 100, 1000][casas];
  return (v * f).roundToDouble() / f;
}

/// Calcula tudo a partir de peso (kg) e impedância (Ω).
///  - IMC, gordura, água, osso e visceral: MiScaleLib (algoritmo do Mi Fit).
///  - Massa muscular: MiScaleLib.getMuscle (massa muscular esquelética, Janssen) em % → kg.
///  - Metabolismo basal e proteína: BodyMiScaleLib (Schofield/OMS e Wang).
///  - Peso ideal: IMC 22 na sua altura (mesma referência do Mi Fit).
Composicao calcularComposicao({
  required double peso,
  required double impedancia,
  required Perfil perfil,
  DateTime? data,
}) {
  final idade = perfil.idadeEm(data ?? DateTime.now());
  final mi = MiScaleLib(perfil.masculino ? 1 : 0, idade, perfil.alturaCm);
  final body = BodyMiScaleLib(perfil.masculino, idade, perfil.alturaCm);
  final lbm = body.getLbm(peso, impedancia);
  final musculoPct = mi.getMuscle(peso, impedancia);
  // A fórmula feminina original pode dar negativo; o Mi Fit mostra de 1 a 59.
  final visceral = mi.getVisceralFat(peso).clamp(1.0, 59.0).toDouble();
  final h = perfil.alturaCm / 100;
  return Composicao(
    imc: _r(mi.getBMI(peso), 1),
    gorduraPct: _r(mi.getBodyFat(peso, impedancia), 1),
    aguaPct: _r(mi.getWater(peso, impedancia), 1),
    musculoKg: _r(musculoPct * peso / 100, 1),
    ossoKg: _r(mi.getBoneMass(peso, impedancia), 2),
    visceral: _r(visceral, 1),
    metabolismoKcal: body.getBmr(peso).roundToDouble(),
    proteinaPct: _r(body.getProtein(peso, lbm), 1),
    pesoIdeal: _r(22 * h * h, 1),
  );
}
