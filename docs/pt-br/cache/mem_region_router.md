# mem_region_router

## 1. Função do componente no SoC

O roteador de região recebe o pedido de um mestre (o lado da memória de uma cache) e o encaminha à SDRAM ou à FLASH conforme o endereço esteja ou não na região da FLASH. Devolve ao mestre o `ready` e o dado da região escolhida. A escolha é combinacional sobre o endereço, que o mestre mantém estável durante o pedido.

Dois tipos de pedido à FLASH nunca chegam ao chip e são concluídos no próprio roteador.

| Pedido à FLASH | Resposta do roteador |
| :--- | :--- |
| Escrita | Concluída sem efeito, como num chip protegido contra escrita |
| Leitura de endereço além da janela que o chip atende | Concluída com zeros nas quatro palavras |

## 2. Interface

### 2.1. Generics

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | :--- | :--- |
| `flash_base_kib` | natural | 524288 | Base da região da FLASH em KiB (0x20000000) |
| `flash_end_kib` | natural | 1048576 | Fim exclusivo da região da FLASH em KiB (0x40000000) |
| `flash_window_kib` | natural | 1024 | Tamanho em KiB da janela que o chip atende a partir da base; a leitura além dela devolve zero |
| `hold_rdata` | boolean | false | O dado lido segue a região do último pedido concluído, e não o endereço atual (mestre sem cache de dados, ver a seção 3.4) |

