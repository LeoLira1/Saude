import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:material_ui/material_ui.dart';

import 'estado_app.dart';
import 'tema.dart';

class TelaHistorico extends StatefulWidget {
  const TelaHistorico({super.key, required this.app});
  final EstadoApp app;
  @override
  State<TelaHistorico> createState() => _TelaHistoricoState();
}

class _TelaHistoricoState extends State<TelaHistorico> {
  int _dias = 30;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) {
        final hoje = DateTime.now();
        final inicio = _dias == 0 ? DateTime(2000) : DateTime(hoje.year, hoje.month, hoje.day).subtract(Duration(days: _dias - 1));
        final ms = widget.app.medicoes.where((m) => !m.data.isBefore(inicio)).toList();
        final at = widget.app.arm.atividade.values.where((a) => a.data.compareTo(_iso(inicio)) >= 0).toList()
          ..sort((a, b) => a.data.compareTo(b.data));
        var origem = inicio;
        if (_dias == 0) {
          // "Tudo": começa no dado mais antigo (balança ou pulseira).
          final candidatos = [
            if (ms.isNotEmpty) DateTime(ms.first.data.year, ms.first.data.month, ms.first.data.day),
            if (at.isNotEmpty) DateTime.parse(at.first.data),
          ];
          origem = candidatos.isEmpty ? DateTime(hoje.year, hoje.month, hoje.day) : candidatos.reduce((a, b) => a.isBefore(b) ? a : b);
        }
        double x(DateTime d) => d.difference(origem).inHours / 24.0;

        final peso = [for (final m in ms) FlSpot(x(m.data), m.peso)];
        final gord = [for (final m in ms) if (m.gorduraPct != null) FlSpot(x(m.data), m.gorduraPct!)];
        final passos = [for (final a in at) if (a.passos != null) (x(DateTime.parse(a.data)), a.passos!.toDouble())];
        final sono = [for (final a in at) if (a.sonoMin != null) (x(DateTime.parse(a.data)), a.sonoMin! / 60)];

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 7, label: Text('7d')),
                ButtonSegment(value: 30, label: Text('30d')),
                ButtonSegment(value: 90, label: Text('90d')),
                ButtonSegment(value: 365, label: Text('1 ano')),
                ButtonSegment(value: 0, label: Text('Tudo')),
              ],
              selected: {_dias},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _dias = s.first),
            ),
            const SizedBox(height: 14),
            _Grafico(titulo: 'Peso', unidade: 'kg', cor: Cores.ciano, resumo: _resumo(peso.map((s) => s.y), 'kg'), child: _linha(peso, Cores.ciano, origem)),
            _Grafico(titulo: 'Gordura', unidade: '%', cor: Cores.ambar, resumo: _resumo(gord.map((s) => s.y), '%'), child: _linha(gord, Cores.ambar, origem)),
            _Grafico(
              titulo: 'Passos',
              unidade: '',
              cor: Cores.verde,
              resumo: passos.isEmpty ? null : 'média ${milhar(passos.map((p) => p.$2).reduce((a, b) => a + b) / passos.length)}',
              child: _barras(passos, Cores.verde, origem),
            ),
            _Grafico(
              titulo: 'Sono',
              unidade: 'h',
              cor: Cores.violeta,
              resumo: sono.isEmpty ? null : 'média ${horasMin(sono.map((p) => p.$2).reduce((a, b) => a + b) / sono.length * 60)}',
              child: _barras(sono, Cores.violeta, origem, linhaMeta: 7),
            ),
          ],
        );
      },
    );
  }

  static String _iso(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String? _resumo(Iterable<double> v, String un) {
    final l = v.toList();
    if (l.isEmpty) return null;
    final dif = l.last - l.first;
    return '${num1(l.last)} $un · ${delta(dif)} no período';
  }

  Widget _vazio() => const Center(child: Text('Sem dados neste período', style: TextStyle(color: Cores.suave)));

  String _rotuloData(DateTime origem, double v) {
    final d = origem.add(Duration(hours: (v * 24).round()));
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
  }

  /// Intervalo "redondo" para o eixo Y (1, 2, 5 × 10^n), ~4 linhas.
  static double _passoY(double faixa) {
    if (faixa <= 0) return 1;
    final bruto = faixa / 4;
    final p = math.pow(10, (math.log(bruto) / math.ln10).floor()).toDouble();
    for (final m in [1, 2, 5, 10]) {
      if (bruto <= m * p) return m * p;
    }
    return 10 * p;
  }

  FlTitlesData _titulos(DateTime origem, double minX, double maxX, double minY, double maxY, {bool barras = false}) {
    final passo = math.max(1.0, ((maxX - minX) / 4).ceilToDouble());
    final passoY = _passoY(maxY - minY);
    final casas = passoY >= 1 ? 0 : 1;
    return FlTitlesData(
      topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      leftTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 40,
          interval: passoY,
          minIncluded: false,
          maxIncluded: false,
          getTitlesWidget: (v, meta) => SideTitleWidget(
            meta: meta,
            child: Text(v >= 1000 ? '${num1(v / 1000, v % 1000 == 0 ? 0 : 1)}k' : num1(v, casas),
                style: const TextStyle(color: Cores.suave, fontSize: 10)),
          ),
        ),
      ),
      bottomTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 24,
          interval: passo,
          getTitlesWidget: (v, meta) {
            // Nas barras o fl_chart chama para cada barra: mostra só a cada "passo" dias.
            if (barras && ((v - minX) % passo).abs() > 0.01) return const SizedBox.shrink();
            return SideTitleWidget(
              meta: meta,
              child: Text(_rotuloData(origem, v), style: const TextStyle(color: Cores.suave, fontSize: 10)),
            );
          },
        ),
      ),
    );
  }

  FlGridData get _grade => FlGridData(
        drawVerticalLine: false,
        getDrawingHorizontalLine: (_) => const FlLine(color: Cores.borda, strokeWidth: 1),
      );

  Widget _linha(List<FlSpot> pts, Color cor, DateTime origem) {
    if (pts.isEmpty) return _vazio();
    final ys = pts.map((p) => p.y);
    var minY = ys.reduce(math.min);
    var maxY = ys.reduce(math.max);
    final folga = math.max(0.5, (maxY - minY) * 0.15);
    minY -= folga;
    maxY += folga;
    final minX = pts.first.x;
    final maxX = math.max(pts.last.x, minX + 1);
    return LineChart(LineChartData(
      minX: minX,
      maxX: maxX,
      minY: minY,
      maxY: maxY,
      gridData: _grade,
      borderData: FlBorderData(show: false),
      titlesData: _titulos(origem, minX, maxX, minY, maxY),
      lineTouchData: LineTouchData(
        touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (_) => Cores.cartao2,
          getTooltipItems: (s) => s
              .map((e) => LineTooltipItem('${num1(e.y)}\n${_rotuloData(origem, e.x)}', TextStyle(color: cor, fontWeight: FontWeight.w600)))
              .toList(),
        ),
      ),
      lineBarsData: [
        LineChartBarData(
          spots: pts,
          isCurved: true,
          preventCurveOverShooting: true,
          color: cor,
          barWidth: 2.5,
          dotData: FlDotData(show: pts.length <= 31),
          belowBarData: BarAreaData(
            show: true,
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [cor.withValues(alpha: 0.28), cor.withValues(alpha: 0.0)],
            ),
          ),
        ),
      ],
    ));
  }

  Widget _barras(List<(double, double)> pts, Color cor, DateTime origem, {double? linhaMeta}) {
    if (pts.isEmpty) return _vazio();
    final maxY = math.max(pts.map((p) => p.$2).reduce(math.max) * 1.15, linhaMeta ?? 0);
    final minX = pts.first.$1;
    final maxX = math.max(pts.last.$1, minX + 1);
    final largura = (260 / math.max(pts.length, 1)).clamp(2.0, 14.0);
    return BarChart(BarChartData(
      maxY: maxY,
      gridData: _grade,
      borderData: FlBorderData(show: false),
      titlesData: _titulos(origem, minX, maxX, 0, maxY, barras: true),
      extraLinesData: linhaMeta == null
          ? null
          : ExtraLinesData(horizontalLines: [HorizontalLine(y: linhaMeta, color: cor.withValues(alpha: 0.5), dashArray: [4, 4])]),
      barTouchData: BarTouchData(
        touchTooltipData: BarTouchTooltipData(
          getTooltipColor: (_) => Cores.cartao2,
          getTooltipItem: (g, _, rod, _) => BarTooltipItem(
            '${linhaMeta != null ? horasMin(rod.toY * 60) : milhar(rod.toY)}\n${_rotuloData(origem, g.x.toDouble())}',
            TextStyle(color: cor, fontWeight: FontWeight.w600),
          ),
        ),
      ),
      barGroups: [
        for (final p in pts)
          BarChartGroupData(x: p.$1.round(), barRods: [
            BarChartRodData(toY: p.$2, color: cor, width: largura, borderRadius: BorderRadius.circular(3)),
          ]),
      ],
    ));
  }
}

class _Grafico extends StatelessWidget {
  const _Grafico({required this.titulo, required this.unidade, required this.cor, required this.child, this.resumo});
  final String titulo;
  final String unidade;
  final Color cor;
  final Widget child;
  final String? resumo;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 18, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(width: 8, height: 8, decoration: BoxDecoration(color: cor, shape: BoxShape.circle)),
                const SizedBox(width: 8),
                Text(titulo, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                if (unidade.isNotEmpty) Text('  $unidade', style: const TextStyle(color: Cores.suave, fontSize: 12)),
                const Spacer(),
                if (resumo != null) Text(resumo!, style: const TextStyle(color: Cores.suave, fontSize: 12)),
              ]),
              const SizedBox(height: 12),
              SizedBox(height: 170, child: child),
            ]),
          ),
        ),
      );
}
