import 'package:material_ui/material_ui.dart';

import '../balanca/servico_balanca.dart';
import '../data/modelos.dart';
import 'estado_app.dart';
import 'tema.dart';

class TelaInicio extends StatefulWidget {
  const TelaInicio({super.key, required this.app, required this.irParaAjustes});
  final EstadoApp app;
  final VoidCallback irParaAjustes;

  @override
  State<TelaInicio> createState() => _TelaInicioState();
}

class _TelaInicioState extends State<TelaInicio> {
  bool _dialogoAberto = false;

  @override
  void initState() {
    super.initState();
    widget.app.addListener(_talvezPerguntar);
  }

  @override
  void dispose() {
    widget.app.removeListener(_talvezPerguntar);
    super.dispose();
  }

  Future<void> _talvezPerguntar() async {
    final m = widget.app.aConfirmar;
    if (m == null || _dialogoAberto || !mounted) return;
    _dialogoAberto = true;
    final ult = widget.app.ultima;
    final souEu = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        title: const Text('É você?'),
        content: Text(
          'A balança mediu ${num1(m.peso, 2)} kg, '
          '${num1((m.peso - (ult?.peso ?? m.peso)).abs())} kg de diferença da sua última medição '
          '(${num1(ult?.peso, 2)} kg).\n\nSe foi outra pessoa, não salvo.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Não, descartar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Sou eu, salvar')),
        ],
      ),
    );
    _dialogoAberto = false;
    await widget.app.responderEVoce(souEu == true);
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final ult = app.ultima;
        return RefreshIndicator(
          color: Cores.ciano,
          onRefresh: () => app.sincronizar(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              if (!app.arm.configurado)
                _Aviso(
                  icone: Icons.person_outline,
                  texto: 'Preencha altura, nascimento e sexo para calcular gordura, músculo e o resto.',
                  botao: 'Abrir perfil',
                  aoTocar: widget.irParaAjustes,
                ),
              if (!app.permissaoBluetooth)
                _Aviso(
                  icone: Icons.bluetooth_searching,
                  texto: 'Para ler a balança, o app precisa de Bluetooth e Localização. '
                      'O Android pede Localização para qualquer leitura Bluetooth; o app não usa onde você está.',
                  botao: 'Permitir',
                  aoTocar: app.pedirBluetooth,
                ),
              _CartaoBalanca(app: app),
              const SizedBox(height: 14),
              if (ult == null)
                const _Vazio()
              else ...[
                _CartaoPeso(app: app, m: ult),
                const SizedBox(height: 14),
                _GradeComposicao(m: ult, pesoIdeal: _pesoIdeal(app)),
              ],
              const SizedBox(height: 14),
              _CartaoPulseira(app: app, irParaAjustes: widget.irParaAjustes),
              if (app.avisoSinc != null || app.pendentes > 0) ...[
                const SizedBox(height: 12),
                Text(
                  [
                    if (app.pendentes > 0) '${app.pendentes} item(ns) aguardando envio',
                    if (app.avisoSinc != null) app.avisoSinc!,
                  ].join(' · '),
                  style: const TextStyle(color: Cores.suave, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  double? _pesoIdeal(EstadoApp app) {
    final p = app.arm.perfil;
    if (p == null) return null;
    final h = p.alturaCm / 100;
    return 22 * h * h;
  }
}

class _Aviso extends StatelessWidget {
  const _Aviso({required this.icone, required this.texto, required this.botao, required this.aoTocar});
  final IconData icone;
  final String texto;
  final String botao;
  final VoidCallback aoTocar;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Card(
          color: Cores.cartao2,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Icon(icone, color: Cores.ambar),
              const SizedBox(width: 12),
              Expanded(child: Text(texto, style: const TextStyle(fontSize: 13, height: 1.35))),
              const SizedBox(width: 8),
              FilledButton.tonal(onPressed: aoTocar, child: Text(botao)),
            ]),
          ),
        ),
      );
}