### 2.2. Portas do mestre

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_clk` | entrada | 1 | Clock do módulo |
| `i_rst` | entrada | 1 | Reset, ativo em 1 |
| `i_addr` | entrada | 32 | Endereço do pedido |
| `i_wdata` | entrada | 32 | Dado de escrita (palavra 0) |
| `i_byteena` | entrada | 4 | Habilita de bytes da escrita |
| `i_rden` | entrada | 1 | Pedido de leitura |
| `i_wren` | entrada | 1 | Pedido de escrita |
| `i_line` | entrada | 1 | Pedido de linha de quatro palavras |
| `i_wdata_x` | entrada | 96 | Palavras 1 a 3 do dado de escrita da linha (padrão zeros) |
| `i_advance` | entrada | 1 | O pedido foi consumido neste ciclo |
| `o_ready` | saída | 1 | Pedido concluído |
| `o_rdata` | saída | 32 | Palavra lida (palavra 0 da linha) |
| `o_rdata_x` | saída | 96 | Palavras 1 a 3 da linha lida |

### 2.3. Portas da SDRAM

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `o_s_addr` | saída | 32 | Endereço do pedido (igual a `i_addr`) |
| `o_s_wdata` | saída | 32 | Dado de escrita |
| `o_s_byteena` | saída | 4 | Habilita de bytes da escrita |
| `o_s_rden` | saída | 1 | Leitura, em 1 só para endereços fora da região da FLASH |
| `o_s_wren` | saída | 1 | Escrita, em 1 só para endereços fora da região da FLASH |
| `o_s_line` | saída | 1 | Pedido de linha (igual a `i_line`) |
| `o_s_wdata_x` | saída | 96 | Palavras 1 a 3 do dado de escrita da linha |
| `o_s_advance` | saída | 1 | `i_advance` apenas para endereços fora da região da FLASH |
| `i_s_ready` | entrada | 1 | Pedido concluído |
| `i_s_rdata` | entrada | 32 | Palavra lida |
| `i_s_rdata_x` | entrada | 96 | Palavras 1 a 3 da linha lida (padrão zeros) |

### 2.4. Portas da FLASH

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `o_f_addr` | saída | 32 | Endereço do pedido (igual a `i_addr`) |
| `o_f_rden` | saída | 1 | Leitura, em 1 só para leituras da FLASH dentro da janela |
| `o_f_line` | saída | 1 | Pedido de linha (igual a `i_line`) |
| `o_f_advance` | saída | 1 | `i_advance` apenas para pedidos da FLASH que chegam ao chip |
| `i_f_ready` | entrada | 1 | Pedido concluído |
| `i_f_rdata` | entrada | 32 | Palavra lida |
| `i_f_rdata_x` | entrada | 96 | Palavras 1 a 3 da linha lida (padrão zeros) |

A porta da FLASH não tem escrita nem dado de escrita, porque nenhum pedido de escrita chega ao chip.

## 3. Comportamento

### 3.1. Seleção do destino

Com $A$ o endereço e $B$, $E$ e $W$ os generics em KiB, as condições são as seguintes.

$$
\text{flash} = (A \ge 1024\,B) \wedge (A < 1024\,E)
$$

$$
\text{além} = A \ge 1024\,(B + W)
$$

$$
\text{local} = \text{flash} \wedge (\texttt{i\_wren} \vee (\texttt{i\_rden} \wedge \text{além}))
$$

| Condição | Destino do pedido | `o_ready` | `o_rdata` e `o_rdata_x` |
| :--- | :--- | :--- | :--- |
| `local` | Nenhum, concluído no roteador | Registrador de pedido local | Zeros |
| `flash` e não `local` | FLASH | `i_f_ready` | Dados da FLASH |
| não `flash` | SDRAM | `i_s_ready` | Dados da SDRAM |

Os endereços do pedido e os dados de escrita seguem para as duas saídas sem condição, mas só a saída escolhida recebe o pedido de leitura, o de escrita e o `i_advance`.

### 3.2. Pedido local

Quando `local` vale e o registrador de pedido local está em 0, ele vai a 1 na borda seguinte, de modo que `o_ready` sobe um ciclo depois do pedido. Permanece em 1 até `i_advance` e então cai. O mestre baixa o pedido na borda em que vê `o_ready`, como as caches fazem. O reset zera o registrador.

### 3.3. Contrato do mestre

O pedido fica no barramento até `o_ready`, que é um nível e só cai com `i_advance`. O dado lido só muda no pedido seguinte. Para as saídas que não passam pelo registrador (SDRAM e FLASH), o roteador não adiciona ciclos, porque `o_ready`, `o_rdata` e `o_rdata_x` são combinacionais sobre as respostas dos escravos.

Para uma cache somente de leitura, `i_wren` fica em 0 e o caso do store não ocorre.

### 3.4. Dado lido guardado (`hold_rdata`)

Uma cache guarda o dado ao terminar o pedido, então a escolha combinacional do dado pelo endereço basta. Um mestre que não guarda o dado, como o núcleo ligado direto ao roteador, muda o endereço assim que o pedido termina, e o estágio de write-back ainda lê o dado lido um terço de ciclo depois. Com `hold_rdata` em `true`, `o_rdata` e `o_rdata_x` seguem a região do último pedido concluído, que um registrador guarda na borda em que o chip troca o dado lido.

$$
\text{conclui} = (\texttt{i\_rden} \vee \texttt{i\_wren}) \wedge \texttt{i\_advance} \wedge \texttt{o\_ready}
$$

Na borda em que `conclui` vale, os registradores `flash` e `local` recebem as condições da seção 3.1; fora dela, mantêm o valor. O reset os zera, e o dado lido volta a ser o da SDRAM. Com `hold_rdata` em `false` nenhum registrador existe e o comportamento é o da seção 3.1.

## 4. Integração

| Instância | Arquivo | Conexão |
| :--- | :--- | :--- |
| `u_router_i` | `src/cache/SoC/sim/flash_path_system.vhd` | Mestre ligado ao lado da memória da [icache](icache.md), com `i_wren` em 0; saída da FLASH ligada ao mestre A do [flash_arbiter](flash_arbiter.md); saída da SDRAM sem escravo |
| `u_router_b` | `src/cache/SoC/sim/flash_path_system.vhd` | Mestre ligado à porta B do sistema, que representa o lado da memória de uma cache de dados; saída da FLASH ligada ao mestre B do árbitro; saída da SDRAM sem escravo |

O lado da memória da [dcache](dcache.md) usa a mesma convenção de pedido e resposta. Um store à FLASH repassado pela dcache é o caso em que o roteador o conclui sem efeito. Nenhuma instância no repositório liga a dcache a este roteador. O topo modular do Insper-RISC-V liga o núcleo ao roteador dos dados com `hold_rdata` em `true` quando não há cache de dados.

## 5. Verificação

Os testes são cocotb em `tests/python/unittests/cache`, registrados em `tests/python/tests.json`. Não há provas formais do roteador.

| Entrada de `tests.json` | Módulo de teste | O que cobre |
| :--- | :--- | :--- |
| `MemRegionRouter` | [mem_region_router.py](../../../tests/python/unittests/cache/mem_region_router.py) | Leitura de linha à SDRAM e à FLASH, store à FLASH absorvido, leitura fora da janela devolve zero, store à SDRAM repassado, sequência mista |
| `MemRegionRouterLow` | [mem_region_router_low.py](../../../tests/python/unittests/cache/mem_region_router_low.py) | Generics `flash_base_kib` igual a 2, `flash_end_kib` igual a 32 e `flash_window_kib` igual a 30; leitura dentro da região chega à ROM, bordas da região, store à ROM absorvido e à SDRAM repassado |
| `MemRegionRouterHold` | [mem_region_router_hold.py](../../../tests/python/unittests/cache/mem_region_router_hold.py) | Generic `hold_rdata` em `true`; o dado da FLASH e o da SDRAM continuam depois que o endereço muda, e um store absorvido deixa zero |
| `FlashPath` | [flash_path.py](../../../tests/python/unittests/cache/flash_path.py) | Dois roteadores, a icache, o árbitro e o chip juntos; store à FLASH nunca chega ao chip, leitura além da janela devolve zero sem tocar o chip, pedidos à SDRAM não tocam o caminho da FLASH |

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
