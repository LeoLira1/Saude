import 'package:material_ui/material_ui.dart';

import '../core/composicao.dart';
import '../data/api.dart';
import '../saude/agregador.dart';
import 'estado_app.dart';
import 'tema.dart';

class TelaAjustes extends StatefulWidget {
  const TelaAjustes({super.key, required this.app});
  final EstadoApp app;
  @override
  State<TelaAjustes> createState() => _TelaAjustesState();
}

class _TelaAjustesState extends State<TelaAjustes> {
  late final TextEditingController _altura;
  late final TextEditingController _nasc;
  late final TextEditingController _url;
  late final TextEditingController _chave;
  bool _masculino = true;
  bool _verChave = false;
  String? _testeApi;

  @override
  void initState() {
    super.initState();
    final arm = widget.app.arm;
    final p = arm.perfil;
    _altura = TextEditingController(text: p == null ? '' : num1(p.alturaCm, 0));
    _nasc = TextEditingController(text: p == null ? '' : _fmtData(p.nascimento));
    _masculino = p?.masculino ?? true;
    _url = TextEditingController(text: arm.apiUrl);
    _chave = TextEditingController(text: arm.apiKey);
  }

  @override
  void dispose() {
    for (final c in [_altura, _nasc, _url, _chave]) {
      c.dispose();
    }
    super.dispose();
  }

  String _fmtData(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  DateTime? _lerData(String s) {
    final m = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})$').firstMatch(s.trim());
    if (m == null) return null;
    final d = DateTime(int.parse(m[3]!), int.parse(m[2]!), int.parse(m[1]!));
    return d.day == int.parse(m[1]!) && d.month == int.parse(m[2]!) ? d : null;
  }

  void _msg(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<void> _salvarPerfil() async {
    final h = double.tryParse(_altura.text.replaceAll(',', '.'));
    final n = _lerData(_nasc.text);
    if (h == null || h < 100 || h > 230) return _msg('Altura em cm, ex.: 178');
    if (n == null || n.isAfter(DateTime.now())) return _msg('Nascimento no formato DD/MM/AAAA');
    await widget.app.salvarPerfil(Perfil(alturaCm: h, nascimento: n, masculino: _masculino));
    _msg('Perfil salvo');
  }

  Future<void> _escolherData() async {
    final atual = _lerData(_nasc.text) ?? DateTime(1990, 1, 1);
    final d = await showDatePicker(
      context: context,
      initialDate: atual,
      firstDate: DateTime(1920),
      lastDate: DateTime.now(),
      initialDatePickerMode: DatePickerMode.year,
    );
    if (d != null) setState(() => _nasc.text = _fmtData(d));
  }

  Future<void> _salvarApi() async {
    setState(() => _testeApi = 'Testando…');
    try {
      await ApiSaude(_url.text.trim().replaceAll(RegExp(r'/+$'), ''), _chave.text.trim()).ping();
      await widget.app.salvarApi(_url.text, _chave.text);
      setState(() => _testeApi = 'Conectado ✓');
    } catch (e) {
      await widget.app.salvarApi(_url.text, _chave.text);
      setState(() => _testeApi = 'Salvo, mas o teste falhou: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _Secao(titulo: 'Perfil', subtitulo: 'Usado nas fórmulas de composição corporal', children: [
            TextField(
              controller: _altura,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Altura (cm)'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _nasc,
              keyboardType: TextInputType.datetime,
              decoration: InputDecoration(
                labelText: 'Nascimento (DD/MM/AAAA)',
                suffixIcon: IconButton(icon: const Icon(Icons.calendar_month), onPressed: _escolherData),
              ),
            ),
            const SizedBox(height: 10),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Masculino')),
                ButtonSegment(value: false, label: Text('Feminino')),
              ],
              selected: {_masculino},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _masculino = s.first),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: _salvarPerfil, child: const Text('Salvar perfil')),
          ]),
          _Secao(titulo: 'Servidor', subtitulo: 'Para onde as medições vão (Worker na Cloudflare)', children: [
            TextField(controller: _url, decoration: const InputDecoration(labelText: 'Endereço da API')),
            const SizedBox(height: 10),
            TextField(
              controller: _chave,
              obscureText: !_verChave,
              decoration: InputDecoration(
                labelText: 'Chave da API (APP_API_KEY)',
                suffixIcon: IconButton(
                  icon: Icon(_verChave ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _verChave = !_verChave),
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: _salvarApi, child: const Text('Salvar e testar')),
            if (_testeApi != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_testeApi!, style: const TextStyle(color: Cores.suave)),
              ),
            if (app.pendentes > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('${app.pendentes} item(ns) aguardando envio', style: const TextStyle(color: Cores.ambar)),
              ),
          ]),
          _Secao(titulo: 'Mi Band (Health Connect)', subtitulo: 'Passos, calorias, batimentos, sono e SpO2', children: [
            Row(children: [
              Icon(app.hcPermissao ? Icons.check_circle : Icons.error_outline,
                  color: app.hcPermissao ? Cores.verde : Cores.ambar),
              const SizedBox(width: 8),
              Expanded(
                child: Text(app.hcDisponivel == false
                    ? 'Health Connect não instalado'
                    : app.hcPermissao
                        ? 'Leitura liberada'
                        : 'Leitura ainda não liberada'),
              ),
              FilledButton.tonal(
                onPressed: app.conectarHealthConnect,
                child: Text(app.hcDisponivel == false ? 'Instalar' : (app.hcPermissao ? 'Revisar' : 'Conectar')),
              ),
            ]),
            const SizedBox(height: 10),
            const Text(
              'No app Mi Fitness: Perfil → Dados de terceiros → Health Connect → libere todas as categorias '
              '(passos, calorias, frequência cardíaca, oxigênio no sangue e sono). '
              'O Mi Fitness grava lá e este app só lê; a pulseira continua pareada com o Mi Fitness.',
              style: TextStyle(color: Cores.suave, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 10),
            _SegundoPlano(app: app),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: app.sincronizando ? null : () => app.sincronizar(origem: 'manual'),
              icon: const Icon(Icons.sync),
              label: Text(app.sincronizando ? 'Sincronizando…' : 'Sincronizar agora'),
            ),
          ]),
          _Secao(titulo: 'Bluetooth', subtitulo: 'Leitura direta da balança, sem parear', children: [
            Row(children: [
              Icon(app.permissaoBluetooth ? Icons.check_circle : Icons.error_outline,
                  color: app.permissaoBluetooth ? Cores.verde : Cores.ambar),
              const SizedBox(width: 8),
              Expanded(child: Text(app.permissaoBluetooth ? 'Permitido' : 'Sem permissão')),
              if (!app.permissaoBluetooth) FilledButton.tonal(onPressed: app.pedirBluetooth, child: const Text('Permitir')),
            ]),
          ]),
        ],
      ),
    );
  }
}

