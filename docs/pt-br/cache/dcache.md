# dcache

## 1. Função do componente no SoC

A dcache é a cache de dados do core. Fica no caminho de memória dos endereços da SDRAM e da FLASH, entre o estágio de memória do pipeline e uma porta de memória que move uma palavra por vez ou uma linha de quatro palavras. Os periféricos nunca passam por ela. O pipeline fica parado enquanto um acesso está em andamento, de modo que a cache atende um acesso por vez.

| Propriedade | Valor |
| :--- | :--- |
| Organização | Mapeamento direto, linhas de 16 bytes (quatro palavras) |
| Tamanho | Genérico `size_bits` (4 KB por padrão) |
| Política de escrita | Write-back com write-allocate, ou write-through com write-around (genérico `write_through`) |
| Regiões atendidas | SDRAM e FLASH, distinguidas por um bit da tag |
| Leitura das RAMs | Registrada, como nas RAMs de bloco da FPGA |

A visão geral do caminho do core até a SDRAM, as medições de custo e as escolhas de projeto estão em [dcache_axi.md](../barramento/dcache_axi.md) e [dcache_axi_decisions.md](../barramento/dcache_axi_decisions.md). O motivo da política write-through nas plataformas com porta de debug está em [CACHE_HOST_COHERENCE.md](../bugs/CACHE_HOST_COHERENCE.md).

## 2. Interface

### 2.1. Generics

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | :--- | :--- |
| `size_bits` | positive | 32768 | Tamanho da cache em bits, potência de dois de pelo menos 256 (duas linhas). 32768 é 4 KB e 4096 é 4 kbit |
| `base_sdram` | vetor de 6 bits | `010000` | Bits 31 a 26 acrescentados aos endereços da SDRAM no lado da memória (0x40000000) |
| `base_flash` | vetor de 6 bits | `001000` | Bits 31 a 26 acrescentados aos endereços da FLASH no lado da memória (0x20000000) |
| `rom_base_kib` | natural | 524288 | Base da região da ROM em KiB; o que cai nela é tratado como FLASH (0x20000000) |
| `rom_end_kib` | natural | 1048576 | Fim exclusivo da região da ROM em KiB (0x40000000) |
| `write_through` | boolean | falso | Verdadeiro faz todo store ir também à memória e a falha de store não trazer a linha |

