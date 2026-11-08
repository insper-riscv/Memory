# onchip_ram_port

## 1. Função do componente no SoC

O adaptador da RAM interna põe o bloco de RAM da FPGA atrás do contrato de linha do lado da memória, o mesmo do [ram_chip](ram_chip.md). Com ele, uma RAM interna pode ficar atrás da cache de dados e do roteador de região, com a espera e o protocolo de linha de uma memória externa, e o requisitante não distingue um do outro. O adaptador não tem armazenamento próprio e é sintetizável: tem uma máquina de estados e os registradores do acesso, e o armazenamento é o bloco de RAM ligado às portas `o_mem_*` e `i_mem_q`, que pode ser o IP [ram](ram.md) na placa ou o modelo [ram_simulation](ram_simulation.md) na simulação.

O bloco de RAM tem uma única porta de palavra com leitura registrada. O adaptador move uma linha de quatro palavras como quatro acessos seguidos a essa porta, um por borda, e usa a mesma porta para a depuração nos ciclos em que nenhum acesso a ocupa.

## 2. Interface

### 2.1. Generics

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | ---: | :--- |
| `size_bytes` | positive | 1048576 | tamanho da janela da RAM em bytes, uma potência de dois de 16 bytes a 32 MB |
| `base_kib` | natural | 0 | onde a RAM começa dentro dos 64 MB da região, em KiB; o endereço da RAM é o da região menos esta base |
| `latency` | natural | 0 | latência emulada em bordas, a mesma do `ram_chip`; zero deixa só a latência estrutural da seção 3.3 |

Com $S$ igual a `size_bytes`, o índice de palavra do bloco de RAM tem $\log_2 S - 2$ bits, a mesma largura da porta `i_address` do IP `ram`.

### 2.2. Portas do requisitante

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_clk` | entrada | 1 | clock do módulo e do bloco de RAM |
| `i_rst` | entrada | 1 | reset síncrono, ativo em `'1'` |
| `i_addr` | entrada | 32 | endereço de byte do acesso |
| `i_wdata` | entrada | 32 | dado de escrita (palavra 0 da linha) |
| `i_byteena` | entrada | 4 | habilita de bytes da escrita (palavra 0) |
| `i_rden` | entrada | 1 | pedido de leitura |
| `i_wren` | entrada | 1 | pedido de escrita, que prevalece sobre a leitura se os dois vierem juntos |
| `i_mem_advance` | entrada | 1 | o pipeline avançou neste ciclo, o acesso concluído pode terminar |
| `o_ready` | saída | 1 | acesso concluído, o dado lido é válido |
| `o_rdata` | saída | 32 | dado lido (palavra 0 da linha) |
| `i_line` | entrada | 1 | acesso de linha, quatro palavras seguidas (padrão `'0'`) |
| `i_wdata_x` | entrada | 96 | palavras 1 a 3 do dado de escrita da linha, a palavra 1 nos bits mais baixos |
| `i_byteena_x` | entrada | 12 | habilita de bytes das palavras 1 a 3, quatro bits por palavra |
| `o_rdata_x` | saída | 96 | palavras 1 a 3 do dado lido da linha |

### 2.3. Portas do bloco de RAM

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `o_mem_addr` | saída | $\log_2 S - 2$ | índice da palavra |
| `o_mem_wdata` | saída | 32 | dado de escrita |
| `o_mem_byteena` | saída | 4 | habilita de bytes da escrita |
| `o_mem_rden` | saída | 1 | habilita de leitura |
| `o_mem_wren` | saída | 1 | habilita de escrita |
| `i_mem_q` | entrada | 32 | palavra lida, válida um ciclo depois do endereço |

### 2.4. Porta de depuração

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_dbg_word_addr` | entrada | 24 | índice da palavra lida, contado do início da janela e sem deslocamento por `base_kib` |
| `o_dbg_word_data` | saída | 32 | palavra da RAM nesse índice |

## 3. Comportamento

### 3.1. Contrato do acesso

