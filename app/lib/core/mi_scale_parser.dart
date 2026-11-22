// Leitura do anúncio BLE da Xiaomi Mi Body Composition Scale 2 (XMTZC05HM).
//
// Service data do UUID 0x181B, 13 bytes. Layout conferido no openScale
// (MiScaleHandler.kt, parseLive13 — mesmo frame de 13 bytes do v2):
//   byte 0  : controle 0 — bit 0 (0x01) = libras
//   byte 1  : controle 1 — bit 1 (0x02) = tem impedância
//                          bit 5 (0x20) = peso estabilizado
//                          bit 6 (0x40) = catty (jin)
//                          bit 7 (0x80) = carga removida (saiu da balança)
//   bytes 2-3: ano (uint16 LE); 4 mês; 5 dia; 6 hora; 7 minuto; 8 segundo
//   bytes 9-10 : impedância (uint16 LE)
//   bytes 11-12: peso (uint16 LE) — kg: ÷ 200; libras/catty: ÷ 100

/// UUID 16 bits do Body Composition Service.
const String uuidBodyComposition = '181b';

class LeituraBalanca {
  final double pesoKg;
  final int? impedancia;
  final bool estabilizado;
  final bool removido;
  final bool temImpedancia;

  /// Data/hora da medição como a balança informou (horário local), ou null se o relógio dela for inválido.
  final DateTime? medidoEm;

  const LeituraBalanca({
    required this.pesoKg,
    required this.impedancia,
    required this.estabilizado,
    required this.removido,
    required this.temImpedancia,
    required this.medidoEm,
  });

  /// Medição final: estabilizada E com impedância válida.
  bool get finalComImpedancia => estabilizado && temImpedancia && impedancia != null;

  /// Chave única "AAAA-MM-DD HH:MM:SS" (a balança repete o mesmo anúncio várias vezes).
  String? get chave => medidoEm == null ? null : formatarDataHora(medidoEm!);

  @override
  String toString() =>
      'LeituraBalanca($pesoKg kg, imp=$impedancia, estab=$estabilizado, removido=$removido, em=$chave)';
}

String _dois(int v) => v.toString().padLeft(2, '0');

String formatarDataHora(DateTime d) =>
    '${d.year}-${_dois(d.month)}-${_dois(d.day)} ${_dois(d.hour)}:${_dois(d.minute)}:${_dois(d.second)}';

/// Lê os 13 bytes. Devolve null se não for um frame válido.
LeituraBalanca? lerAnuncioMiScale2(List<int> d) {
  if (d.length != 13) return null;
  final c0 = d[0] & 0xFF;
  final c1 = d[1] & 0xFF;
  final libras = (c0 & 0x01) != 0;
  final catty = (c1 & 0x40) != 0;
  final estabilizado = (c1 & 0x20) != 0;
  final removido = (c1 & 0x80) != 0;
  final temImp = (c1 & 0x02) != 0;

  final ano = ((d[3] & 0xFF) << 8) | (d[2] & 0xFF);
  final mes = d[4] & 0xFF;
  final dia = d[5] & 0xFF;
  final hora = d[6] & 0xFF;
  final min = d[7] & 0xFF;
  final seg = d[8] & 0xFF;

  final impRaw = ((d[10] & 0xFF) << 8) | (d[9] & 0xFF);
  final pesoRaw = ((d[12] & 0xFF) << 8) | (d[11] & 0xFF);

  double peso;
  if (libras) {
    peso = pesoRaw / 100.0 * 0.45359237;
  } else if (catty) {
    peso = pesoRaw / 100.0 * 0.5;
  } else {
    peso = pesoRaw / 200.0;
  }
  peso = (peso * 100).roundToDouble() / 100;

  DateTime? em;
  final dataOk = ano >= 2015 && ano <= 2100 && mes >= 1 && mes <= 12 && dia >= 1 && dia <= 31 && hora < 24 && min < 60 && seg < 60;
  if (dataOk) {
    final t = DateTime(ano, mes, dia, hora, min, seg);
    // DateTime normaliza 31/02 → março; se mudou, a data era inválida.
    if (t.month == mes && t.day == dia) em = t;
  }

  // Impedância 0 ou absurda (≥ 3000 Ω) = medição sem bioimpedância (ex.: de meia).
  final impValida = temImp && impRaw > 0 && impRaw < 3000;

  return LeituraBalanca(
    pesoKg: peso,
    impedancia: impValida ? impRaw : null,
    estabilizado: estabilizado,
    removido: removido,
    temImpedancia: impValida,
    medidoEm: em,
  );
}
