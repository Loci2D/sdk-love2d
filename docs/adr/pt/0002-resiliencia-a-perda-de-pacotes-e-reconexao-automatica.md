# ADR 0002: Resiliência a Perda de Pacotes, Teto de Predição e Reconexão Automática

## Status
Aceito

## Contexto
Após a implementação da ADR 0001 (Predição no Cliente e Interpolação de Snapshots), testes físicos em rede local sem fio (Wi-Fi) entre múltiplas máquinas sem acesso à internet externa revelaram cenários de degradação sob perda severa de pacotes UDP e instabilidade de sinal de rádio:

1. **Personagem Andando Sozinho e Atravessando Paredes ("Efeito Overwatch"):** Quando o jogador mantinha teclas direcionais pressionadas durante rajadas de perda de pacotes, a predição no cliente continuava integrando a posição frame a frame sem interrupção. Como as colisões e limites do mapa são validados de forma autoritativa no servidor (`loci2d`), o personagem do cliente atravessava paredes e saía dos limites do mapa na ausência de snapshots de correção.
2. **Assimetria de Heartbeat e Estado Zumbi:** O cliente enviava pings de heartbeat a cada 2.0s, enquanto o servidor encerrava sessões inativas após 10s (`client_timeout_secs = 10`). Em Wi-Fi com oscilações, perder de 4 a 5 pings UDP em sequência acarretava a expulsão da sessão no servidor. O cliente, mantendo o `my_entity_id` preenchido e enviando pings ignorados pelo servidor, entrava em estado "zumbi" irreversível sem reiniciar o jogo.

## Decisão
Decidimos adicionar salvaguardas de resiliência de rede diretamente no `loci_client.lua`:

1. **Teto de Tempo de Predição (Prediction Horizon):**
   * Limitar a predição no cliente a uma janela máxima de silêncio (padrão: `0.200s` / 200ms) sem snapshots autoritativos do servidor.
   * Se o tempo sem pacotes exceder esse teto, congelar o deslocamento e zerar a velocidade prevista, mantendo o personagem na última posição válida até o restabelecimento da comunicação.

2. **Aceleração do Intervalo de Heartbeat:**
   * Reduzir o intervalo de ping de heartbeat de 2.0s para `0.400s` (~2.5 pings/segundo).
   * Em uma janela de inatividade de 10 segundos, isso eleva as tentativas para ~25 pings, exigindo perda contínua extrema para que ocorra timeout acidental no servidor.

3. **Watchdog de Conexão no Cliente e Reconexão Automática:**
   * Introduzir um watchdog de inatividade no cliente (padrão: `4.0s`). Se nenhum datagrama for recebido do servidor nesse período:
     * Transicionar o estado de sessão para desconectado e disparar o callback `loci.on_connection_lost(motivo)`.
     * Resetar `my_entity_id = nil` e limpar o buffer de snapshots.
     * Iniciar automaticamente tentativas de re-entrada (`JoinIntent`) com recuo temporal.
     * Quando o servidor aceitar o re-ingresso e emitir a nova entidade, restaurar o ID e disparar `loci.on_reconnected(entity_id)`.

4. **Simulador Sintético de Latência e Perda de Pacotes:**
   * Disponibilizar `simulate_packet_loss` e `simulate_latency` no `loci.netcode` para testes e diagnósticos locais sem necessidade de ferramentas de terceiros no sistema operacional.

## Consequências
- **Positivo:** Elimina o efeito de andar sozinho atravessando paredes durante quedas de pacotes; o avatar para suavemente.
- **Positivo:** Elimina o estado zumbi; clientes sobrevivem a quedas transitórias ou reconectam-se automaticamente.
- **Positivo:** Reduz drasticamente desconexões acidentais em redes Wi-Fi instáveis.
- **Positivo:** Permite à interface do jogo (UI) reagir com avisos de "Reconectando..." através de callbacks padrão.
- **Positivo:** 100% reutilizável e desacoplado de regras de jogo específicas.
- **Negativo:** Pequeno acréscimo de tráfego UDP de pings (de 0.5 para 2.5 pacotes/segundo, insignificante para redes locais modernas).