O acesso fica em `i_addr`, `i_rden` ou `i_wren` e `i_line` enquanto o estágio que o pede está parado. `o_ready` sobe quando o acesso termina e permanece em nível alto até `i_mem_advance` valer `'1'`. O dado lido (`o_rdata`, `o_rdata_x`) só muda nessa borda, porque o load que ainda está no estágio de write-back lê o valor anterior até lá. A porta volta a aceitar pedidos na borda seguinte à do avanço.

O endereço de um acesso de palavra é alinhado em 4 bytes, e o de um acesso de linha em 16 bytes. Uma linha move as quatro palavras seguintes ao endereço alinhado, e a escrita atualiza só os bytes habilitados de cada palavra.

### 3.2. Janela de endereços

O adaptador usa os 26 bits baixos do endereço de byte. Com $B$ igual a $1024 \cdot$ `base_kib` e $S$ igual a `size_bytes`, o índice de palavra é

$$\text{índice} = \frac{a_{25..0} - B}{4}, \qquad B \le a_{25..0} < B + S$$

Fora desse intervalo a leitura devolve zero e a escrita é descartada, sem erro, e o acesso leva o mesmo tempo de um acesso dentro da janela.

### 3.3. Máquina de estados e latência

| Estado | Ação | Próximo estado |
| :--- | :--- | :--- |
| `S_IDLE` | com `i_rden` ou `i_wren`, captura endereço, dados e máscaras e zera o passo | `S_ACCESS` |
| `S_ACCESS` | o passo $k$ emite a palavra $k$ ao bloco, e o passo $k+1$ recolhe a palavra lida; ao fim do passo seguinte à última palavra, encerra | `S_DONE`, ou `S_HOLD` se a latência emulada ainda não acabou |
| `S_HOLD` | espera o resto da latência emulada, sem tocar no bloco | `S_DONE` |
| `S_DONE` | `o_ready` em `'1'`; com `i_mem_advance`, copia o dado recolhido para a saída de leitura | `S_IDLE` |

A latência é baixa e constante. Seja $E_0$ a borda em que o pedido é visto. O acesso de palavra termina na borda $E_2$ e o de linha na borda $E_5$, e `o_ready` sobe logo depois. Leitura e escrita levam o mesmo tempo, em qualquer endereço e também fora da janela.

| Acesso | Bordas até `o_ready` |
| :--- | ---: |
| Palavra | 2 |
| Linha | 5 |

Com `latency` maior que zero o adaptador conta as mesmas bordas do `ram_chip`, com a mesma máquina [latency_counter](../latency/latency_counter.md), e o acesso termina na maior entre essa contagem e a estrutural da tabela. Com $L$ igual a `latency` e $L \geq 5$, palavra e linha terminam na borda $E_L$, igual ao `ram_chip` de mesma latência, e o programa leva o mesmo tempo na simulação e na placa. Com $L < 5$ vale o mínimo do bloco, porque quatro leituras de uma porta de palavra não cabem em menos de 5 bordas.

### 3.4. Porta de depuração

A depuração lê o bloco pela mesma porta, nos ciclos em que o adaptador está livre (sem pedido) ou com o acesso concluído esperando o avanço. Um índice novo aparece em `o_dbg_word_data` 2 bordas depois da troca quando a porta está livre, e a saída mantém o último valor lido enquanto não está. A leitura de depuração nunca atrasa nem altera um acesso em curso. Um índice fora da janela lê zero. O testbench usa essa porta para ler o `tohost` sem passar pelas caches.

## 4. Integração

| Item | Descrição |
| :--- | :--- |
| Acima dele | a cache de dados ([dcache](../cache/dcache.md)) e, quando há ROM também atrás de cache, o roteador [mem_region_router](../cache/mem_region_router.md); as portas de linha carregam as linhas da cache |
| Abaixo dele | o IP [ram](ram.md) na placa, ou o [ram_simulation](ram_simulation.md) na simulação, ligados pelas portas `o_mem_*` e `i_mem_q` |
| Lista de portas do requisitante | a porta de dados do [ram_chip](ram_chip.md), o que deixa o topo trocar um pelo outro |
| Contagem da latência | o [latency_counter](../latency/latency_counter.md), que é também o do `ram_chip` e o do [flash_chip](../rom/flash_chip.md) |
| Porta de instruções | o adaptador tem uma só porta de acesso, porque o bloco de RAM tem uma só porta |

