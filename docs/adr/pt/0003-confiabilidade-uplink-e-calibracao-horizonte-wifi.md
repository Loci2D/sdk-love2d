# ADR 0003: Confiabilidade de Uplink (MoveIntent), Calibração do Horizonte Wi-Fi e Sincronia Pós-Reconexão

## Status
Aceito (Emenda ADR 0001 e ADR 0002)

## Contexto
Testes físicos em Wi-Fi local na mesma sala rodando o SDK `v0.6.2` contra o servidor `loci2d` (`v0.6.5-sdk.4`) mostraram que o personagem continuava congelando por vários segundos após pequenas rajadas de interferência ou perda de pacotes. Uma reprodução local controlada via proxy UDP modelando contenção Wi-Fi (jitter em rajada, perda de pacotes simples/duplos e blecautes transitórios) expôs cinco falhas interagindo entre os módulos do SDK ([`loci/init.lua`](../../loci/init.lua), [`loci/network/transport.lua`](../../loci/network/transport.lua), [`loci/network/protocol.lua`](../../loci/network/protocol.lua), [`loci/netcode/prediction.lua`](../../loci/netcode/prediction.lua)):

1. **Fragilidade de Disparo Único em Uplink UDP (`MoveIntent`):**
   * Os jogos consumidores chamam `loci.send_move(dx, dy)` apenas em bordas de mudança de direção. Na versão `v0.6.2`, o `MoveIntent` era enviado uma única vez em datagrama UDP sem confirmação.
   * Como o servidor `loci2d` mantém o último vetor de velocidade até a chegada de um novo `MoveIntent` (ou término de efeito de controle de grupo), a perda de um único pacote `MoveIntent` deixa o servidor preso no estado anterior (por exemplo, parado em `(0, 0)` mesmo com tecla pressionada, ou continuando andando após soltar a tecla) até o jogador soltar e pressionar a tecla novamente.
   * Quando efeitos de CC (*stun*, paralisia ou morte) expiram, o servidor não enfileira intenções rejeitadas anteriormente; teclas mantidas pressionadas permaneciam ignoradas até um novo pacote `MoveIntent`.

2. **Horizonte de Predição Restrito em `200ms` (`prediction_timeout`):**
   * A ADR 0002 definiu `prediction_timeout = 0.200s`. Em 30 Hz no Wi-Fi, perder ~6 snapshots `WorldState` seguidos (~200ms) ou sofrer um stall breve de contenção CSMA/CA de 250–400ms zerava a velocidade prevista no meio da corrida, causando micro-congelamentos mesmo com a sessão saudável no servidor.

3. **`get_my_entity()` Vazio em `on_reconnected` e Velocidade Travada em Zero Pós-Reconexão:**
   * Em `loci._handle_world_state`, o callback `loci.on_reconnected(id)` era disparado antes do loop de `entities` popular `loci.entities[id]`, fazendo `loci.get_my_entity()` retornar `nil` na primeira conexão/reconexão.
   * Ao atingir o watchdog (`connection_timeout`), `loci._active_move_dx/dy` eram limpos para `0`; após reconectar, se o jogador ainda segurasse uma tecla, a predição local sobrescrevia `ent.vx/vy` com `0` até que o jogo chamasse `send_move` explicitamente.

4. **Simulador Sintético de Rede Assimétrico:**
   * `simulate_packet_loss` e `simulate_latency` da ADR 0002 atuavam apenas no recebimento em `transport.lua`, mascarando falhas de uplink (`MoveIntent` perdido, dessincronia após CC) durante testes locais.

## Decisão
Evoluímos o SDK modular com confiabilidade de uplink, tolerância calibrada de predição, hooks limpos de reconexão e simulação simétrica, mantendo zero alocações no heap em regime estacionário:

