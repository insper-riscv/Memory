# ram_chip

## 1. Função do componente no SoC

O modelo de chip de RAM externa faz, nas plataformas simuladas, o papel da SDRAM da placa, sem o controlador nem o modelo do chip. Ele é um vetor de palavras de 32 bits com duas portas de acesso, uma de dados e outra de instruções, mais uma porta de depuração por palavra. Usa o mesmo contrato de requisição e conclusão da ponte da SDRAM, de modo que as caches e o roteador que ficam entre o core e a memória externa não distinguem este modelo da SDRAM real. O modelo não é sintetizável para a placa, pois usa leitura de arquivo e uma variável protegida.

## 2. Interface

### 2.1. Generics

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | ---: | :--- |
| `init_file` | string | vazio | arquivo com a imagem inicial, uma palavra de 32 bits por linha em hexadecimal, a partir do primeiro endereço da janela; vazio deixa tudo em zero |
| `latency` | natural | 8 | bordas de `i_clk` entre o pedido e a conclusão do acesso, mínimo 2 |
| `size_bytes` | positive | 1048576 | tamanho da janela do chip em bytes, uma potência de dois de 16 bytes a 32 MB |
| `base_kib` | natural | 0 | onde o chip começa dentro dos 64 MB da região, em KiB; o endereço do chip é o da região menos esta base |

### 2.2. Portas da porta de dados

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_clk` | entrada | 1 | clock do módulo |
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

### 2.3. Portas da porta de instruções

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_ins_addr` | entrada | 32 | endereço de byte do acesso |
| `i_ins_rden` | entrada | 1 | pedido de leitura |
| `i_ins_advance` | entrada | 1 | o pipeline avançou neste ciclo |
| `o_ins_ready` | saída | 1 | acesso concluído, o dado lido é válido |
| `o_ins_rdata` | saída | 32 | dado lido (palavra 0 da linha) |
| `i_ins_line` | entrada | 1 | acesso de linha (padrão `'0'`) |
| `o_ins_rdata_x` | saída | 96 | palavras 1 a 3 do dado lido da linha |

A porta de instruções só lê. Os valores padrão das entradas da porta de instruções e de `i_line`, `i_wdata_x` e `i_byteena_x` deixam as portas não ligadas inativas.

### 2.4. Portas de estado e depuração

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `o_init_done` | saída | 1 | o chip aceita pedidos, em `'1'` desde a borda seguinte ao fim do reset |
| `i_dbg_word_addr` | entrada | 24 | índice da palavra lida pela porta de depuração, contado do início da janela |
| `o_dbg_word_data` | saída | 32 | palavra do chip nesse índice, atualizada a cada borda e a cada troca de índice |

## 3. Comportamento

### 3.1. Janela de endereços

O chip usa os 26 bits baixos do endereço de byte, e os bits altos são ignorados. Com $B$ igual a `base_kib` em bytes ($1024 \cdot$ `base_kib`) e $S$ igual a `size_bytes`, o índice de palavra é

$$\text{índice} = \frac{a_{25..0} - B}{4}, \qquad B \le a_{25..0} < B + S$$

Um endereço fora desse intervalo está fora da janela: a leitura devolve zero e a escrita é descartada, sem erro. Num acesso de linha, as palavras de índice acima da última não são escritas e são lidas como zero.

### 3.2. Acesso de palavra e de linha

O endereço de um acesso de palavra é alinhado em 4 bytes, e o de um acesso de linha em 16 bytes. Uma linha move as quatro palavras seguintes ao endereço alinhado, a palavra 0 em `i_wdata`, `i_byteena` e `o_rdata`, e as palavras 1 a 3 nos vetores `_x`. A escrita atualiza só os bytes habilitados de cada palavra.

### 3.3. Máquina de estados de uma porta

As duas portas têm máquinas independentes de três estados sobre o mesmo vetor. Um pedido só é aceito com `o_init_done` em `'1'`.

| Estado | Ação | Próximo estado |
| :--- | :--- | :--- |
| `S_IDLE` | com `i_rden` ou `i_wren` (porta de dados) ou `i_ins_rden` (porta de instruções), captura endereço, dados e máscaras e carrega o [latency_counter](../latency/latency_counter.md) da porta com `latency` | `S_WAIT` |
| `S_WAIT` | espera até o `latency_counter` sinalizar a última borda; nessa borda faz o acesso ao vetor (escrita, ou leitura para um registrador pendente) | `S_DONE` |
| `S_DONE` | `o_ready` em `'1'`; quando `i_mem_advance` (ou `i_ins_advance`) vale `'1'`, copia o dado pendente para a saída de leitura | `S_IDLE` |

### 3.4. Latência

Seja $E_0$ a borda em que o pedido é aceito. O acesso ao vetor acontece na borda $E_L$, com $L$ igual a `latency`, e `o_ready` sobe logo depois dela, de modo que passam $L$ bordas entre o pedido e a conclusão. A escrita e a leitura ocorrem no fim da latência, então um store da porta de dados é visto por uma leitura da porta de instruções que seja pedida depois da conclusão dele.