class _CartaoBalanca extends StatelessWidget {
  const _CartaoBalanca({required this.app});
  final EstadoApp app;

  @override
  Widget build(BuildContext context) {
    final s = app.balanca;
    final l = s.leitura;
    String titulo;
    String sub;
    Color cor = Cores.ciano;
    bool pulsando = false;
    switch (s.estado) {
      case EstadoBalanca.parado:
        titulo = 'Balança desligada';
        sub = app.permissaoBluetooth ? 'Toque para escutar' : 'Permita o Bluetooth acima';
        cor = Cores.suave;
      case EstadoBalanca.ouvindo:
        titulo = 'Suba na balança';
        sub = 'Descalço, para medir a composição';
        pulsando = true;
      case EstadoBalanca.medindo:
        titulo = '${num1(l?.pesoKg, 2)} kg';
        sub = 'Pesando…';
        pulsando = true;
      case EstadoBalanca.estabilizado:
        titulo = '${num1(l?.pesoKg, 2)} kg';
        sub = 'Medindo composição… fique parado';
        cor = Cores.ambar;
        pulsando = true;
      case EstadoBalanca.finalizado:
        titulo = '${num1(l?.pesoKg, 2)} kg';
        sub = app.salvaAgora != null && app.salvaAgora == l?.chave
            ? 'Salvo ✓ ${app.pendentes > 0 ? '(envio pendente)' : 'e enviado'}'
            : 'Medição concluída';
        cor = Cores.verde;
      case EstadoBalanca.erro:
        titulo = l != null ? '${num1(l.pesoKg, 2)} kg' : 'Atenção';
        sub = s.mensagem ?? 'Erro';
        cor = Cores.rosa;
    }
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: s.estado == EstadoBalanca.parado || s.estado == EstadoBalanca.erro ? app.ligarBalanca : null,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(children: [
            _Pulso(cor: cor, ativo: pulsando),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(titulo,
                    style: TextStyle(
                        fontSize: s.estado == EstadoBalanca.ouvindo || s.estado == EstadoBalanca.parado ? 20 : 30,
                        fontWeight: FontWeight.w700,
                        color: Cores.texto,
                        fontFeatures: const [FontFeature.tabularFigures()])),
                const SizedBox(height: 2),
                Text(sub, style: TextStyle(color: cor == Cores.suave ? Cores.suave : cor, fontSize: 13)),
              ]),
            ),
            const Icon(Icons.monitor_weight_outlined, color: Cores.suave),
          ]),
        ),
      ),
    );
  }
}

class _Pulso extends StatefulWidget {
  const _Pulso({required this.cor, required this.ativo});
  final Color cor;
  final bool ativo;
  @override
  State<_Pulso> createState() => _PulsoState();
}

class _PulsoState extends State<_Pulso> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 44,
        height: 44,
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, _) {
            final t = widget.ativo ? _c.value : 0.0;
            return Stack(alignment: Alignment.center, children: [
              Container(
                width: 18 + 26 * t,
                height: 18 + 26 * t,
                decoration: BoxDecoration(shape: BoxShape.circle, color: widget.cor.withValues(alpha: 0.25 * (1 - t))),
              ),
              Container(width: 14, height: 14, decoration: BoxDecoration(shape: BoxShape.circle, color: widget.cor)),
            ]);
          },
        ),
      );
}

class _Vazio extends StatelessWidget {
  const _Vazio();
  @override
  Widget build(BuildContext context) => const Card(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Nenhuma medição ainda. Suba na balança com o app aberto.',
              textAlign: TextAlign.center, style: TextStyle(color: Cores.suave)),
        ),
      );
}

class _CartaoPeso extends StatelessWidget {
  const _CartaoPeso({required this.app, required this.m});
  final EstadoApp app;
  final Medicao m;

