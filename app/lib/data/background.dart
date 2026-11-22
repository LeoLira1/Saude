import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../saude/agregador.dart';
import 'armazenamento.dart';
import 'sincronizacao.dart';

/// Tarefas do WorkManager.
///  - Noturna: uma tarefa única por noite, para as 23:00 de Brasília. Ao terminar, agenda a da noite
///    seguinte. O nome leva a data ("sinc-noturna-2026-11-23"), então reagendar nunca apaga a de hoje.
///  - Reserva: a tarefa periódica de 24 h que já existia, caso a corrente da noturna se perca.
///  - Ao sair: roda logo depois que o app vai para segundo plano (o WorkManager termina mesmo se o
///    Android fechar o app).
/// O WorkManager guarda as tarefas e as restaura sozinho depois de reiniciar o celular ou atualizar o
/// app; e toda vez que o app abre, ele confere se a próxima noturna está agendada.
const tarefaNoturna = 'sinc-noturna';
const tarefaReserva = 'sinc-diaria';
const tarefaAoSair = 'sinc-ao-sair';

const horaNoturna = 23;

/// Próximo 23:00 em Brasília depois de [agora] (instante UTC).
DateTime proximaNoturna(DateTime agora) {
  final hoje23 = inicioDiaBrasilia(agora).add(const Duration(hours: horaNoturna));
  return agora.isBefore(hoje23) ? hoje23 : hoje23.add(const Duration(days: 1));
}

/// Agenda (se ainda não estiver) a próxima sincronização das 23:00 e guarda o horário para os Ajustes.
Future<void> agendarNoturna(Armazenamento arm, {DateTime? agora}) async {
  final agoraUtc = (agora ?? DateTime.now()).toUtc();
  final alvo = proximaNoturna(agoraUtc);
  await Workmanager().registerOneOffTask(
    '$tarefaNoturna-${dataBrasilia(alvo)}',
    tarefaNoturna,
    initialDelay: alvo.difference(agoraUtc),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingWorkPolicy.keep,
    backoffPolicy: BackoffPolicy.linear,
    backoffPolicyDelay: const Duration(minutes: 15),
  );
  arm.proximaNoturna = alvo;
  await arm.salvar();
}

/// Ao abrir o app: garante a noturna e a reserva diária.
Future<void> garantirAgendamentos(Armazenamento arm) async {
  await Workmanager().initialize(despachanteSegundoPlano);
  await agendarNoturna(arm);
  await Workmanager().registerPeriodicTask(
    tarefaReserva,
    tarefaReserva,
    frequency: const Duration(hours: 24),
    initialDelay: const Duration(hours: 1),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
  );
}

/// Ao sair do app: sincroniza em segundo plano logo em seguida.
Future<void> agendarAoSair() async {
  await Workmanager().registerOneOffTask(
    tarefaAoSair,
    tarefaAoSair,
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingWorkPolicy.replace,
  );
}

const origensTarefa = {tarefaNoturna: 'noturna', tarefaReserva: 'reserva diária', tarefaAoSair: 'ao sair'};

@pragma('vm:entry-point')
void despachanteSegundoPlano() {
  Workmanager().executeTask((tarefa, dados) async {
    WidgetsFlutterBinding.ensureInitialized();
    final origem = origensTarefa[tarefa] ?? tarefa;
    Armazenamento? arm;
    try {
      arm = await Armazenamento.abrir();
      await Sincronizacao(arm).tudo(origem: origem);
    } catch (e) {
      try {
        arm ??= await Armazenamento.abrir();
        arm.registrarSinc(origem: origem, ok: false, erro: '$e');
        await arm.salvar();
      } catch (_) {}
    }
    if (tarefa == tarefaNoturna) {
      // Agenda a da próxima noite (mesmo se esta falhou). Se o Android atrasou esta para depois da
      // meia-noite, a próxima continua sendo às 23:00 de hoje.
      try {
        arm ??= await Armazenamento.abrir();
        await agendarNoturna(arm);
      } catch (_) {}
    }
    return true;
  });
}