`o_ready` permanece em nível alto até a borda em que `i_mem_advance` vale `'1'`, e o dado lido (`o_rdata`, `o_rdata_x`) só muda nessa mesma borda. A razão é que o load que ainda está no estágio de write-back lê o valor anterior até lá. O primeiro `i_mem_advance` aproveitado é o da borda $E_{L+1}$ ou de uma posterior, e a porta volta a aceitar pedidos na borda seguinte à do avanço.

### 3.5. Carga inicial e porta de depuração

No instante zero, um processo lê `init_file` linha a linha e grava cada palavra válida em sequência a partir do índice 0, o mesmo formato do arquivo de imagem da SDRAM simulada. Linhas que não são hexadecimais são puladas. A porta de depuração lê o vetor sem passar pelas portas de acesso, e o índice dela não é deslocado por `base_kib`.

## 4. Integração

| Item | Descrição |
| :--- | :--- |
| Instanciado em | `src/simulation/modular/modular_sim_top.vhd` do repositório Insper-RISC-V, quando `ram_external` é verdadeiro, com `init_file` igual a `ram_file`, `latency` igual a `ext_ram_latency`, `size_bytes` igual a `ram_size_bytes` e `base_kib` igual ao módulo 65536 de `ram_base_kib` |
| Acima dele | a cache de dados (`src/cache/SoC/dcache.vhd`), a cache de instruções (`src/cache/SoC/icache.vhd`) e, quando a ROM também é externa, o roteador `mem_region_router`; as portas de linha carregam as linhas das caches |
| Contagem da latência | uma instância de [latency_counter](../latency/latency_counter.md) por porta, a mesma máquina do [onchip_ram_port](onchip_ram_port.md) e do [flash_chip](../rom/flash_chip.md) |
| Contrato | o mesmo da ponte da SDRAM (`sdram_cpu_bridge`) e da porta externa do core, descrito em [ext_interconnect.md](https://github.com/insper-riscv/Insper-RISC-V/blob/main/docs/pt-br/interconnect/ext_interconnect.md) |
| Lista de portas | a mesma de `sdram_system`, o que deixa o topo trocar um pelo outro |
| Porta de depuração | no topo modular, o testbench lê por ela o `tohost` do HTIF quando ele está no chip, sem passar pelas caches |

O topo modular alimenta `ram_base_kib` e `ram_size_bytes` a partir do mapa de memória da plataforma. No mapa do core, a RAM interna ocupa de `0x00008000` a `0x3FFFFFFF` por padrão e a janela externa começa em `0x40000000`, e o mapa completo está no contrato de barramento e memória do repositório Core. O formato do acesso de linha, com a palavra 1 nos bits mais baixos dos vetores `_x`, é o da SDRAM real, descrito em [sdram_line.md](sdram_line.md), e o caminho de cache e barramento que leva a SDRAM está em [dcache_axi.md](../barramento/dcache_axi.md).

## 5. Verificação

Os testes de `tests/python/unittests/ram/ram_chip.py` rodam em três configurações de `tests/python/tests.json`.

| Entrada | Módulo de teste | Parâmetros |
| :--- | :--- | :--- |
| `RamChip` | `ram_chip` | padrão (1 MB, latência 8) |
| `RamChipSmall` | `ram_chip_small` | `SIZE_BYTES` igual a 4096 |
| `RamChipOffset` | `ram_chip_offset` | `SIZE_BYTES` igual a 4096 e `BASE_KIB` igual a 8 |

| Teste | Verifica |
| :--- | :--- |
| `test_a_word_is_written_and_read_back` | uma palavra escrita volta e cada acesso leva ao menos `latency` bordas, e a porta de depuração a vê |
| `test_byte_enables_keep_the_other_bytes` | só os bytes habilitados mudam |
| `test_a_line_is_written_and_read_back` | a escrita e a leitura de linha movem quatro palavras a partir da fronteira de 16 bytes |
| `test_the_read_data_changes_on_advance` | `o_ready` espera o avanço e o dado antigo é mantido até lá |
| `test_the_instruction_port_sees_the_stores_of_the_data_port` | a porta de instruções vê os stores, por palavra e por linha |
| `test_outside_the_window_reads_zero_and_drops_stores` | fora da janela a leitura é zero, a escrita some e não há dobra de endereços |

Os módulos `ram_chip_small` e `ram_chip_offset` trazem testes próprios.

| Teste | Verifica |
| :--- | :--- |
| `test_the_window_follows_the_generic` | com 4 KB, a última palavra é mantida, a seguinte lê zero e nada dobra o endereço |
| `test_the_debug_port_ends_with_the_window` | a porta de depuração lê zero além do fim do chip |
| `test_the_chip_starts_at_the_base` | com `base_kib` igual a 8, a primeira palavra do chip é a do endereço de base, e a porta de depuração a vê no índice 0 |
| `test_outside_the_chip_is_zero` | a palavra antes da base e a depois do fim leem zero, e os stores fora não dobram o endereço |

Não há prova formal deste bloco.

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