  @override
  Widget build(BuildContext context) {
    final ant = app.anterior;
    final m30 = app.de30Dias;
    final d = m.data;
    final quando =
        '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} às ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Último peso · $quando${m.origem == 'manual' ? ' · manual' : ''}',
              style: const TextStyle(color: Cores.suave, fontSize: 13)),
          const SizedBox(height: 6),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(num1(m.peso, 1),
                style: const TextStyle(
                    fontSize: 64, fontWeight: FontWeight.w800, height: 1, letterSpacing: -2, color: Cores.texto)),
            const Padding(
              padding: EdgeInsets.only(left: 6, bottom: 8),
              child: Text('kg', style: TextStyle(fontSize: 20, color: Cores.suave)),
            ),
          ]),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: _Variacao(rotulo: 'vs. anterior', valor: ant == null ? null : m.peso - ant.peso)),
            const SizedBox(width: 10),
            Expanded(child: _Variacao(rotulo: 'vs. 30 dias', valor: m30 == null ? null : m.peso - m30.peso)),
          ]),
        ]),
      ),
    );
  }
}

class _Variacao extends StatelessWidget {
  const _Variacao({required this.rotulo, required this.valor});
  final String rotulo;
  final double? valor;

  @override
  Widget build(BuildContext context) {
    final v = valor;
    final cor = v == null || v.abs() < 0.05 ? Cores.suave : (v < 0 ? Cores.verde : Cores.ambar);
    final icone = v == null || v.abs() < 0.05 ? Icons.remove : (v < 0 ? Icons.south_east : Icons.north_east);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: Cores.cartao2, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icone, size: 18, color: cor),
          const SizedBox(width: 6),
          Flexible(
            child: Text(v == null ? '—' : '${delta(v)} kg',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: cor, fontWeight: FontWeight.w700, fontSize: 16)),
          ),
        ]),
        const SizedBox(height: 2),
        Text(rotulo, style: const TextStyle(color: Cores.suave, fontSize: 12)),
      ]),
    );
  }
}

class _GradeComposicao extends StatelessWidget {
  const _GradeComposicao({required this.m, required this.pesoIdeal});
  final Medicao m;
  final double? pesoIdeal;

  @override
  Widget build(BuildContext context) {
    final itens = [
      ('IMC', num1(m.imc), '', Cores.ciano),
      ('Gordura', num1(m.gorduraPct), '%', Cores.ambar),
      ('Visceral', num1(m.visceral, 0), '', Cores.rosa),
      ('Músculo', num1(m.musculoKg), 'kg', Cores.violeta),
    ];
    final menores = [
      ('Água', '${num1(m.aguaPct)}%'),
      ('Osso', '${num1(m.ossoKg)} kg'),
      ('Metab. basal', '${milhar(m.metabolismoKcal)} kcal'),
      ('Proteína', '${num1(m.proteinaPct)}%'),
      ('Peso ideal', '${num1(pesoIdeal)} kg'),
      ('Impedância', '${m.impedancia ?? '—'} Ω'),
    ];
    return Column(children: [
      GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1.9,
        children: [
          for (final (rotulo, valor, un, cor) in itens)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Row(children: [
                    Container(width: 8, height: 8, decoration: BoxDecoration(color: cor, shape: BoxShape.circle)),
                    const SizedBox(width: 8),
                    Text(rotulo, style: const TextStyle(color: Cores.suave, fontSize: 13)),
                  ]),
                  Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(valor, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, height: 1)),
                    if (un.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 4, bottom: 2),
                        child: Text(un, style: const TextStyle(color: Cores.suave)),
                      ),
                  ]),
                ]),
              ),
            ),
        ],
      ),
      const SizedBox(height: 10),
      Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final (r, v) in menores)
                SizedBox(
                  width: (MediaQuery.sizeOf(context).width - 32 - 32 - 20) / 3,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(r, style: const TextStyle(color: Cores.suave, fontSize: 11)),
                    const SizedBox(height: 2),
                    Text(v, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                  ]),
                ),
            ],
          ),
        ),
      ),
    ]);
  }
}

