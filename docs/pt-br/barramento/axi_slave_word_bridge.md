# axi_slave_word_bridge

## 1. Função do componente no SoC

Escravo AXI4 colocado na frente de uma memória que segue o contrato de palavra do core (acesso mantido até `ready`, avanço por `mem_advance`), com a extensão de linha desse contrato. Traduz rajadas INCR de beats de 4 bytes em acessos à memória, uma transação por vez e sem IDs (largura 0). No SoC ele fica atrás da porta de memória do roteador, e a memória atrás dele é a ponte da SDRAM.

## 2. Interface

O componente não tem generics.

### 2.1. Controle

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_clk` | entrada | 1 | clock do módulo |
| `i_rst` | entrada | 1 | reset síncrono, ativo em `'1'` |

### 2.2. Porta escravo AXI4

| Canal | Sinais | Direção | Largura | Significado |
| :--- | :--- | :--- | ---: | :--- |
| AW | `i_s_awvalid`, `o_s_awready` | entrada, saída | 1 | handshake do endereço de escrita |
| AW | `i_s_awaddr` | entrada | 32 | endereço do primeiro beat |
| AW | `i_s_awlen` | entrada | 8 | beats menos um |
| AW | `i_s_awsize` | entrada | 3 | log2 dos bytes por beat |
| AW | `i_s_awburst` | entrada | 2 | tipo da rajada |
| W | `i_s_wvalid`, `o_s_wready` | entrada, saída | 1 | handshake do beat de escrita |
| W | `i_s_wdata` | entrada | 32 | dado |
| W | `i_s_wstrb` | entrada | 4 | habilita de bytes |
| W | `i_s_wlast` | entrada | 1 | último beat da rajada |
| B | `o_s_bvalid`, `i_s_bready` | saída, entrada | 1 | handshake da resposta de escrita |
| B | `o_s_bresp` | saída | 2 | `"00"` (OKAY) ou `"10"` (SLVERR) |
| AR | `i_s_arvalid`, `o_s_arready` | entrada, saída | 1 | handshake do endereço de leitura |
| AR | `i_s_araddr`, `i_s_arlen`, `i_s_arsize`, `i_s_arburst` | entrada | 32, 8, 3, 2 | mesmos campos de AW |
| R | `o_s_rvalid`, `i_s_rready` | saída, entrada | 1 | handshake do beat de leitura |
| R | `o_s_rdata` | saída | 32 | dado lido, zero em transação recusada |
| R | `o_s_rresp` | saída | 2 | `"00"` (OKAY) ou `"10"` (SLVERR) |
| R | `o_s_rlast` | saída | 1 | último beat da rajada |

### 2.3. Porta de memória (contrato de palavra com extensão de linha)

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `o_addr` | saída | 32 | endereço do acesso |
| `o_wdata` | saída | 32 | dado de escrita da palavra 0 |
| `o_byteena` | saída | 4 | habilita de bytes da palavra 0 |
| `o_rden` | saída | 1 | pedido de leitura |
| `o_wren` | saída | 1 | pedido de escrita |
| `o_mem_advance` | saída | 1 | pulso de avanço do acesso |
| `i_ready` | entrada | 1 | a memória concluiu o acesso, o dado lido é válido |
| `i_rdata` | entrada | 32 | palavra 0 lida |
| `o_line` | saída | 1 | acesso de linha, quatro palavras |
| `o_wdata_x` | saída | 96 | palavras 1 a 3 de escrita, a palavra 1 nos bits mais baixos |
| `o_byteena_x` | saída | 12 | habilita de bytes das palavras 1 a 3 |
| `i_rdata_x` | entrada | 96 | palavras 1 a 3 lidas |

## 3. Comportamento

### 3.1. Transações atendidas

Todas as transações atendidas são INCR com beats de 4 bytes e endereço alinhado em 4 bytes.

| Transação | Tratamento |
| :--- | :--- |
| `len` igual a 3 e endereço alinhado em 16 bytes | um acesso de linha à memória, com `o_line` em `'1'` |
| qualquer outro `len` | um acesso de palavra por beat, em ordem, com o endereço somado de 4 a cada beat |
| tamanho diferente de 4 bytes, tipo diferente de INCR ou endereço não alinhado em 4 bytes | recusada, resposta SLVERR depois de todos os beats serem consumidos (escrita) ou dados como zeros (leitura), e nada chega à memória |

A recusa não depende de `len`, e o comprimento vai de 1 a 256 beats.

### 3.2. Estados

| Estado | Ação | Próximo estado |
| :--- | :--- | :--- |
| `ST_IDLE` | `o_s_awready` em `'1'`, e `o_s_arready` em `'1'` apenas se `i_s_awvalid` está em `'0'`. Copia endereço e `len`, avalia recusa e linha | AW leva a `ST_WBEAT`. AR recusada leva a `ST_RBEAT`. AR válida leva a `ST_ACC` |
| `ST_WBEAT` | `o_s_wready` em `'1'`. Recusada, consome beats até `wlast`. Linha, guarda os quatro beats (o beat k nas posições de palavra k). Palavra, guarda o beat | recusada, `ST_BRESP` após `wlast`. Linha, `ST_ACC` após o quarto beat. Palavra, `ST_ACC` |
| `ST_ACC` | mantém `o_rden` ou `o_wren` até `i_ready` | `ST_ADV` com `i_ready` |
| `ST_ADV` | mantém `o_rden` ou `o_wren` e emite `o_mem_advance` por um ciclo | escrita, `ST_BRESP` se linha ou último beat, senão soma 4 ao endereço e vai a `ST_WBEAT`. Leitura, `ST_RBEAT` |
| `ST_RBEAT` | `o_s_rvalid` em `'1'` com o beat | com `i_s_rready`, `ST_IDLE` após o último beat, `ST_ACC` para o próximo beat de palavra, o mesmo estado para o próximo beat de linha ou de recusada |
| `ST_BRESP` | `o_s_bvalid` em `'1'` | `ST_IDLE` com `i_s_bready` |

Uma escrita oferecida ao mesmo tempo que uma leitura passa na frente, e a leitura espera. Nenhum pedido é aceito antes de a resposta inteira ser tomada.

### 3.3. Escrita

1. AW é aceito primeiro, e `o_s_wready` só sobe depois. Um W oferecido antes espera.
2. Numa transação recusada, cada beat de W é consumido até `wlast`, e a resposta é SLVERR.
3. Numa linha, os quatro beats são guardados e a memória recebe um único acesso de linha, com a palavra 0 em `o_wdata` e `o_byteena` e as palavras 1 a 3 em `o_wdata_x` e `o_byteena_x`. Depois do avanço, vem uma única resposta B.
4. Em qualquer outra rajada, cada beat é um acesso de palavra completo (`ST_ACC`, `ST_ADV`), com a resposta B só depois do último.
5. Numa transação válida o `wlast` não é conferido, o número de beats vem de `len`.

### 3.4. Leitura

1. AR válido leva ao acesso de leitura (`o_rden`) e, depois do avanço, ao primeiro beat de R.
2. Numa linha, a memória é lida uma vez, e os quatro beats de R saem de `i_rdata` e `i_rdata_x` na ordem, com `o_s_rlast` no quarto.
3. Em qualquer outra rajada, cada beat faz um acesso de palavra à memória, com `o_s_rlast` no último beat, que é o de contador restante igual a zero.
4. Numa transação recusada, os `len` mais um beats saem com dado zero e SLVERR, sem acesso à memória. O beat seguinte é oferecido no clock depois de o anterior ser aceito.
5. O dado lido da memória só muda no seu próprio `mem_advance`, então permanece válido enquanto um beat espera por `i_s_rready`.

### 3.5. Interface com a memória

O acesso fica em `o_addr`, `o_rden` ou `o_wren` até `i_ready`. Depois disso o componente emite `o_mem_advance` por um ciclo com o acesso ainda presente. A memória não tem outro bloco parado, portanto o avanço é um pulso.

### 3.6. Resposta

| Situação | Resposta |
| :--- | :--- |
| transação válida | OKAY |
| transação recusada | SLVERR em B ou em cada beat de R, com dado zero em R |

## 4. Integração

- O interconector AXI4 do repositório Insper-RISC-V expõe a porta mestre AXI4 do escravo 0 do roteador, e o escravo de palavra é ligado a essa porta fora do interconector.
- Os topos de simulação da cache de dados e do próprio escravo ligam o componente à ponte da SDRAM, com `axi_master_bridge` ou com um mestre de teste.

Veja [DCACHE_AXI.md](../../DCACHE_AXI.md) para o caminho completo, [SDRAM_LINE.md](../../SDRAM_LINE.md) para o acesso de linha do controlador e [AXI_UNALIGNED_BYTE_STORE.md](../../bugs/AXI_UNALIGNED_BYTE_STORE.md) para o motivo de endereços não alinhados serem recusados.

## 5. Verificação

| Cobertura | Onde |
| :--- | :--- |
| escravo com o chip simulado | `AxiSdramSlave`, módulo [axi_sdram_slave.py](../../../tests/python/unittests/barramento/axi_sdram_slave.py) |
| escravo na cadeia da cache | `DataCache` e `DataCacheWriteThrough` |
| prova formal | [formal/axi_slave](../../../formal/axi_slave/props.sv), executada por `bash formal/axi_slave/run.sh` |

O teste `AxiSdramSlave` cobre cinco comportamentos.

1. Uma rajada de linha é escrita e lida inteira.
2. Os `wstrb` de cada beat de uma rajada de linha são respeitados.
3. Rajadas de 1, 2, 3, 5 e 8 beats, alinhadas ou não em 16 bytes, geram um acesso de palavra por beat.
4. WRAP, FIXED, tamanhos diferentes de 4 bytes e endereço não alinhado respondem SLVERR em escrita e leitura sem tocar no chip, e uma transação válida é atendida depois deles.
5. Uma leitura de linha é mais rápida que quatro leituras de palavra.

A prova formal trata o mestre AXI4 e a memória como entradas livres sujeitas a suposições do contrato e garante o seguinte.

1. Handshakes e o flag de último beat corretos, com `bvalid`, `rvalid`, `bresp`, `rresp`, `rdata` e `rlast` mantidos até o `ready` correspondente.
2. Uma transação por vez, sem AW e AR aceitos juntos, e nunca `o_rden` e `o_wren` ao mesmo tempo.
3. Uma transação recusada nunca chega à memória, e um acesso de linha só ocorre com `len` igual a 3 e endereço alinhado em 16 bytes.
4. `o_mem_advance` só ocorre com a memória pronta e o acesso ativo.
5. Resposta SLVERR e dado zero em toda transação recusada, OKAY nas demais.
6. Uma transação de até quatro beats é respondida em até 40 clocks depois de aceita, se o mestre e a memória respondem em até 3 clocks.

A prova de segurança é limitada a 55 clocks a partir do reset, o que cobre transações de até quatro beats. O conteúdo que chega à memória é verificado pelo teste de sistema acima, e não pela prova. Seis cenários de cobertura precisam ser alcançáveis (escrita e leitura de quatro beats, escrita e leitura recusadas, escrita de dois beats por palavra e uma leitura que espera uma escrita), e seis mutantes do VHDL precisam falhar (leitura que passa na frente da escrita, AW aceito duas vezes, `rlast` adiantado, endereço não alinhado atendido, resposta sem esperar `bready` e avanço sem `i_ready`). O método geral está em [FORMAL.md](../../FORMAL.md).

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
