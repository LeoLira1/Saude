// Renderiza as 3 telas com dados de exemplo no tamanho do Galaxy A12 (720×1600, 2x).
// Falha se houver erro de layout (ex.: texto estourando). Com SCREENSHOTS=pasta, salva PNGs.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:saude/balanca/servico_balanca.dart';
import 'package:saude/core/composicao.dart';
import 'package:saude/core/mi_scale_parser.dart';
import 'package:saude/data/armazenamento.dart';
import 'package:saude/data/modelos.dart';
import 'package:saude/saude/agregador.dart';
import 'package:saude/ui/estado_app.dart';
import 'package:saude/ui/tela_ajustes.dart';
import 'package:saude/ui/tela_historico.dart';
import 'package:saude/ui/tela_inicio.dart';
import 'package:saude/ui/tema.dart';

Future<void> _fontes() async {
  final base = '${Platform.environment['FLUTTER_ROOT'] ?? '/home/user/flutter'}/bin/cache/artifacts/material_fonts';
  if (!Directory(base).existsSync()) return;
  final roboto = FontLoader('Roboto');
  for (final f in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf', 'Roboto-Black.ttf']) {
    roboto.addFont(Future.value(ByteData.sublistView(File('$base/$f').readAsBytesSync())));
  }
  await roboto.load();
  final icones = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.sublistView(File('$base/MaterialIcons-Regular.otf').readAsBytesSync())));
  await icones.load();
}

Future<EstadoApp> _estado(Directory dir) async {
  final arm = await Armazenamento.abrir(pasta: dir);
  final perfil = Perfil(alturaCm: 178, nascimento: DateTime(1988, 4, 10), masculino: true);
  arm.perfil = perfil;
  arm.apiKey = 'x';
  final hoje = DateTime.now();
  for (var i = 45; i >= 0; i -= 1) {
    final d = DateTime(hoje.year, hoje.month, hoje.day, 7, 12).subtract(Duration(days: i));
    final peso = 84.0 - i * -0.06 - (i % 3) * 0.2;
    final imp = 480 + (i % 5) * 6;
    final c = calcularComposicao(peso: peso, impedancia: imp.toDouble(), perfil: perfil, data: d);
    arm.adicionarMedicao(Medicao(
      medidoEm: formatarDataHora(d),
      peso: double.parse(peso.toStringAsFixed(2)),
      impedancia: imp,
      imc: c.imc,
      gorduraPct: c.gorduraPct,
      aguaPct: c.aguaPct,
      musculoKg: c.musculoKg,
      ossoKg: c.ossoKg,
      visceral: c.visceral,
      metabolismoKcal: c.metabolismoKcal,
      proteinaPct: c.proteinaPct,
    ));
    final dia = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    arm.gravarAtividade([
      AtividadeDia(
        data: dia,
        passos: 6000 + (i * 937) % 7000,
        calorias: 300 + (i * 41) % 300,
        fcRepouso: 58 + (i % 6).toDouble(),
        fcMedia: 74,
        sonoMin: 330 + (i * 23) % 150,
        sonoProfundoMin: 80,
        sonoLeveMin: 220,
        sonoRemMin: 85,
        acordadoMin: 12,
        spo2Medio: 96,
      ),
    ]);
  }
  arm.marcarAtividadeEnviada(arm.atividadePendente());
  arm.tirarDaFila(arm.filaMedicoes);
  arm.ultimaSincSaude = DateTime.now();
  final app = EstadoApp()
    ..arm = arm
    ..pronto = true
    ..permissaoBluetooth = true
    ..hcDisponivel = true
    ..hcPermissao = true;
  final u = arm.ultimaMedicao!;
  app.balanca = StatusBalanca(EstadoBalanca.finalizado,
      leitura: LeituraBalanca(
          pesoKg: u.peso, impedancia: u.impedancia, estabilizado: true, removido: true, temImpedancia: true, medidoEm: u.data));
  app.salvaAgora = u.medidoEm;
  app.prato = PratoDia(
      data: dataBrasilia(DateTime.now()), refeicoes: 3, kcal: 1850, ultimaRefeicao: '${dataBrasilia(DateTime.now())} 20:15:00', aguaMl: 1750, metaAguaMl: 2500);
  return app;
}

void main() {
  late Directory dir;
  setUpAll(_fontes);
  setUp(() => dir = Directory.systemTemp.createTempSync('telas'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> render(WidgetTester t, String nome, String titulo, Widget Function(EstadoApp) tela, {double altura = 1600}) async {
    t.view.physicalSize = Size(720, altura);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    final app = await t.runAsync(() => _estado(dir));
    final chave = GlobalKey();
    await t.pumpWidget(RepaintBoundary(
      key: chave,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: temaEscuro(),
        home: Scaffold(
          appBar: AppBar(title: Text(titulo)),
          body: tela(app!),
          bottomNavigationBar: NavigationBar(selectedIndex: 0, destinations: const [
            NavigationDestination(icon: Icon(Icons.monitor_weight_outlined), label: 'Início'),
            NavigationDestination(icon: Icon(Icons.show_chart), label: 'Histórico'),
            NavigationDestination(icon: Icon(Icons.tune), label: 'Ajustes'),
          ]),
        ),
      ),
    ));
    await t.pump(const Duration(milliseconds: 600));
    final pasta = Platform.environment['SCREENSHOTS'];
    if (pasta != null) {
      await t.runAsync(() async {
        final img = await (chave.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage(pixelRatio: 2);
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        File('$pasta/$nome.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }
  }

  testWidgets('início', (t) async {
    await render(t, 'inicio', 'Saúde', (a) => TelaInicio(app: a, irParaAjustes: () {}), altura: 3000);
    expect(find.text('É você?'), findsNothing);
    expect(find.textContaining('Salvo'), findsOneWidget);
    expect(find.text('Hoje no prato'), findsOneWidget);
    expect(find.text('1.850 kcal'), findsOneWidget);
    expect(find.text('1.750 / 2.500 ml'), findsOneWidget);
    expect(find.text('atualizado 20:15'), findsOneWidget);
  });

  testWidgets('início sem refeição hoje', (t) async {
    await render(t, 'inicio_sem_refeicao', 'Saúde', (a) {
      a.prato = PratoDia(data: dataBrasilia(DateTime.now()), refeicoes: 0, kcal: 0, aguaMl: 0, metaAguaMl: 2500);
      return TelaInicio(app: a, irParaAjustes: () {});
    }, altura: 3000);
    expect(find.text('Nenhuma refeição registrada'), findsOneWidget);
    expect(find.textContaining('atualizado 20'), findsNothing);
  });

  testWidgets('histórico', (t) async {
    await render(t, 'historico', 'Histórico', (a) => TelaHistorico(app: a), altura: 2400);
    expect(find.text('Peso'), findsOneWidget);
  });

  testWidgets('ajustes', (t) async {
    await render(t, 'ajustes', 'Ajustes', (a) => TelaAjustes(app: a), altura: 2400);
    expect(find.text('Salvar perfil'), findsOneWidget);
  });
}
