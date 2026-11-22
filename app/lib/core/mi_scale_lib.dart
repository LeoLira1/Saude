// Porte para Dart de duas classes do openScale (GPL-3.0, github.com/oliexdev/openScale):
//  - MiScaleLib.kt: algoritmo do Mi Fit/Zepp Life (engenharia reversa de prototux/MIBCS).
//  - BodyMiScaleLib.kt: porte do bodymiscale (dckiller51), usado aqui só para
//    metabolismo basal (Schofield/OMS) e proteína (Wang 1999), que a MiScaleLib não tem.
// As contas seguem o original linha a linha; os testes em test/mi_scale_lib_test.dart
// usam os mesmos valores de referência dos testes do openScale.

/// MiScaleLib.kt. sexo: 1 = masculino, 0 = feminino. altura em cm.
class MiScaleLib {
  final int sex;
  final int age;
  final double height;

  const MiScaleLib(this.sex, this.age, this.height);

  double _getLBMCoefficient(double weight, double impedance) {
    var lbm = (height * 9.058 / 100.0) * (height / 100.0);
    lbm += weight * 0.32 + 12.226;
    lbm -= impedance * 0.0068;
    lbm -= age * 0.0542;
    return lbm;
  }

  double getBMI(double weight) => weight / (((height * height) / 100.0) / 100.0);

  double getLBM(double weight, double impedance) {
    var leanBodyMass = weight - ((getBodyFat(weight, impedance) * 0.01) * weight) - getBoneMass(weight, impedance);
    if (sex == 0 && leanBodyMass >= 84.0) {
      leanBodyMass = 120.0;
    } else if (sex == 1 && leanBodyMass >= 93.5) {
      leanBodyMass = 120.0;
    }
    return leanBodyMass;
  }

  /// Massa muscular esquelética em % do peso (Janssen et al.).
  double getMuscle(double weight, double impedance) {
    if (weight <= 0) return 0;
    double smmKg;
    if (impedance > 0) {
      final h2OverR = (height * height) / impedance;
      smmKg = 0.401 * h2OverR + 3.825 * sex - 0.071 * age + 5.102;
    } else {
      final lbm = getLBM(weight, impedance);
      final ratio = sex == 1 ? 0.52 : 0.46;
      smmKg = lbm * ratio;
    }
    final percent = (smmKg / weight) * 100;
    return percent.clamp(10.0, 60.0).toDouble();
  }

  double getWater(double weight, double impedance) {
    final water = (100.0 - getBodyFat(weight, impedance)) * 0.7;
    final coeff = water < 50 ? 1.02 : 0.98;
    return coeff * water;
  }

  double getBoneMass(double weight, double impedance) {
    final base = sex == 0 ? 0.245691014 : 0.18016894;
    var boneMass = (base - (_getLBMCoefficient(weight, impedance) * 0.05158)) * -1.0;
    boneMass = boneMass > 2.2 ? boneMass + 0.1 : boneMass - 0.1;
    if (sex == 0 && boneMass > 5.1) {
      boneMass = 8.0;
    } else if (sex == 1 && boneMass > 5.2) {
      boneMass = 8.0;
    }
    return boneMass;
  }

  double getVisceralFat(double weight) {
    double visceralFat;
    if (sex == 0) {
      if (weight > (13.0 - (height * 0.5)) * -1.0) {
        final subsubcalc = ((height * 1.45) + (height * 0.1158) * height) - 120.0;
        final subcalc = weight * 500.0 / subsubcalc;
        visceralFat = (subcalc - 6.0) + (age * 0.07);
      } else {
        final subcalc = 0.691 + (height * -0.0024) + (height * -0.0024);
        visceralFat = (((height * 0.027) - (subcalc * weight)) * -1.0) + (age * 0.07) - age;
      }
    } else {
      if (height < weight * 1.6) {
        final subcalc = ((height * 0.4) - (height * (height * 0.0826))) * -1.0;
        visceralFat = ((weight * 305.0) / (subcalc + 48.0)) - 2.9 + (age * 0.15);
      } else {
        final subcalc = 0.765 + height * -0.0015;
        visceralFat = (((height * 0.143) - (weight * subcalc)) * -1.0) + (age * 0.15) - 5.0;
      }
    }
    return visceralFat;
  }

