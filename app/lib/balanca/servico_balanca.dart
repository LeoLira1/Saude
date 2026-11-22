import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../core/mi_scale_parser.dart';

enum EstadoBalanca { parado, ouvindo, medindo, estabilizado, finalizado, erro }

class StatusBalanca {
  final EstadoBalanca estado;
  final LeituraBalanca? leitura;
  final String? mensagem;
  const StatusBalanca(this.estado, {this.leitura, this.mensagem});
}

/// Escuta passiva dos anúncios BLE da balança (sem parear, sem conectar).
class ServicoBalanca {
  ServicoBalanca._();
  static final instancia = ServicoBalanca._();

  final _status = StreamController<StatusBalanca>.broadcast();
  final _finais = StreamController<LeituraBalanca>.broadcast();
  Stream<StatusBalanca> get status => _status.stream;

  /// Medições finais (estabilizada + impedância), uma vez por chave.
  Stream<LeituraBalanca> get medicoesFinais => _finais.stream;

  StatusBalanca ultimo = const StatusBalanca(EstadoBalanca.parado);
  StreamSubscription<List<ScanResult>>? _sub;
  Timer? _reinicio;
  Timer? _ocioso;
  final Set<String> _chavesEmitidas = {};
  LeituraBalanca? _ultimaFinalSemChave;
  DateTime? _horaUltimaFinalSemChave;
  bool _ligado = false;

  void _emitir(StatusBalanca s) {
    ultimo = s;
    _status.add(s);
  }

  /// Chaves já salvas/recusadas, para não emitir de novo.
  void marcarVistas(Iterable<String> chaves) => _chavesEmitidas.addAll(chaves);

  Future<void> iniciar() async {
    if (_ligado) return;
    _ligado = true;
    try {
      if (await FlutterBluePlus.isSupported == false) {
        _emitir(const StatusBalanca(EstadoBalanca.erro, mensagem: 'Este celular não tem Bluetooth LE.'));
        return;
      }
      if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
        final estado = await FlutterBluePlus.adapterState
            .where((s) => s != BluetoothAdapterState.unknown)
            .first
            .timeout(const Duration(seconds: 3), onTimeout: () => BluetoothAdapterState.off);
        if (estado != BluetoothAdapterState.on) {
          try {
            await FlutterBluePlus.turnOn();
          } catch (_) {
            _emitir(const StatusBalanca(EstadoBalanca.erro, mensagem: 'Ligue o Bluetooth para ler a balança.'));
            _ligado = false;
            return;
          }
        }
      }
      _sub ??= FlutterBluePlus.onScanResults.listen(_aoReceber, onError: (_) {});
      await _comecarScan();
      // O Android encerra scans muito longos: reinicia a cada 10 minutos.
      _reinicio = Timer.periodic(const Duration(minutes: 10), (_) async {
        await FlutterBluePlus.stopScan();
        await _comecarScan();
      });
      _emitir(const StatusBalanca(EstadoBalanca.ouvindo, mensagem: 'Suba na balança'));
    } catch (e) {
      _ligado = false;
      final msg = '$e'.toLowerCase().contains('location')
          ? 'Ligue a Localização do celular (o Android exige para ler Bluetooth).'
          : 'Não consegui ligar o Bluetooth: $e';
      _emitir(StatusBalanca(EstadoBalanca.erro, mensagem: msg));
    }
  }

  Future<void> _comecarScan() async {
    await FlutterBluePlus.startScan(
      // Filtro no próprio Android: só anúncios com service data 0x181B.
      withServiceData: [ServiceDataFilter(Guid(uuidBodyComposition))],
      continuousUpdates: true, // a balança muda o peso no mesmo anúncio: precisamos de todos
      androidScanMode: AndroidScanMode.lowLatency,
      androidUsesFineLocation: true,
    );
  }

  Future<void> parar() async {
    _ligado = false;
    _reinicio?.cancel();
    _ocioso?.cancel();
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    _emitir(const StatusBalanca(EstadoBalanca.parado));
  }

  void _aoReceber(List<ScanResult> resultados) {
    for (final r in resultados) {
      List<int>? bytes;
      r.advertisementData.serviceData.forEach((uuid, dados) {
        if (uuid.str.toLowerCase().contains(uuidBodyComposition) && dados.length == 13) bytes = dados;
      });
      if (bytes == null) continue;
      final l = lerAnuncioMiScale2(bytes!);
      if (l == null || l.pesoKg <= 0) continue;
      processar(l);
    }
  }

  /// Público para teste: decide o que mostrar e quando emitir a medição final.
  void processar(LeituraBalanca l, {DateTime? agora}) {
    final t = agora ?? DateTime.now();
    _ocioso?.cancel();
    _ocioso = Timer(const Duration(seconds: 20), () {
      if (_ligado) _emitir(const StatusBalanca(EstadoBalanca.ouvindo, mensagem: 'Suba na balança'));
    });

    if (l.finalComImpedancia) {
      final chave = l.chave;
      if (chave != null) {
        if (_chavesEmitidas.add(chave)) _finais.add(l);
      } else {
        // Relógio da balança inválido: evita repetir o mesmo peso+impedância por 10 minutos.
        final u = _ultimaFinalSemChave;
        final repetida = u != null &&
            u.pesoKg == l.pesoKg &&
            u.impedancia == l.impedancia &&
            t.difference(_horaUltimaFinalSemChave!).inMinutes < 10;
        if (!repetida) {
          _ultimaFinalSemChave = l;
          _horaUltimaFinalSemChave = t;
          _finais.add(l);
        }
      }
      _emitir(StatusBalanca(EstadoBalanca.finalizado, leitura: l));
      return;
    }
    if (ultimo.estado == EstadoBalanca.finalizado && (l.removido || l.estabilizado)) {
      return; // continua mostrando o resultado até a próxima pesagem
    }
    if (l.estabilizado && l.removido) {
      _emitir(StatusBalanca(EstadoBalanca.erro,
          leitura: l, mensagem: 'Saiu antes da bioimpedância. Suba de novo, descalço, e espere terminar.'));
    } else if (l.estabilizado) {
      _emitir(StatusBalanca(EstadoBalanca.estabilizado, leitura: l, mensagem: 'Medindo composição… fique parado'));
    } else if (!l.removido) {
      _emitir(StatusBalanca(EstadoBalanca.medindo, leitura: l));
    }
  }
}
