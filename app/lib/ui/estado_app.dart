import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:permission_handler/permission_handler.dart';

import '../balanca/servico_balanca.dart';
import '../core/composicao.dart';
import '../core/mi_scale_parser.dart';
import '../data/armazenamento.dart';
import '../data/modelos.dart';
import '../data/sincronizacao.dart';
import '../saude/health_sync.dart';

/// Estado do app inteiro (um só, criado no main).
class EstadoApp extends ChangeNotifier {
  late Armazenamento arm;
  bool pronto = false;

  StatusBalanca balanca = const StatusBalanca(EstadoBalanca.parado);
  bool permissaoBluetooth = false;
  bool? hcDisponivel;
  bool hcPermissao = false;
  bool sincronizando = false;
  String? avisoSinc;

  /// Medição esperando o "É você?".
  Medicao? aConfirmar;

  /// Última medição recém-salva (para o cartão mostrar "Salvo ✓").
  String? salvaAgora;

  StreamSubscription<StatusBalanca>? _subStatus;
  StreamSubscription<LeituraBalanca>? _subFinal;

  Future<void> iniciar() async {
    arm = await Armazenamento.abrir();
    pronto = true;
    final sb = ServicoBalanca.instancia;
    sb.marcarVistas(arm.chavesVistas);
    _subStatus = sb.status.listen((s) {
      balanca = s;
      notifyListeners();
    });
    _subFinal = sb.medicoesFinais.listen(_aoMedir);
    notifyListeners();
    await verificarPermissoes();
  }

  @override
  void dispose() {
    _subStatus?.cancel();
    _subFinal?.cancel();
    super.dispose();
  }

  Future<void> verificarPermissoes() async {
    final scan = await Permission.bluetoothScan.status;
    final loc = await Permission.locationWhenInUse.status;
    permissaoBluetooth = scan.isGranted && loc.isGranted;
    try {
      hcDisponivel = await HealthSync.instancia.disponivel();
      hcPermissao = hcDisponivel == true && await HealthSync.instancia.temPermissao();
    } catch (_) {
      hcDisponivel = false;
    }
    notifyListeners();
  }

  /// Bluetooth (Android 12) + Localização (Android 11 exige para achar aparelhos BLE).
  Future<bool> pedirBluetooth() async {
    final r = await [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.locationWhenInUse].request();
    permissaoBluetooth =
        (r[Permission.bluetoothScan]?.isGranted ?? false) && (r[Permission.locationWhenInUse]?.isGranted ?? false);
    notifyListeners();
    if (permissaoBluetooth) await ligarBalanca();
    return permissaoBluetooth;
  }

  Future<void> ligarBalanca() async {
    if (!permissaoBluetooth) return;
    await ServicoBalanca.instancia.iniciar();
  }

  Future<void> desligarBalanca() => ServicoBalanca.instancia.parar();

  /// Ao abrir/voltar ao app: relê o arquivo (o segundo plano pode ter gravado), liga a balança e sincroniza.
  Future<void> aoRetomar() async {
    if (!pronto) return;
    arm = await Armazenamento.abrir();
    ServicoBalanca.instancia.marcarVistas(arm.chavesVistas);
    notifyListeners();
    await verificarPermissoes();
    await ligarBalanca();
    unawaited(sincronizar());
  }

  Future<void> sincronizar({bool lerSaude = true}) async {
    if (sincronizando) return;
    sincronizando = true;
    notifyListeners();
    try {
      final r = await Sincronizacao(arm).tudo(lerSaude: lerSaude && hcPermissao);
      avisoSinc = r.erro;
    } catch (e) {
      avisoSinc = '$e';
    } finally {
      sincronizando = false;
      notifyListeners();
    }
  }

  void _aoMedir(LeituraBalanca l) {
    final perfil = arm.perfil;
    if (perfil == null) {
      avisoSinc = 'Preencha o perfil (altura, nascimento, sexo) em Ajustes para calcular a composição.';
      notifyListeners();
      return;
    }
    final quando = l.medidoEm ?? DateTime.now();
    final chave = formatarDataHora(quando);
    if (arm.chavesVistas.contains(chave)) return;
    final c = calcularComposicao(peso: l.pesoKg, impedancia: l.impedancia!.toDouble(), perfil: perfil, data: quando);
    final m = Medicao(
      medidoEm: chave,
      peso: l.pesoKg,
      impedancia: l.impedancia,
      imc: c.imc,
      gorduraPct: c.gorduraPct,
      aguaPct: c.aguaPct,
      musculoKg: c.musculoKg,
      ossoKg: c.ossoKg,
      visceral: c.visceral,
      metabolismoKcal: c.metabolismoKcal,
      proteinaPct: c.proteinaPct,
    );
    final ultima = arm.ultimaMedicao;
    if (ultima != null && (m.peso - ultima.peso).abs() > 5) {
      aConfirmar = m; // a tela pergunta "É você?"
      notifyListeners();
      return;
    }
    unawaited(_salvar(m));
  }

  Future<void> responderEVoce(bool souEu) async {
    final m = aConfirmar;
    aConfirmar = null;
    if (m == null) return;
    if (souEu) {
      await _salvar(m);
    } else {
      arm.recusar(m.medidoEm);
      ServicoBalanca.instancia.marcarVistas([m.medidoEm]);
      await arm.salvar();
      notifyListeners();
    }
  }

  Future<void> _salvar(Medicao m) async {
    if (!arm.adicionarMedicao(m)) return;
    ServicoBalanca.instancia.marcarVistas([m.medidoEm]);
    salvaAgora = m.medidoEm;
    await arm.salvar();
    notifyListeners();
    await sincronizar(lerSaude: false);
  }

  Future<void> salvarPerfil(Perfil p) async {
    arm.perfil = p;
    await arm.salvar();
    notifyListeners();
  }

  Future<void> salvarApi(String url, String chave) async {
    arm.apiUrl = url;
    arm.apiKey = chave;
    arm.historicoRecuperado = false;
    await arm.salvar();
    notifyListeners();
    await sincronizar(lerSaude: false);
  }

  Future<void> conectarHealthConnect() async {
    final hs = HealthSync.instancia;
    if (!await hs.disponivel()) {
      await hs.instalar(); // abre a página do Health Connect na Play Store
      return;
    }
    await Permission.activityRecognition.request();
    await hs.pedirPermissao();
    await verificarPermissoes();
    if (hcPermissao) await sincronizar();
  }

  // ── Dados para as telas ──────────────────────────────────────────────────
  List<Medicao> get medicoes => arm.medicoes;

  Medicao? get ultima => arm.ultimaMedicao;

  Medicao? get anterior {
    final l = medicoes;
    return l.length < 2 ? null : l[l.length - 2];
  }

  /// A medição mais recente feita 30 dias (ou mais) antes da última.
  Medicao? get de30Dias {
    final l = medicoes;
    if (l.isEmpty) return null;
    final limite = l.last.data.subtract(const Duration(days: 30));
    Medicao? r;
    for (final m in l) {
      if (!m.data.isAfter(limite)) r = m;
    }
    return r;
  }

  AtividadeDia? atividadeDe(DateTime d) {
    final k = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return arm.atividade[k];
  }

  int get pendentes => arm.filaMedicoes.length + arm.atividadePendente().length;
}
