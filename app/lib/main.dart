import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'data/background.dart';
import 'ui/estado_app.dart';
import 'ui/tela_ajustes.dart';
import 'ui/tela_historico.dart';
import 'ui/tela_inicio.dart';
import 'ui/tema.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AppSaude());
}

class AppSaude extends StatelessWidget {
  const AppSaude({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Saúde',
        debugShowCheckedModeBanner: false,
        theme: temaEscuro(),
        darkTheme: temaEscuro(),
        themeMode: ThemeMode.dark,
        home: const Casca(),
      );
}

class Casca extends StatefulWidget {
  const Casca({super.key});
  @override
  State<Casca> createState() => _CascaState();
}

class _CascaState extends State<Casca> with WidgetsBindingObserver {
  final app = EstadoApp();
  int _aba = 0;
  bool _carregou = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _iniciar();
  }

  Future<void> _iniciar() async {
    await app.iniciar();
    if (!mounted) return;
    setState(() => _carregou = true);
    if (!app.arm.configurado) setState(() => _aba = 2);
    // Primeira abertura: explica e pede Bluetooth/Localização.
    if (!app.permissaoBluetooth) {
      await _explicarBluetooth();
    }
    await app.ligarBalanca();
    unawaited(app.sincronizar(origem: 'ao abrir'));
    unawaited(garantirAgendamentos(app.arm).catchError((_) {}));
  }

  Future<void> _explicarBluetooth() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Ler a balança'),
        content: const Text(
          'O app escuta a balança pelo Bluetooth, sem parear.\n\n'
          'O Android chama isso de "Dispositivos por perto" e também pede "Localização" '
          '(é exigência do sistema para Bluetooth). O app não guarda nem usa onde você está.\n\n'
          'No Android 11, deixe a Localização do celular ligada enquanto se pesa.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Agora não')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Continuar')),
        ],
      ),
    );
    if (ok == true) await app.pedirBluetooth();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (!_carregou) return;
    if (s == AppLifecycleState.resumed) {
      app.aoRetomar();
    } else if (s == AppLifecycleState.paused) {
      app.aoSair();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    app.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_carregou) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final titulos = ['Saúde', 'Histórico', 'Ajustes'];
    return Scaffold(
      appBar: AppBar(title: Text(titulos[_aba])),
      body: SafeArea(
        top: false,
        child: IndexedStack(index: _aba, children: [
          TelaInicio(app: app, irParaAjustes: () => setState(() => _aba = 2)),
          TelaHistorico(app: app),
          TelaAjustes(app: app),
        ]),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _aba,
        onDestinationSelected: (i) => setState(() => _aba = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.monitor_weight_outlined), selectedIcon: Icon(Icons.monitor_weight), label: 'Início'),
          NavigationDestination(icon: Icon(Icons.show_chart), label: 'Histórico'),
          NavigationDestination(icon: Icon(Icons.tune), label: 'Ajustes'),
        ],
      ),
    );
  }
}
