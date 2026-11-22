import 'package:material_ui/material_ui.dart';

class Cores {
  static const fundo = Color(0xFF0B0D10);
  static const cartao = Color(0xFF15181D);
  static const cartao2 = Color(0xFF1C2027);
  static const borda = Color(0xFF262B33);
  static const texto = Color(0xFFECEFF4);
  static const suave = Color(0xFF8A93A3);
  static const ciano = Color(0xFF3DDCCB);
  static const ambar = Color(0xFFFFB454);
  static const rosa = Color(0xFFFF6B8B);
  static const violeta = Color(0xFF9D8CFF);
  static const verde = Color(0xFF6BE38E);
}

ThemeData temaEscuro() {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    colorScheme: const ColorScheme.dark(
      primary: Cores.ciano,
      secondary: Cores.ambar,
      surface: Cores.cartao,
      onSurface: Cores.texto,
      error: Cores.rosa,
    ),
    scaffoldBackgroundColor: Cores.fundo,
  );
  return base.copyWith(
    appBarTheme: const AppBarTheme(
      backgroundColor: Cores.fundo,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Cores.texto, letterSpacing: -0.3),
    ),
    cardTheme: CardThemeData(
      color: Cores.cartao,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Cores.borda)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Cores.cartao,
      indicatorColor: Cores.ciano.withValues(alpha: 0.18),
      labelTextStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12, color: Cores.suave)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Cores.cartao2,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      labelStyle: const TextStyle(color: Cores.suave),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Cores.cartao,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating, backgroundColor: Cores.cartao2),
  );
}

String num1(num? v, [int casas = 1]) => v == null ? '—' : v.toStringAsFixed(casas).replaceAll('.', ',');

String milhar(num? v) {
  if (v == null) return '—';
  final s = v.round().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write('.');
    b.write(s[i]);
  }
  return b.toString();
}

String horasMin(num? min) {
  if (min == null) return '—';
  final h = min ~/ 60;
  final m = (min - h * 60).round();
  return '${h}h${m.toString().padLeft(2, '0')}';
}

/// "+0,4" / "−1,2" com sinal.
String delta(num? v, [int casas = 1]) {
  if (v == null) return '—';
  if (v.abs() < 0.05) return '0,0';
  return '${v > 0 ? '+' : '−'}${num1(v.abs(), casas)}';
}