## 5. Verificação

O topo de simulação `onchip_ram_system` liga o adaptador ao `ram_simulation`, com a `dcache` na frente ou não. Com o genérico `use_chip`, o `ram_chip` ocupa o lugar do adaptador e do modelo, e o mesmo teste roda nos dois, de modo que o `ram_chip` serve de referência do contrato.

| Entrada de `tests/python/tests.json` | Módulo de teste | Parâmetros |
| :--- | :--- | :--- |
| `OnchipRamPort` | `onchip_ram_port` | `SIZE_BYTES` igual a 4096 |
| `OnchipRamPortChip` | `onchip_ram_port` | `SIZE_BYTES` igual a 4096 e `USE_CHIP` verdadeiro |
| `OnchipRamLatency` | `onchip_ram_latency` | `SIZE_BYTES` igual a 4096 |
| `OnchipRamOffset` | `onchip_ram_offset` | `SIZE_BYTES` igual a 4096 e `BASE_KIB` igual a 8 |
| `OnchipRamEmulated` | `onchip_ram_emulated_latency` | `SIZE_BYTES` igual a 4096 e `LATENCY` igual a 9 |
| `OnchipRamEmulatedChip` | `onchip_ram_emulated_latency` | os mesmos e `USE_CHIP` verdadeiro |
| `OnchipRamEmulatedShort` | `onchip_ram_emulated_short` | `SIZE_BYTES` igual a 4096 e `LATENCY` igual a 3 |
| `OnchipRamDcache` | `onchip_ram_dcache` | `WITH_CACHE` verdadeiro |
| `OnchipRamDcacheWriteThrough` | `onchip_ram_dcache` | `WITH_CACHE` e `WRITE_THROUGH` verdadeiros |
| `OnchipRamDcacheChip` | `onchip_ram_dcache` | `WITH_CACHE` e `USE_CHIP` verdadeiros |

| Teste | Verifica |
| :--- | :--- |
| `test_a_word_is_written_and_read_back` | uma palavra escrita volta e a porta de depuração a vê |
| `test_byte_enables_keep_the_other_bytes` | as 16 máscaras mudam só os bytes habilitados |
| `test_a_line_is_written_and_read_back` | a escrita e a leitura de linha movem quatro palavras a partir da fronteira de 16 bytes |
| `test_a_line_write_keeps_the_masked_bytes` | o habilita de bytes das palavras 1 a 3 vale na escrita de linha |
| `test_the_read_data_changes_on_advance` | `o_ready` espera o avanço e o dado antigo é mantido até lá |
| `test_outside_the_window_reads_zero_and_drops_stores` | fora da janela a leitura é zero, a escrita some e não há dobra de endereços |
| `test_the_debug_port_ends_with_the_window` | a porta de depuração lê zero além da última palavra |
| `test_the_latency_of_a_word_is_constant` e `test_the_latency_of_a_line_is_constant` | 3 e 6 bordas contando a borda $E_0$, iguais para leitura e escrita |
| `test_the_outside_of_the_window_takes_the_same_time` | o acesso fora da janela não é mais rápido |
| `onchip_ram_emulated_latency` | com `LATENCY` igual a 9, palavra e linha, leitura e escrita, dentro e fora da janela, levam 10 bordas contando a $E_0$, no adaptador e no `ram_chip` com o mesmo módulo de teste |
| `onchip_ram_emulated_short` | com `LATENCY` igual a 3, a palavra leva 4 bordas e a linha 6, o mínimo do bloco |
| `test_the_debug_port_reads_while_ready_waits` | a depuração lê com `o_ready` em espera e não o derruba |
| `test_the_debug_port_does_not_disturb_an_access` | variar o índice de depuração a cada clock não altera os acessos |
| `test_the_ram_starts_at_the_base` e `test_outside_the_ram_is_zero` | com `base_kib` igual a 8, a primeira palavra é a da base e os vizinhos fora da janela leem zero |
| `test_write_then_read`, `test_byte_enables`, `test_eviction_writes_back` e `test_random_traffic` | a `dcache` sobre o adaptador, com tráfego aleatório comparado com uma cópia em Python da memória, também depois do flush |

Não há prova formal deste bloco.

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
