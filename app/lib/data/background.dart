import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import 'armazenamento.dart';
import 'sincronizacao.dart';

const tarefaDiaria = 'sinc-diaria';

/// Roda no segundo plano (WorkManager), 1x por dia, com internet.
@pragma('vm:entry-point')
void despachanteSegundoPlano() {
  Workmanager().executeTask((tarefa, dados) async {
    WidgetsFlutterBinding.ensureInitialized();
    Armazenamento? arm;
    try {
      arm = await Armazenamento.abrir();
      await Sincronizacao(arm).tudo(segundoPlano: true);
    } catch (e) {
      // Registra para aparecer em Ajustes; o WorkManager tenta de novo no próximo ciclo.
      try {
        arm ??= await Armazenamento.abrir();
        arm.statusSegundoPlano = {'quando': DateTime.now().toIso8601String(), 'ok': false, 'erro': '$e'};
        await arm.salvar();
      } catch (_) {}
    }
    return true;
  });
}

Future<void> agendarSincDiaria() async {
  await Workmanager().initialize(despachanteSegundoPlano);
  await Workmanager().registerPeriodicTask(
    tarefaDiaria,
    tarefaDiaria,
    frequency: const Duration(hours: 24),
    initialDelay: const Duration(hours: 1),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
  );
}
