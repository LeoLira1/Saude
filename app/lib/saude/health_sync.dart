import 'package:health/health.dart';

import '../data/modelos.dart';
import 'agregador.dart';

/// Leitura do Health Connect (onde o Mi Fitness grava os dados da Mi Band).
class HealthSync {
  HealthSync._();
  static final instancia = HealthSync._();

  final Health _health = Health();
  bool _configurado = false;

  static const tipos = [
    HealthDataType.STEPS,
    HealthDataType.ACTIVE_ENERGY_BURNED,
    HealthDataType.HEART_RATE,
    HealthDataType.RESTING_HEART_RATE,
    HealthDataType.SLEEP_SESSION,
    HealthDataType.SLEEP_ASLEEP,
    HealthDataType.SLEEP_AWAKE,
    HealthDataType.SLEEP_DEEP,
    HealthDataType.SLEEP_LIGHT,
    HealthDataType.SLEEP_REM,
    HealthDataType.BLOOD_OXYGEN,
  ];

  Future<void> _configurar() async {
    if (_configurado) return;
    await _health.configure();
    _configurado = true;
  }

  /// null = Health Connect não instalado / precisa atualizar.
  Future<bool> disponivel() async {
    await _configurar();
    final s = await _health.getHealthConnectSdkStatus();
    return s == HealthConnectSdkStatus.sdkAvailable;
  }

  Future<void> instalar() async {
    await _configurar();
    await _health.installHealthConnect();
  }

  Future<bool> temPermissao() async {
    await _configurar();
    try {
      // Pergunta por um tipo de cada vez: basta passos ou sono estarem liberados.
      final passos = await _health.hasPermissions([HealthDataType.STEPS]) ?? false;
      final sono = await _health.hasPermissions([HealthDataType.SLEEP_SESSION]) ?? false;
      return passos || sono;
    } catch (_) {
      return false;
    }
  }

  /// Abre a tela de permissões do Health Connect.
  Future<bool> pedirPermissao() async {
    await _configurar();
    final ok = await _health.requestAuthorization(
      tipos,
      permissions: tipos.map((_) => HealthDataAccess.READ).toList(),
    );
    // Leitura em segundo plano (para a sincronização diária) e histórico antigo, onde existirem.
    try {
      if (await _health.isHealthDataInBackgroundAvailable() && !await _health.isHealthDataInBackgroundAuthorized()) {
        await _health.requestHealthDataInBackgroundAuthorization();
      }
    } catch (_) {}
    try {
      if (await _health.isHealthDataHistoryAvailable() && !await _health.isHealthDataHistoryAuthorized()) {
        await _health.requestHealthDataHistoryAuthorization();
      }
    } catch (_) {}
    return ok;
  }

  /// Erros da última leitura (por tipo). Vazio = tudo leu.
  final List<String> erros = [];

  Future<List<HealthDataPoint>> _ler(HealthDataType t, DateTime ini, DateTime fim) async {
    try {
      return await _health.getHealthDataFromTypes(types: [t], startTime: ini, endTime: fim);
    } catch (e) {
      erros.add('${t.name}: $e'); // segue com os outros tipos, mas fica registrado
      return const [];
    }
  }

  /// Leitura com o app fechado: o Health Connect só deixa com a permissão de segundo plano.
  /// disponivel = o Health Connect deste celular tem esse recurso; autorizada = você liberou.
  Future<({bool disponivel, bool autorizada})> segundoPlano() async {
    await _configurar();
    try {
      final disp = await _health.isHealthDataInBackgroundAvailable();
      final aut = disp && await _health.isHealthDataInBackgroundAuthorized();
      return (disponivel: disp, autorizada: aut);
    } catch (_) {
      return (disponivel: false, autorizada: false);
    }
  }

  Future<bool> pedirSegundoPlano() async {
    await _configurar();
    try {
      return await _health.requestHealthDataInBackgroundAuthorization();
    } catch (_) {
      return false;
    }
  }

  static double _num(HealthDataPoint p) {
    final v = p.value;
    return v is NumericHealthValue ? v.numericValue.toDouble() : 0;
  }

  /// Lê os últimos [dias] dias (hoje incluso) e devolve um resumo por dia.
  Future<List<AtividadeDia>> lerDias(int dias) async {
    await _configurar();
    erros.clear();
    final agora = DateTime.now();
    final hoje = DateTime(agora.year, agora.month, agora.day);
    final ini = hoje.subtract(Duration(days: dias - 1));
    final datas = [for (var i = 0; i < dias; i++) dataLocal(ini.add(Duration(days: i)))];

    // Passos e calorias: agregados do Health Connect (sem contar em dobro quando há mais de um app).
    final passos = <String, int>{};
    for (var i = 0; i < dias; i++) {
      final d0 = ini.add(Duration(days: i));
      final d1 = d0.add(const Duration(days: 1));
      try {
        final n = await _health.getTotalStepsInInterval(d0, d1.isAfter(agora) ? agora : d1);
        if (n > 0) passos[dataLocal(d0)] = n;
      } catch (e) {
        erros.add('STEPS ${dataLocal(d0)}: $e');
      }
    }
    final calorias = <String, double>{};
    try {
      final pts = await _health.getHealthIntervalDataFromTypes(
        startDate: ini,
        endDate: agora,
        types: [HealthDataType.ACTIVE_ENERGY_BURNED],
        interval: 86400,
      );
      for (final p in pts) {
        final d = dataLocal(p.dateFrom);
        calorias[d] = (calorias[d] ?? 0) + _num(p);
      }
    } catch (e) {
      erros.add('ACTIVE_ENERGY_BURNED: $e');
    }

    Amostra a(HealthDataPoint p) => Amostra(p.dateFrom, p.dateTo, _num(p));

    final hr = (await _ler(HealthDataType.HEART_RATE, ini, agora)).map(a).toList();
    final rhr = (await _ler(HealthDataType.RESTING_HEART_RATE, ini, agora)).map(a).toList();
    final ox = (await _ler(HealthDataType.BLOOD_OXYGEN, ini, agora)).map(a).toList();

    // Sono: o Health Connect devolve a sessão pelo horário em que COMEÇOU. Lê desde 00:00 do dia
    // anterior ao primeiro, para achar também a noite (ou cochilo longo) que acabou no primeiro dia.
    final iniSono = ini.subtract(const Duration(days: 1));
    final sessoes = (await _ler(HealthDataType.SLEEP_SESSION, iniSono, agora)).map(a).toList();
    final estagios = <EstagioSono>[];
    const mapa = {
      HealthDataType.SLEEP_DEEP: Estagio.profundo,
      HealthDataType.SLEEP_LIGHT: Estagio.leve,
      HealthDataType.SLEEP_REM: Estagio.rem,
      HealthDataType.SLEEP_AWAKE: Estagio.acordado,
      HealthDataType.SLEEP_ASLEEP: Estagio.dormindo,
    };
    for (final e in mapa.entries) {
      for (final p in await _ler(e.key, iniSono, agora)) {
        estagios.add(EstagioSono(e.value, p.dateFrom, p.dateTo));
      }
    }

    return montarDias(
      datas: datas,
      passos: passos,
      calorias: calorias,
      batimentos: hr,
      fcRepouso: rhr,
      spo2: ox,
      sono: agregarSono(sessoes, estagios),
      hoje: dataLocal(agora),
    );
  }
}