### 2.2. Portas do lado do core

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_clk` | entrada | 1 | Clock do módulo |
| `i_rst` | entrada | 1 | Reset, ativo em 1; invalida todas as linhas |
| `i_addr` | entrada | 32 | Endereço do acesso |
| `i_wdata` | entrada | 32 | Dado de escrita |
| `i_byteena` | entrada | 4 | Habilita de bytes da escrita, um bit por byte |
| `i_rden` | entrada | 1 | Pedido de leitura |
| `i_wren` | entrada | 1 | Pedido de escrita |
| `i_mem_advance` | entrada | 1 | O pipeline avançou, o acesso concluído pode ser liberado |
| `o_ready` | saída | 1 | Acesso concluído; permanece em 1 até `i_mem_advance` |
| `o_rdata` | saída | 32 | Dado lido; só muda na borda em que o pipeline avança |
| `i_flush` | entrada | 1 | Pede a escrita de todas as linhas sujas; um pulso basta |
| `i_invalidate` | entrada | 1 | Em 1 no mesmo ciclo de `i_flush`, derruba todas as linhas depois da escrita de volta (padrão 0) |
| `i_bypass` | entrada | 1 | O acesso não passa pela cache (padrão 0) |
| `o_miss` | saída | 1 | Pulso de um ciclo no início de cada preenchimento de linha |
| `i_inval_region` | entrada | 1 | Pulso que derruba as linhas limpas da região de `i_inval_first` a `i_inval_last` (padrão 0) |
| `i_inval_first` | entrada | 32 | Primeiro endereço de byte da região a derrubar (padrão 0) |
| `i_inval_last` | entrada | 32 | Último endereço de byte da região a derrubar, incluído (padrão 0) |
| `o_flush_done` | saída | 1 | Pulso de um ciclo ao fim do flush |
| `o_busy` | saída | 1 | Há flush pendente ou em andamento |

### 2.3. Portas do lado da memória

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `o_d_addr` | saída | 32 | Endereço do pedido, com a base da região nos bits 31 a 26 |
| `o_d_wdata` | saída | 32 | Dado de escrita (palavra 0 numa escrita de linha) |
| `o_d_byteena` | saída | 4 | Habilita de bytes da escrita |
| `o_d_rden` | saída | 1 | Pedido de leitura |
| `o_d_wren` | saída | 1 | Pedido de escrita |
| `o_d_line` | saída | 1 | O pedido é de uma linha de quatro palavras |
| `o_d_wdata_x` | saída | 96 | Palavras 1 a 3 do dado de escrita da linha |
| `o_d_advance` | saída | 1 | Igual a `i_d_ready`; a cache consome a resposta no mesmo ciclo |
| `i_d_ready` | entrada | 1 | Pedido concluído |
| `i_d_rdata` | entrada | 32 | Dado lido (palavra 0 numa leitura de linha) |
| `i_d_rdata_x` | entrada | 96 | Palavras 1 a 3 da linha lida (padrão zeros) |

## 3. Comportamento

### 3.1. Divisão do endereço

Com $I = \log_2(\texttt{size\_bits}) - 7$ bits de índice, a cache tem $2^I$ linhas e o endereço se divide como na tabela.

| Campo | Bits do endereço | Largura |
| :--- | :--- | ---: |
| Palavra na linha | 3 a 2 | 2 |
| Índice | $I+3$ a 4 | $I$ |
| Tag | 25 a $I+4$ | $22-I$ |
| Região | Calculada a partir de `rom_base_kib` e `rom_end_kib`; vira o bit mais significativo da tag | 1 |

$$
\text{TAG\_BITS} = 23 - I
$$

Os bits 31 a 26 não são guardados. Num pedido ao lado da memória, a cache os reconstrói com `base_flash` (região da ROM) ou `base_sdram`. Com o tamanho padrão, $I = 8$ (256 linhas) e a tag tem 15 bits.

A escolha da base num preenchimento lê o bit 14 da tag, e não o bit mais significativo. Os dois coincidem apenas quando $\text{TAG\_BITS} = 15$, isto é, com `size_bits` igual a 32768. A escolha da base na escrita de volta usa o bit mais significativo da tag, para qualquer tamanho.

### 3.2. Contrato do lado do core

O acesso fica em `i_addr`, `i_wdata`, `i_byteena`, `i_rden` e `i_wren` enquanto o estágio de memória está parado. `o_ready` sobe quando o acesso termina e permanece em 1 até `i_mem_advance`. `o_rdata` recebe o dado lido só na borda em que `i_mem_advance` conclui um acesso de leitura.

### 3.3. Máquina de estados

| Grupo | Estados | Função |
| :--- | :--- | :--- |
| Acesso | `S_IDLE`, `S_LOOK`, `S_DONE` | Espera, consulta das RAMs e entrega do resultado |
| Escrita de volta | `S_WB_RD`, `S_WB_CAP`, `S_WB_REQ`, `S_WB_WAIT` | Lê as quatro palavras da linha suja e as escreve na memória num pedido de linha |
| Preenchimento | `S_FILL_REQ`, `S_FILL_WAIT`, `S_FILL_GET` | Pede a linha e grava as quatro palavras nas RAMs |
| Flush | `S_FL_TAG`, `S_FL_CHK`, `S_FL_NEXT` | Varre as linhas uma a uma |
| Escrita direta | `S_WT_REQ`, `S_WT_WAIT` | Repassa o store de uma palavra à memória |
| Sem cache | `S_BY_REQ`, `S_BY_WAIT`, `S_BY_GET` | Lê uma palavra da memória sem consultar a cache |

Em `S_IDLE`, um flush pendente tem prioridade sobre um acesso. Em `S_LOOK`, a decisão segue a ordem da tabela.

| Ordem | Condição | Próximo estado | Efeito |
| ---: | :--- | :--- | :--- |
| 1 | `i_bypass` em 1 e `i_wren` em 0 | `S_BY_REQ` | Load de uma palavra direto da memória |
| 2 | `i_wren` em 1 e (`write_through` ou endereço na ROM ou `i_bypass` em 1) | `S_WT_REQ` | Store repassado à memória |
| 3 | Acerto | `S_DONE` | Load guarda a palavra lida; store marca a linha como suja |
| 4 | Falha, linha válida e suja | `S_WB_RD` | Escrita de volta e depois preenchimento |
| 5 | Falha, linha limpa ou inválida | `S_FILL_REQ` | Preenchimento |

O acerto é a validade da linha com a tag lida igual à tag do endereço. Num store que segue a ordem 2 e acerta, as RAMs também recebem a palavra, exceto se o endereço está na ROM ou se `i_bypass` está em 1. Assim, um store à FLASH nunca altera a cache, nem num acerto nem numa falha; ele só é repassado à memória, onde o roteador de região o conclui sem efeito.

Terminado o preenchimento, a máquina volta a `S_IDLE` e refaz a consulta, de modo que o acesso que causou a falha é atendido como acerto. Num store sem `write_through`, isso marca a linha como suja (write-allocate).

### 3.4. Latências

Contadas em ciclos de `i_clk`, do ciclo em que o acesso aparece com a máquina em `S_IDLE` até o primeiro ciclo com `o_ready` em 1. Seja $k$ o número de ciclos que a memória leva para responder, contado nos ciclos de espera do estado correspondente ($k \ge 1$).

| Acesso | Ciclos |
| :--- | :--- |
| Acerto de load ou store (sem escrita direta) | $2$ |
| Falha com linha limpa ou inválida | $9 + k$ |
| Falha com linha suja | $18 + k_w + k_r$, com $k_w$ na escrita de volta e $k_r$ no preenchimento |
| Store com escrita direta | $3 + k$ |
| Load sem cache | $4 + k$ |

O ciclo extra do load sem cache é o de `S_BY_GET`, que lê `i_d_rdata` um ciclo depois de `i_d_ready`, porque o dado só muda na borda em que a memória avança. A mesma regra vale no preenchimento, onde `S_FILL_GET` percorre as palavras 0 a 3 em quatro ciclos.

### 3.5. Escrita de volta

Cada palavra da linha é lida da RAM (`S_WB_RD` e `S_WB_CAP`, dois ciclos por palavra) e acumulada em um registrador de 128 bits. O pedido de linha usa o endereço $\text{base} \,\Vert\, \text{tag} \,\Vert\, \text{índice} \,\Vert\, 0000_2$, com a palavra 0 em `o_d_wdata` e as palavras 1 a 3 em `o_d_wdata_x`. Ao receber `i_d_ready`, a linha fica limpa. Se a escrita de volta nasceu de um flush, a varredura segue; senão, segue o preenchimento.

### 3.6. Flush e invalidate

| Passo | Descrição |
| :--- | :--- |
| Pedido | Um ciclo com `i_flush` em 1 registra o pedido, e `o_busy` sobe no ciclo seguinte. O valor de `i_invalidate` no último ciclo de `i_flush` decide se a varredura derruba as linhas |
| Início | Em `S_IDLE`, antes de qualquer acesso que espere. Um acesso já em `S_LOOK` ou adiante termina antes, e um acesso que chega depois espera o fim |
| Varredura | Para cada linha, `S_FL_TAG`, `S_FL_CHK` e `S_FL_NEXT`; uma linha válida e suja passa antes pela escrita de volta |
| Fim | Ao fim da última linha, `o_flush_done` pulsa e `o_busy` cai no mesmo ciclo; com invalidate, todas as linhas ficam inválidas |

A varredura de uma cache sem linhas sujas leva $3 \cdot 2^I$ ciclos, mais o ciclo de partida. Um novo `i_flush` durante a varredura agenda mais uma varredura. `i_invalidate` sozinho, sem `i_flush`, não tem efeito.

### 3.7. Invalidação por região

Um pulso em `i_inval_region` derruba as linhas **limpas** dos endereços de `i_inval_first` a `i_inval_last`, que é o que o controlador de FLASH pede ao fim de um apagar ou gravar. A cache guarda a tag, não o endereço completo, então derruba por índice: toda linha limpa cujo índice contém algum endereço da região, inclusive a de outra região com o mesmo índice. Com $N$ linhas na região e $L$ linhas na cache, a região derruba as linhas de índice $i$ tais que

$$
(i - i_{primeira}) \bmod L < N \qquad \text{ou} \qquad N \ge L
$$

em que $i_{primeira}$ é o índice do endereço `i_inval_first`. Uma região com `i_inval_last` menor que `i_inval_first` não tem efeito.

1. Uma linha suja nunca é derrubada. Só a SDRAM tem linhas sujas, e a FLASH nunca é escrita pela cache.
2. O pedido é registrado e aplicado no ciclo seguinte; nenhuma linha da região acerta a partir do terceiro ciclo depois do pulso.
3. Um preenchimento em andamento cuja linha cai na região não valida a linha. O acesso que a pediu volta a `S_IDLE`, consulta de novo, falha e traz a linha outra vez, já com o dado novo.

### 3.8. Pulso de falha

`o_miss` fica em 1 em `S_FILL_REQ`, um ciclo por preenchimento. Loads sem cache e escritas diretas não geram pulso.

## 4. Integração

| Instância | Arquivo | Conexão |
| :--- | :--- | :--- |
| `u_cache` | `ext_axi_interconnect` do repositório Insper-RISC-V | Lado da memória ligado ao mestre AXI4 (`axi_master_bridge`) por um multiplexador com o acesso direto do core; `i_flush` recebe o pedido do periférico 7 e `i_invalidate` o bit 1 do dado escrito nele; `i_bypass` fica no padrão |
| `u_cache` | `src/cache/SoC/sim/sdram_dcache_system.vhd` | Lado da memória ligado a `axi_master_bridge`, `axi_slave_word_bridge` e ao controlador de SDRAM, para simulação |

No interconector, os generics de região ficam nos padrões e apenas `base_sdram` e `write_through` são repassados. Os acessos a periféricos e à última janela de 4 KB da SDRAM não chegam à cache, pois o interconector os desvia. O arranjo completo do caminho está em [dcache_axi.md](../barramento/dcache_axi.md), e a disputa pelo mestre AXI4 entre a cache e o acesso direto do core em [CACHE_MASTER_SHARING.md](../bugs/CACHE_MASTER_SHARING.md).

Para a FLASH, o lado da memória da cache pode passar por um [mem_region_router](mem_region_router.md), que separa SDRAM e FLASH e conclui sem efeito os stores à FLASH. A busca de instruções usa a [icache](icache.md).

## 5. Verificação

Os testes são cocotb em `tests/python/unittests/cache`, registrados em `tests/python/tests.json`. A prova formal está em `formal/dcache/` (ver [blocks](../formal/blocks.md)).

| Entrada de `tests.json` | Módulo de teste | O que cobre |
| :--- | :--- | :--- |
| `DataCache` | [data_cache.py](../../../tests/python/unittests/cache/data_cache.py) | Escrita e leitura de volta, latência de acerto e de falha, habilita de bytes, estabilidade de `o_ready` e `o_rdata`, evicção com escrita de volta, tráfego aleatório, flush mantendo as linhas válidas; compara a memória do chip com uma cópia em Python |
| `DataCacheWriteThrough` | [data_cache_write_through.py](../../../tests/python/unittests/cache/data_cache_write_through.py) | Store chega ao chip sem flush, falha de store não traz a linha, acerto atualiza linha e chip, tráfego aleatório |
| `DataCacheFlash` | [data_cache_flash.py](../../../tests/python/unittests/cache/data_cache_flash.py) | Load da FLASH em cache, store nunca altera a linha da FLASH, regiões sem alias, store à SDRAM ainda atualiza a linha, `i_bypass` em load e store, um pulso de falha por linha |
| `DataCacheRegion` | [data_cache_region.py](../../../tests/python/unittests/cache/data_cache_region.py) | Invalidação por região no modo write-back: derruba só a linha da região, região de várias linhas com volta do índice, linha suja do mesmo índice preservada, região do tamanho da cache, região invertida, preenchimento em andamento dentro da região não valida a linha |
| `DataCacheSmall` | [data_cache_small.py](../../../tests/python/unittests/cache/data_cache_small.py) | `size_bits` igual a 4096 com `write_through`, capacidade de 32 linhas e conflito a 512 bytes; usa apenas endereços da SDRAM |

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