  double getBodyFat(double weight, double impedance) {
    var lbmSub = 0.8;
    if (sex == 0 && age <= 49) {
      lbmSub = 9.25;
    } else if (sex == 0 && age > 49) {
      lbmSub = 7.25;
    }
    final lbmCoeff = _getLBMCoefficient(weight, impedance);
    var coeff = 1.0;
    if (sex == 1 && weight < 61.0) {
      coeff = 0.98;
    } else if (sex == 0 && weight > 60.0) {
      coeff = 0.96;
      if (height > 160.0) coeff *= 1.03;
    } else if (sex == 0 && weight < 50.0) {
      coeff = 1.02;
      if (height > 160.0) coeff *= 1.03;
    }
    var bodyFat = (1.0 - (((lbmCoeff - lbmSub) * coeff) / weight)) * 100.0;
    if (bodyFat > 63.0) bodyFat = 75.0;
    return bodyFat;
  }
}

/// BodyMiScaleLib.kt (só o que usamos). masculino = true/false.
class BodyMiScaleLib {
  final bool isMale;
  final int age;
  final double heightCm;

  const BodyMiScaleLib(this.isMale, this.age, this.heightCm);

  static const _femaleLbmCorrection = 0.84;
  static const _maleSchofield = [
    [59.512, -30.4], [22.706, 504.3], [17.686, 658.2], //
    [15.057, 692.2], [11.472, 873.1], [11.711, 587.7],
  ];
  static const _femaleSchofield = [
    [58.317, -31.1], [20.315, 485.9], [13.384, 692.6], //
    [14.818, 486.6], [8.126, 845.6], [9.082, 658.5],
  ];

  double getLbm(double weightKg, double impedance) {
    var lbm = (heightCm * 9.058 / 100) * (heightCm / 100) + weightKg * 0.32 + 12.226 - impedance * 0.0068 - age * 0.0542;
    if (!isMale) lbm *= _femaleLbmCorrection;
    return lbm < weightKg * 0.98 ? lbm : weightKg * 0.98;
  }

  double getFat(double weightKg, double lbm) {
    final fat = (weightKg - lbm) / weightKg * 100;
    return fat.clamp(isMale ? 5.0 : 10.0, 75.0).toDouble();
  }

  double getWater(double fatPercent) => ((100 - fatPercent) * 0.73).clamp(35.0, 73.0).toDouble();

  double getProtein(double weightKg, double lbm) => (lbm * 0.195 / weightKg * 100).clamp(5.0, 32.0).toDouble();

  double getBoneMass(double lbm) {
    final base = isMale ? 0.18016894 : 0.245691014;
    var bone = (base - lbm * 0.05158) * -1;
    bone = bone > 2.2 ? bone + 0.1 : bone - 0.1;
    if ((isMale && bone > 5.2) || (!isMale && bone > 5.1)) bone = 8.0;
    return bone.clamp(0.5, 8.0).toDouble();
  }

  double getMuscleMass(double weightKg, double fatPercent, double boneMassKg) {
    final muscle = weightKg - (fatPercent * 0.01 * weightKg) - boneMassKg;
    return muscle.clamp(10.0, 120.0).toDouble();
  }

  double getBmr(double weightKg) => _schofield(weightKg).clamp(500.0, 5000.0).toDouble();

  double _schofield(double weightKg) {
    final c = isMale ? _maleSchofield : _femaleSchofield;
    final int i;
    if (age < 3) {
      i = 0;
    } else if (age < 10) {
      i = 1;
    } else if (age < 18) {
      i = 2;
    } else if (age < 30) {
      i = 3;
    } else if (age < 60) {
      i = 4;
    } else {
      i = 5;
    }
    return c[i][0] * weightKg + c[i][1];
  }

  double getVisceralFat(double weightKg) {
    final h = heightCm;
    final w = weightKg;
    double vfal;
    if (isMale) {
      vfal = h < w * 1.6 + 63.0
          ? age * 0.15 + ((w * 305.0) / ((h * 0.0826 * h - h * 0.4) + 48.0) - 2.9)
          : age * 0.15 + (w * (h * -0.0015 + 0.765) - h * 0.143) - 5.0;
    } else {
      vfal = w <= h * 0.5 - 13.0
          ? age * 0.07 + (w * (h * -0.0024 + 0.691) - h * 0.027) - 10.5
          : age * 0.07 + ((w * 500.0) / ((h * 1.45 + h * 0.1158 * h) - 120.0) - 6.0);
    }
    return vfal.clamp(1.0, 50.0).toDouble();
  }
}