class _CartaoPulseira extends StatelessWidget {
  const _CartaoPulseira({required this.app, required this.irParaAjustes});
  final EstadoApp app;
  final VoidCallback irParaAjustes;

  @override
  Widget build(BuildContext context) {
    if (!app.hcPermissao) {
      return _Aviso(
        icone: Icons.watch_outlined,
        texto: app.hcDisponivel == false
            ? 'Para ver os dados da Mi Band, instale o Health Connect (abre a Play Store).'
            : 'Para ver passos, sono e batimentos da Mi Band, libere a leitura no Health Connect.',
        botao: app.hcDisponivel == false ? 'Instalar' : 'Conectar',
        aoTocar: app.conectarHealthConnect,
      );
    }
    final hoje = DateTime.now();
    final h = app.atividadeDe(hoje);
    final ontem = app.atividadeDe(hoje.subtract(const Duration(days: 1)));
    // FC de repouso: a de hoje (se o Mi Fitness mandou) ou a de ontem; "est." = calculada pelo app.
    final diaFc = h?.fcRepouso != null ? h : ontem;
    final fc = diaFc?.fcRepouso;
    final fcTxt = fc == null ? '—' : '${fc.round()} bpm${diaFc!.fcRepousoEstimada == true ? ' (est.)' : ''}${diaFc == ontem ? ' · ontem' : ''}';
    final itens = [
      (Icons.directions_walk, 'Passos', milhar(h?.passos), Cores.ciano),
      (Icons.local_fire_department_outlined, 'Calorias ativas', h?.calorias == null ? '—' : '${milhar(h!.calorias)} kcal', Cores.ambar),
      (Icons.bedtime_outlined, 'Sono (última noite)', horasMin(h?.sonoMin), Cores.violeta),
      (Icons.favorite_border, 'FC de repouso', fcTxt, Cores.rosa),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('Hoje na pulseira', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const Spacer(),
            if (app.sincronizando)
              const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
            else
              Text(_quando(app.arm.ultimaSincSaude), style: const TextStyle(color: Cores.suave, fontSize: 12)),
          ]),
          const SizedBox(height: 12),
          for (final (ic, rot, val, cor) in itens)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                Icon(ic, color: cor, size: 22),
                const SizedBox(width: 12),
                Text(rot, style: const TextStyle(color: Cores.suave)),
                const Spacer(),
                Text(val, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              ]),
            ),
          if (h?.sonoMin != null && (h!.sonoProfundoMin ?? 0) > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _BarraSono(d: h),
            ),
        ]),
      ),
    );
  }

  String _quando(DateTime? d) {
    if (d == null) return 'sem sincronizar';
    return 'atualizado ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}

class _BarraSono extends StatelessWidget {
  const _BarraSono({required this.d});
  final AtividadeDia d;

  @override
  Widget build(BuildContext context) {
    final partes = [
      (d.sonoProfundoMin ?? 0, Cores.violeta, 'Profundo'),
      (d.sonoLeveMin ?? 0, Cores.ciano, 'Leve'),
      (d.sonoRemMin ?? 0, Cores.ambar, 'REM'),
      (d.acordadoMin ?? 0, Cores.rosa, 'Acordado'),
    ].where((p) => p.$1 > 0).toList();
    final total = partes.fold<double>(0, (s, p) => s + p.$1);
    if (total <= 0) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Row(children: [
          for (final p in partes)
            Expanded(flex: (p.$1 * 10).round().clamp(1, 100000), child: Container(height: 10, color: p.$2)),
        ]),
      ),
      const SizedBox(height: 6),
      Wrap(spacing: 12, children: [
        for (final p in partes)
          Text('${p.$3} ${horasMin(p.$1)}', style: TextStyle(color: p.$2, fontSize: 11)),
      ]),
    ]);
  }
}
