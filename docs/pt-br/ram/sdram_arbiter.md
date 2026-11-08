# sdram_arbiter

## 1. Função do componente no SoC

Árbitro de três mestres que compartilham a interface de pedido do controlador da SDRAM. Os mestres são a ponte de dados do núcleo (A), a ponte de instruções do núcleo (I) e o mestre da porta de depuração (B). O árbitro atende um pedido por vez, repassa os campos do pedido ao controlador e devolve ao mestre o dado lido e a confirmação. Com vários mestres esperando, eles se revezam, e nenhum espera mais de um acesso de cada um dos outros.

O mestre I é opcional. Sem conexão ele nunca pede. Os mestres A e I podem pedir uma linha de quatro palavras, e o mestre B move uma palavra por vez. O contexto da porta de depuração está em [sdram_debug.md](sdram_debug.md).

## 2. Interface

O bloco tem uma porta de entrada de clock e uma de reset, três portas de mestre e uma porta de controlador. Todos os grupos de mestre repetem o mesmo conjunto de sinais com prefixos diferentes.

### 2.1. Clock e reset

| Porta | Dir. | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_clk` | entrada | 1 | clock do árbitro e do controlador |
| `i_rst` | entrada | 1 | reset síncrono, ativo em `'1'` |

O generic `addr_bits` (natural, padrão 24) é a largura do endereço de palavra de 32 bits do chip, 25 com o chip de 32 bits da DE2-115.

### 2.2. Sinais de cada mestre e do controlador

Para o árbitro, a direção dos sinais de um mestre é a da coluna "Mestre". No lado do controlador as direções se invertem, porque o árbitro é quem pede.

| Função | Mestre A | Mestre I | Mestre B | Controlador | Largura | Dir. do mestre |
| :--- | :--- | :--- | :--- | :--- | ---: | :--- |
| toggle de pedido | `i_a_req_tog` | `i_ins_req_tog` | `i_b_req_tog` | `o_c_req_tog` | 1 | entrada |
| toggle de confirmação | `o_a_ack_tog` | `o_ins_ack_tog` | `o_b_ack_tog` | `i_c_ack_tog` | 1 | saída |
| escrita ou leitura | `i_a_we` | `i_ins_we` | `i_b_we` | `o_c_we` | 1 | entrada |
| endereço de palavra | `i_a_addr` | `i_ins_addr` | `i_b_addr` | `o_c_addr` | `addr_bits` (24) | entrada |
| dado de escrita | `i_a_wdata` | `i_ins_wdata` | `i_b_wdata` | `o_c_wdata` | 32 | entrada |
| habilita de bytes | `i_a_be` | `i_ins_be` | `i_b_be` | `o_c_be` | 4 | entrada |
| dado lido | `o_a_rdata` | `o_ins_rdata` | `o_b_rdata` | `i_c_rdata` | 32 | saída |
| acesso de linha | `i_a_line` | `i_ins_line` | sem porta | `o_c_line` | 1 | entrada |
| palavras 1 a 3 de escrita | `i_a_wdata_x` | `i_ins_wdata_x` | sem porta | `o_c_wdata_x` | 96 | entrada |
| habilita de bytes das palavras 1 a 3 | `i_a_be_x` | `i_ins_be_x` | sem porta | `o_c_be_x` | 12 | entrada |
| palavras 1 a 3 lidas | `o_a_rdata_x` | `o_ins_rdata_x` | sem porta | `i_c_rdata_x` | 96 | saída |

Os sinais do mestre A de linha (`i_a_line`, `i_a_wdata_x`, `i_a_be_x`) e todos os de entrada do mestre I têm valor padrão zero, o que deixa o mestre I sem conexão sem nunca gerar pedido.

## 3. Comportamento

### 3.1. Protocolo de pedido

Um pedido é a inversão do toggle de pedido do mestre, com a palavra nos barramentos. A confirmação é a inversão do toggle de confirmação do mesmo mestre, e o mestre mantém os barramentos estáveis da inversão do pedido até a confirmação. Um pedido está pendente enquanto o toggle de pedido, já sincronizado, difere do toggle de confirmação.

Os toggles dos mestres A e I vêm do clock do núcleo e passam, cada um, por uma instância do `synchronizer` de dois estágios dentro do árbitro. O toggle do mestre B está no clock do árbitro e é lido direto. Os barramentos de dados não são sincronizados. O árbitro os lê só depois de ver a inversão, quando já estão estáveis.

### 3.2. Estados

| Estado | Condição de saída |
| :--- | :--- |
| `ST_IDLE` | existe um mestre com pedido pendente, que o árbitro escolhe, copia o pedido para as saídas do controlador, inverte `o_c_req_tog` e vai para `ST_BUSY` |
| `ST_BUSY` | `i_c_ack_tog` igual a `o_c_req_tog`, o que devolve o dado lido e a confirmação ao mestre atendido e volta para `ST_IDLE` |

Ao escolher, o árbitro guarda o valor sincronizado do toggle de pedido de A ou de I, e usa esse valor como confirmação. Para o mestre B a confirmação copia o toggle de pedido atual, que não muda durante o acesso. O dado lido e, para A e I, as palavras 1 a 3 lidas, são registrados no mesmo clock da confirmação e só mudam nessa resposta. O mestre B nunca pede linha, então o árbitro entrega ao controlador `o_c_line` em `'0'` e as palavras extras zeradas.

### 3.3. Ordem de atendimento

O mestre atendido por último vai para o fim da ordem circular A, I, B. A escolha percorre a ordem a partir do mestre seguinte ao último atendido e pega o primeiro com pedido pendente.

| Último atendido | Prioridade na escolha |
| :--- | :--- |
| A, ou nenhum depois do reset | I, B, A |
| I | B, A, I |
| B | A, I, B |

### 3.4. Latência

Seja $e$ a primeira borda do árbitro que amostra o toggle novo de um mestre, sem outro pedido em andamento.

| Mestre | Borda em que `o_c_req_tog` inverte | Motivo |
| :--- | :--- | :--- |
| B | $e$ | o toggle é lido direto |
| A ou I | $e+2$ | dois estágios do sincronizador |

O árbitro confirma ao mestre na borda em que vê a resposta do controlador, e só pode escolher de novo na borda seguinte.

Cada pedido ocupa o controlador pelo tempo do seu acesso mais uma borda de troca. As latências do acesso estão em [sdram_ctrl](sdram_ctrl.md). A prova formal de [formal.md](../formal/formal.md) limita a espera de qualquer mestre a 20 clocks, com um controlador que responde em até 4 clocks.

## 4. Integração

No topo de simulação do subsistema o árbitro liga os blocos abaixo, todos no clock do controlador, exceto as pontes.

| Porta do árbitro | Bloco ligado |
| :--- | :--- |
| mestre A | [sdram_cpu_bridge](sdram_cpu_bridge.md) de dados, no clock do núcleo |
| mestre I | [sdram_cpu_bridge](sdram_cpu_bridge.md) de instruções, no clock do núcleo; no topo ela só lê, com os dados de escrita e as habilitações zerados |
| mestre B | mestre de depuração, no clock do controlador, comandado por JTAG |
| controlador | [sdram_ctrl](sdram_ctrl.md), com `sync_req` falso, porque o toggle de pedido nasce no mesmo clock |

## 5. Verificação

| Verificação | Onde | O que cobre |
| :--- | :--- | :--- |
| prova formal | [props.sv](../../../formal/sdram_arbiter/props.sv), executada por [run.sh](../../../formal/run.sh) | um pedido por vez ao controlador com barramentos estáveis, cada concessão com a palavra de um mestre que esperava, cada resposta uma vez e com o toggle do seu pedido, dado lido igual ao do controlador, espera limitada a 20 clocks, cobertura das situações e mutantes que a prova precisa reprovar |
| simulação, mestre A | `SdramSystem` e `SdramDebugPort`, em [sdram_system.py](../../../tests/python/unittests/ram/sdram_system.py) | acessos de palavra e de linha do núcleo atravessando o árbitro |
| simulação, mestre B | `SdramDebugPort`, em [sdram_debug_port.py](../../../tests/python/unittests/ram/sdram_debug_port.py) | leitura, escrita, preenchimento e tráfego simultâneo do núcleo e do hospedeiro, incluindo o limite de espera do núcleo durante um preenchimento longo |
| simulação, subsistema atrás da cache e do AXI | `DataCache`, `DataCacheWriteThrough` e `AxiSdramSlave` | o mesmo subsistema, dirigido no lado do núcleo pela cache de dados e pelo escravo AXI |

As propriedades formais tratam as palavras 0 (`we`, endereço, dado, habilita e dado lido). Os barramentos extras de linha são entradas livres sem propriedade própria. Os testes de simulação do subsistema não dirigem o mestre I, e ele é coberto pela prova formal.

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