1. **Keepalive Ativo de `MoveIntent` e Cauda Redundante de Parada (`loci/network/transport.lua`, `loci/init.lua`):**
   * Introduzir `loci.netcode.intent_keepalive_interval` (padrão `0.100s` / 100ms): enquanto `_active_move_dx ~= 0 or _active_move_dy ~= 0`, `poll_network` reenvia periodicamente o `MoveIntent` ativo via UDP. Em 100ms, a perda do pacote inicial se recupera automaticamente em ~100ms sem exigir nova digitação.
   * **Bloqueio Consciente de CC (`prediction.is_incapacitated`):** Enquanto a entidade local estiver morta, atordoada ou paralisada (`is_dead`, `cur_tick < stunned_until`, `cur_tick < paralyzed_until`), o keepalive pausa e registra `_was_incapacitated_with_move = true`, evitando spam de banners de rejeição (`on_intent_rejected`). Assim que o CC expira com movimento ativo, um `MoveIntent` de recuperação é disparado imediatamente.
   * Introduzir `loci.netcode.stop_redundancy_count` (padrão `3`): ao transicionar de movimento não-nulo para `(0, 0)` com socket UDP ativo, emitir até `stop_redundancy_count - 1` pacotes extras de parada espaçados em `>= 30ms` dentro de uma janela de `0.5s`, evitando que a perda do pacote de parada deixe o personagem deslizando no servidor.

2. **Calibração do Horizonte de Predição Wi-Fi (`loci/netcode/prediction.lua`, `loci/init.lua`):**
   * Elevar o padrão de `loci.netcode.prediction_timeout` de `0.200s` para `0.500s` (500ms). A 30 Hz, 500ms absorve ~15 snapshots perdidos ou pequenas rajadas Wi-Fi de forma fluida, mantendo ainda um teto seguro para impedir *ghost walking* através de paredes em quedas reais.

3. **`on_reconnected` Pós-Atualização de Entidades e Fallback de Velocidade Pós-Timeout (`loci/init.lua`, `loci/netcode/prediction.lua`):**
   * Mover a chamada de `loci.on_reconnected(id)` para logo após a atualização das entidades do snapshot, garantindo que `loci.get_my_entity()` retorne a entidade populada e atualizada.
   * Rastrear `_active_move_cleared_by_timeout`: quando o watchdog limpa `_active_move_dx/dy`, espelhar a velocidade autoritativa do servidor (`server_vx`, `server_vy`) em `ent.vx/vy` até que o jogo consumidor chame `loci.send_move(...)` (limpando a flag), evitando travar animações enquanto aguarda ressincronia de entrada.

4. **Simulador Simétrico de Envio (`loci/network/protocol.lua`, `loci/network/transport.lua`):**
   * Encaminhar pacotes de saída (exceto notificações de encerramento `disconnect`) por `protocol.deliver_encoded_packet`, aplicando `simulate_packet_loss` e enfileirando atrasos em `_delayed_outbound_queue` com verificações escalares de custo zero quando desabilitado (`<= 0`). `transport.poll_network` drena os pacotes vencidos a cada frame.

## Consequências
- **Positivo:** Perdas simples ou em rajada de `MoveIntent` (tanto início quanto parada) se autocorrigem em 30–100ms sem congelamentos nem deslizamentos residuais.
- **Positivo:** Stalls transitórios de 250–400ms no Wi-Fi deixam de interromper o movimento e animações sob o horizonte de `500ms`.
- **Positivo:** Ao sair de *stun*/morte, o movimento segurado retorna automaticamente sem poluir `on_intent_rejected` durante a incapacitação.
- **Positivo:** Jogos consumidores podem consultar `loci.get_my_entity()` com segurança dentro de `on_reconnected` e ressincronizar o estado das teclas.
- **Positivo:** Testes sintéticos locais (`simulate_packet_loss` / `simulate_latency`) reproduzem fielmente falhas bidirecionais de Wi-Fi.
- **Positivo:** Zero alocações extras por frame em regime estacionário quando a simulação de rede está desabilitada.
- **Negativo:** Em movimento contínuo, o cliente envia ~10 pacotes UDP pequenos de `MoveIntent` por segundo (antes enviados apenas em troca de direção), impacto insignificante em redes locais e modernas.
