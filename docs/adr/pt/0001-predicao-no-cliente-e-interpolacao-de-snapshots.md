# ADR 0001: Predição no Cliente e Interpolação de Snapshots para Compensação de Latência

## Status
Aceito

## Contexto
Seguindo o [ADR 0020](file:///home/furlan/Documentos/workspace/loci2d/docs/adr/pt/0020-desacoplamento-e-extracao-dos-sdks-de-cliente.md) do `loci2d`, o SDK de cliente para Love2D foi extraído para um repositório dedicado (`Loci2D/sdk-love2d`).

Ao testar partidas multiplayer em rede local sem fio (Wi-Fi) sem acesso à internet externa, observou-se forte sensação de jitter visual e controles travados/lentos. As causas raízes identificadas foram:
1. **Resposta Atrelada ao WorldState do Servidor:** O avatar do jogador local movia-se exclusivamente quando recebia os snapshots autoritativos de `WorldState` enviados pelo servidor. Mesmo em Wi-Fi local com ping baixo (5–15ms), variações no tempo de entrega dos pacotes e o atraso natural do tick do servidor (33.3ms a 30Hz) geravam atraso perceptível de controle e congelamentos intermitentes.
2. **Jitter de Câmera:** Em jogos cliente como `loci-arena`, a câmera do jogo é ancorada diretamente na posição do jogador local. Qualquer micro-atraso na chegada do pacote congelava a cena inteira na tela.
3. **Overshoot por Extrapolação em Entidades Remotas:** Para outros jogadores, extrapolar a posição futura com base na velocidade instantânea causava correções bruscas (*snapping/rubberbanding*) sempre que um personagem parava ou mudava de direção repentinamente.

## Decisão
Decidimos implementar uma arquitetura de compensação de latência em duas camadas, totalmente agnóstica de jogo, dentro do `loci_client.lua`:

### 1. Interpolação de Snapshots para Entidades Remotas
* Manter um buffer circular com os snapshots mais recentes do servidor (padrão de 8 snapshots).
* Renderizar entidades remotas em um timestamp histórico interpolado:
  $$\text{render\_time} = \text{current\_time} - \text{interpolation\_delay}$$
* Estabelecer um atraso de interpolação fixo e seguro de **50ms** (~1.5 ticks a 30Hz) por padrão, absorvendo totalmente o jitter de rádio do Wi-Fi local sem a necessidade de heurísticas adaptativas complexas na v1.

### 2. Predição Cinemática no Cliente para o Avatar Local
* Reter internamente a direção ativa de entrada de movimento entre frames, garantindo deslocamento contínuo mesmo quando o jogo consumidor só emite `send_move()` em mudanças de direção.
* Aplicar deslocamento imediato a cada frame no `loci.update(dt)`:
  $$\Delta \text{pos} = \vec{\text{dir}} \times (\text{move\_speed} \times \text{server\_tick\_rate}) \times dt$$
* Obter dinamicamente a velocidade a partir das propriedades sincronizadas da entidade (`"move_speed"`, com fallback para `"speed"` ou padrão de configuração), adaptando-se naturalmente a buffs/debuffs aplicados pelo servidor (lentidão, dashes, etc.).
* Respeitar propriedades de controle de grupo do servidor (`"stunned_until"`, `"paralyzed_until"`, `"is_dead"`), pausando a predição enquanto a entidade estiver incapacitada.

### 3. Reconciliação Suave de Posição
* Discrepâncias entre a posição prevista e os snapshots autoritativos do servidor são amortecidas por decaimento exponencial de erro ($E_{t+dt} = E_t \cdot e^{-\lambda dt}$) em vez de snaps visuais, com um limite de tolerância para snap rígido (padrão de 50px) reservado para teleportes ou colisões severas.

### 4. Extensibilidade Modular
* Expor a tabela de configuração `loci.netcode` para ajuste fino em nível de jogo.
* Fornecer o hook `loci.set_prediction_handler(fn)` para permitir que jogos futuros com física complexa ou antecipação de colisão forneçam sua própria lógica de predição.

## Consequências
- **Positivo:** O atraso de controle percebido pelo jogador local cai para $0\text{ms}$; a movimentação do avatar e da câmera tornam-se 100% fluidas.
- **Positivo:** O jitter dos outros jogadores no Wi-Fi local é eliminado via interpolação de estados passados.
- **Positivo:** 100% reaproveitável em qualquer jogo futuro que utilize o `sdk-love2d`.
- **Positivo:** Mantém a autoridade total do servidor; o servidor continua sendo a única fonte de verdade para regras de jogo e posições físicas.
- **Negativo:** Adiciona pequeno overhead de memória para os buffers circulares de snapshots.
- **Negativo:** Jogadores remotos são renderizados com um atraso imperceptível de 50ms.
