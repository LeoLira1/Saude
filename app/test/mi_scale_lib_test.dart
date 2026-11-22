// Valores de referência copiados dos testes do openScale:
//   MiScaleLibTest.kt e BodyMiScaleLibTest.kt (android_app/app/src/test/.../bluetooth/libs/).
import 'package:flutter_test/flutter_test.dart';
import 'package:saude/core/composicao.dart';
import 'package:saude/core/mi_scale_lib.dart';

void main() {
  const eps = 1e-3;

  void confere(MiScaleLib lib, double peso, double imp, Map<String, double> r) {
    expect(lib.getBMI(peso), closeTo(r['bmi']!, eps));
    expect(lib.getBodyFat(peso, imp), closeTo(r['bodyFat']!, eps));
    expect(lib.getBoneMass(peso, imp), closeTo(r['bone']!, eps));
    expect(lib.getLBM(peso, imp), closeTo(r['lbm']!, eps));
    expect(lib.getMuscle(peso, imp), closeTo(r['musclePct']!, eps));
    expect(lib.getWater(peso, imp), closeTo(r['waterPct']!, eps));
    expect(lib.getVisceralFat(peso), closeTo(r['visceralFat']!, eps));
  }

  group('MiScaleLib (openScale MiScaleLibTest)', () {
    test('IMC homem 30a 180cm 80kg', () {
      expect(const MiScaleLib(1, 30, 180).getBMI(80), closeTo(24.691358, eps));
    });

    test('regressão homem 30a 180cm 80kg imp 500', () {
      confere(const MiScaleLib(1, 30, 180), 80, 500, {
        'bmi': 24.691359,
        'bodyFat': 23.315107,
        'bone': 3.1254203,
        'lbm': 58.222496,
        'musclePct': 40.977253,
        'waterPct': 52.605835,
        'visceralFat': 13.359997,
      });
    });

    test('regressão mulher 28a 165cm 60kg imp 520', () {
      confere(const MiScaleLib(0, 28, 165), 60, 520, {
        'bmi': 22.038567,
        'bodyFat': 30.361998,
        'bone': 2.4865808,
        'lbm': 39.29622,
        'musclePct': 40.181103,
        'waterPct': 49.72153,
        'visceralFat': -36.555004,
      });
    });

    test('regressão homem 45a 175cm 95kg imp 430', () {
      confere(const MiScaleLib(1, 45, 175), 95, 430, {
        'bmi': 31.020409,
        'bodyFat': 32.41778,
        'bone': 3.2726917,
        'lbm': 60.93042,
        'musclePct': 36.096416,
        'waterPct': 48.2537,
        'visceralFat': 24.462498,
      });
    });

    test('músculo sem impedância usa LBM × 0,46 (mulher) e fica entre 10 e 60', () {
      const lib = MiScaleLib(0, 52, 160);
      final esperado = ((lib.getLBM(48, 0) * 0.46) / 48 * 100).clamp(10.0, 60.0);
      expect(lib.getMuscle(48, 0), closeTo(esperado, eps));
    });

    test('músculo trava em 60%', () {
      expect(const MiScaleLib(1, 20, 190).getMuscle(40, 50), closeTo(60, eps));
    });

    test('água usa o coeficiente certo', () {
      const lib = MiScaleLib(0, 50, 150);
      final bf = lib.getBodyFat(100, 700);
      final raw = (100 - bf) * 0.7;
      expect(lib.getWater(100, 700), closeTo(raw * (raw < 50 ? 1.02 : 0.98), eps));
    });
  });

  group('BodyMiScaleLib (openScale BodyMiScaleLibTest)', () {
    const lib = BodyMiScaleLib(true, 46, 168);
    const peso = 86.10;
    const imp = 421.0;

    test('bate com a referência do bodymiscale', () {
      final lbm = lib.getLbm(peso, imp);
      final fat = lib.getFat(peso, lbm);
      final bone = lib.getBoneMass(lbm);
      expect(lbm, closeTo(60.0, 0.05));
      expect(fat, closeTo(30.33, 0.05));
      expect(lib.getWater(fat), closeTo(50.86, 0.05));
      expect(lib.getProtein(peso, lbm), closeTo(13.59, 0.05));
      expect(bone, closeTo(3.01, 0.05));
      expect(lib.getMuscleMass(peso, fat, bone), closeTo(56.97, 0.05));
      expect(lib.getBmr(peso), closeTo(1861, 1));
      expect(lib.getVisceralFat(peso), closeTo(15.36, 0.05));
    });

    test('correção feminina do LBM', () {
      const f = BodyMiScaleLib(false, 46, 168);
      final lbm = f.getLbm(peso, imp);
      expect(lbm, closeTo(50.40, 0.05));
      expect(f.getFat(peso, lbm), closeTo(41.46, 0.05));
    });

    test('piso de gordura por sexo', () {
      expect(lib.getFat(100, 99), 5);
      expect(const BodyMiScaleLib(false, 46, 168).getFat(100, 99), 10);
    });
  });

  group('calcularComposicao', () {
    test('homem 30a 180cm 80kg imp 500', () {
      final p = Perfil(alturaCm: 180, nascimento: DateTime(1996, 1, 1), masculino: true);
      final c = calcularComposicao(peso: 80, impedancia: 500, perfil: p, data: DateTime(2026, 6, 1));
      expect(c.imc, 24.7);
      expect(c.gorduraPct, 23.3);
      expect(c.aguaPct, 52.6);
      expect(c.ossoKg, 3.13);
      expect(c.visceral, 13.4);
      expect(c.musculoKg, closeTo(40.977253 * 0.8, 0.06));
      expect(c.metabolismoKcal, (11.472 * 80 + 873.1).roundToDouble()); // Schofield 30–60 anos
      expect(c.pesoIdeal, 71.3); // IMC 22 em 1,80 m
      expect(c.proteinaPct, greaterThan(10));
    });

    test('visceral feminino negativo vira 1', () {
      final p = Perfil(alturaCm: 165, nascimento: DateTime(1998, 1, 1), masculino: false);
      final c = calcularComposicao(peso: 60, impedancia: 520, perfil: p, data: DateTime(2026, 6, 1));
      expect(c.visceral, 1);
    });

    test('idade conta o aniversário', () {
      final p = Perfil(alturaCm: 180, nascimento: DateTime(1990, 6, 15), masculino: true);
      expect(p.idadeEm(DateTime(2026, 6, 14)), 35);
      expect(p.idadeEm(DateTime(2026, 6, 15)), 36);
    });
  });
}