class _Secao extends StatelessWidget {
  const _Secao({required this.titulo, required this.subtitulo, required this.children});
  final String titulo;
  final String subtitulo;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(titulo, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
              const SizedBox(height: 2),
              Text(subtitulo, style: const TextStyle(color: Cores.suave, fontSize: 12)),
              const SizedBox(height: 14),
              ...children,
            ]),
          ),
        ),
      );
}

/// Situação da sincronização: última (e origem), última noturna e próxima das 23:00.
class _SegundoPlano extends StatelessWidget {
  const _SegundoPlano({required this.app});
  final EstadoApp app;

  /// "23/11 às 23:04" no horário de Brasília.
  static String quando(DateTime? d) {
    if (d == null) return '—';
    final l = emBrasilia(d);
    String z(int v) => v.toString().padLeft(2, '0');
    return '${z(l.day)}/${z(l.month)} às ${z(l.hour)}:${z(l.minute)}';
  }

  static String linhaSinc(String rotulo, Map<String, dynamic>? st) {
    if (st == null) return '$rotulo: ainda não houve.';
    final q = quando(DateTime.tryParse('${st['quando']}'));
    final origem = st['origem'] ?? '';
    if (st['ok'] == true) return '$rotulo: $q · $origem · deu certo ✓ (${st['dias_lidos'] ?? 0} dias lidos, ${st['dias_enviados'] ?? 0} enviados)';
    return '$rotulo: $q · $origem · ERRO: ${st['erro'] ?? 'desconhecido'}';
  }

  @override
  Widget build(BuildContext context) {
    if (!app.hcPermissao) return const SizedBox.shrink();
    final arm = app.arm;
    final ultima = arm.ultimaSinc;
    final noturna = arm.ultimaNoturna;
    final String permTxt;
    Widget? botao;
    var ok = ultima == null || ultima['ok'] == true;
    if (!app.hcSegundoPlanoDisponivel) {
      ok = false;
      permTxt = 'O Health Connect deste celular não permite ler com o app fechado: a sincronização das 23:00 '
          'não consegue ler. Atualize o Health Connect na Play Store, ou abra o app pelo menos 1 vez a cada 7 dias.';
    } else if (!app.hcSegundoPlanoAutorizado) {
      ok = false;
      permTxt = 'Falta liberar "acessar dados em segundo plano" no Health Connect: sem isso, a sincronização das 23:00 não lê nada.';
      botao = FilledButton.tonal(onPressed: app.pedirSegundoPlano, child: const Text('Liberar'));
    } else {
      permTxt = 'Leitura com o app fechado liberada.';
    }
    final linhas = [
      linhaSinc('Última sincronização', ultima),
      if (ultima?['origem'] != 'noturna') linhaSinc('Última noturna', noturna),
      'Próxima noturna (23:00): ${quando(arm.proximaNoturna)}',
      if (arm.descartadas.isNotEmpty)
        'Medições da balança descartadas (reenvio/repetição): ${arm.descartadas.length}, '
            'a última de ${arm.descartadas.last['medido_em']} (${arm.descartadas.last['peso']} kg, ${arm.descartadas.last['impedancia']} Ω)',
    ];
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Cores.cartao2, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(ok ? Icons.check_circle : Icons.warning_amber_rounded, size: 18, color: ok ? Cores.verde : Cores.ambar),
          const SizedBox(width: 8),
          const Expanded(child: Text('Sincronização', style: TextStyle(fontWeight: FontWeight.w600))),
          ?botao,
        ]),
        const SizedBox(height: 6),
        Text(permTxt, style: const TextStyle(color: Cores.suave, fontSize: 12, height: 1.35)),
        for (final l in linhas) ...[
          const SizedBox(height: 4),
          Text(l,
              style: TextStyle(
                  color: l.contains('ERRO') ? Cores.rosa : Cores.suave, fontSize: 12, height: 1.35)),
        ],
      ]),
    );
  }
}
