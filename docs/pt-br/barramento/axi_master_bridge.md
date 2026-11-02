# axi_master_bridge

## 1. Função do componente no SoC

Converte o acesso de dados externo do core, que segue o contrato de palavra com `ready` em nível até `mem_advance`, em transações AXI4 de um mestre. Um acesso de palavra vira uma transação de um beat de 4 bytes. Um acesso de linha, usado pela cache de dados, vira uma rajada INCR de quatro beats de 4 bytes. A ponte mantém uma única transação por vez, sem IDs (largura 0) e sem regras de ordenação.

## 2. Interface

O componente não tem generics.

### 2.1. Lado do core

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_clk` | entrada | 1 | clock do módulo |
| `i_rst` | entrada | 1 | reset síncrono, ativo em `'1'` |
| `i_addr` | entrada | 32 | endereço do acesso; os 2 bits baixos são descartados |
| `i_wdata` | entrada | 32 | dado de escrita da palavra 0 |
| `i_byteena` | entrada | 4 | habilita de bytes da palavra 0 |
| `i_rden` | entrada | 1 | pedido de leitura |
| `i_wren` | entrada | 1 | pedido de escrita; vence `i_rden` quando os dois estão em `'1'` |
| `i_mem_advance` | entrada | 1 | o pipeline avançou neste ciclo |
| `o_ready` | saída | 1 | acesso concluído, o dado lido é válido |
| `o_rdata` | saída | 32 | palavra 0 lida |
| `i_line` | entrada | 1 | acesso de linha, quatro palavras (padrão `'0'`) |
| `i_wdata_x` | entrada | 96 | palavras 1 a 3 de escrita, a palavra 1 nos bits mais baixos |
| `i_byteena_x` | entrada | 12 | habilita de bytes das palavras 1 a 3, 4 bits por palavra |
| `o_rdata_x` | saída | 96 | palavras 1 a 3 lidas, a palavra 1 nos bits mais baixos |
| `o_err` | saída | 1 | o escravo respondeu com erro, ou faltou `rlast` na leitura; só vale com `o_ready` em `'1'` |

### 2.2. Lado AXI4 (mestre)

| Canal | Sinais | Direção | Largura | Significado |
| :--- | :--- | :--- | ---: | :--- |
| AW | `o_m_awvalid`, `i_m_awready` | saída, entrada | 1 | handshake do endereço de escrita |
| AW | `o_m_awaddr` | saída | 32 | endereço da escrita, alinhado em 4 bytes |
| AW | `o_m_awlen` | saída | 8 | beats menos um, 3 para linha e 0 para palavra |
| AW | `o_m_awsize` | saída | 3 | log2 dos bytes por beat, fixo em `"010"` |
| AW | `o_m_awburst` | saída | 2 | tipo da rajada, fixo em `"01"` (INCR) |
| AW | `o_m_awprot` | saída | 3 | proteção, fixo em `"000"` |
| W | `o_m_wvalid`, `i_m_wready` | saída, entrada | 1 | handshake do beat de escrita |
| W | `o_m_wdata` | saída | 32 | dado do beat |
| W | `o_m_wstrb` | saída | 4 | habilita de bytes do beat |
| W | `o_m_wlast` | saída | 1 | último beat da rajada |
| B | `i_m_bvalid`, `o_m_bready` | entrada, saída | 1 | handshake da resposta de escrita |
| B | `i_m_bresp` | entrada | 2 | resposta; o bit 1 em `'1'` sinaliza erro |
| AR | `o_m_arvalid`, `i_m_arready` | saída, entrada | 1 | handshake do endereço de leitura |
| AR | `o_m_araddr` | saída | 32 | endereço da leitura, alinhado em 4 bytes |
| AR | `o_m_arlen`, `o_m_arsize`, `o_m_arburst`, `o_m_arprot` | saída | 8, 3, 2, 3 | mesmos valores dos campos de AW |
| R | `i_m_rvalid`, `o_m_rready` | entrada, saída | 1 | handshake do beat de leitura |
| R | `i_m_rdata` | entrada | 32 | dado do beat |
| R | `i_m_rresp` | entrada | 2 | resposta; o bit 1 em `'1'` sinaliza erro |
| R | `i_m_rlast` | entrada | 1 | último beat da rajada |

## 3. Comportamento

### 3.1. Contrato do lado do core

O acesso permanece em `i_addr`, `i_wdata`, `i_byteena`, `i_rden` e `i_wren` enquanto o estágio de memória está parado. `o_ready` sobe quando o acesso termina e permanece em nível alto até `i_mem_advance`. `o_rdata` e `o_rdata_x` só mudam nessa mesma borda, porque o load que ainda está no estágio de write-back lê o valor anterior até lá. Uma escrita não altera `o_rdata` nem `o_rdata_x`.

### 3.2. Estados

| Estado | Condição de saída | Próximo estado |
| :--- | :--- | :--- |
| `ST_IDLE` | `i_rden` ou `i_wren` em `'1'` | `ST_WR` se `i_wren`, senão `ST_RD` |
| `ST_WR` | `B` aceito com o endereço e todos os beats já aceitos | `ST_DONE` |
| `ST_RD` | último beat de `R` aceito | `ST_DONE` |
| `ST_DONE` | `i_mem_advance` em `'1'` | `ST_IDLE` |

Na saída de `ST_IDLE` o endereço (com os 2 bits baixos zerados), os dados, os habilita de bytes e o tipo do acesso são copiados para registradores. Os campos do barramento AXI saem desses registradores, então ficam estáveis enquanto um `valid` está alto, o que o core faça o que fizer. O último beat é 3 quando `i_line` está em `'1'` e 0 caso contrário.

### 3.3. Escrita

1. `o_m_awvalid` e `o_m_wvalid` sobem juntos, um ciclo depois de o acesso ser capturado. A ponte não espera o handshake de AW para oferecer W, portanto W pode ser aceito antes de AW.
2. `o_m_awvalid` cai quando `i_m_awready` é visto em `'1'`.
3. Cada beat de W é retido até o seu `i_m_wready`. O beat 0 usa `i_wdata` e `i_byteena`, e os beats 1 a 3 usam a fatia correspondente de `i_wdata_x` e `i_byteena_x`. `o_m_wlast` é `'1'` no beat igual ao último.
4. `o_m_bready` só é `'1'` em `ST_WR` com AW e W já aceitos, então uma resposta que chega antes não é tomada.
5. Ao aceitar B, o bit 1 de `i_m_bresp` é guardado como erro e o estado passa para `ST_DONE`.

### 3.4. Leitura

1. `o_m_arvalid` sobe um ciclo depois da captura e cai com `i_m_arready`.
2. `o_m_rready` só é `'1'` em `ST_RD` depois de AR aceito.
3. Cada beat de R é guardado na palavra correspondente (palavra 0 em `o_rdata`, palavras 1 a 3 em `o_rdata_x`) e o contador de beats avança.
4. O estado passa para `ST_DONE` no beat igual ao último ou quando `i_m_rlast` vem em `'1'`, o que ocorrer primeiro.
5. As palavras lidas ficam retidas e só são entregues em `o_rdata` e `o_rdata_x` quando `i_mem_advance` chega em `ST_DONE`.

Uma leitura sempre pede palavras inteiras, e `i_byteena` não é usado.

### 3.5. Campos fixos das transações

| Campo | Valor |
| :--- | :--- |
| endereço | `i_addr` com os bits 1 e 0 em zero |
| comprimento | 3 se `i_line`, senão 0 |
| tamanho | 4 bytes |
| tipo de rajada | INCR |
| proteção | sem privilégio, seguro, dados |
| ID, lock e cache | não existem nas portas |

### 3.6. Erros

`o_err` vale `'1'` em `ST_DONE` quando ocorreu qualquer uma destas condições, e é `'0'` fora desse estado.

| Condição | Canal |
| :--- | :--- |
| bit 1 de `i_m_bresp` em `'1'` (SLVERR ou DECERR) | B |
| bit 1 de `i_m_rresp` em `'1'` em qualquer beat | R |
| `i_m_rlast` diferente de (beat atual igual ao último) | R |

### 3.7. Latência

Contada em bordas de clock a partir da borda que captura o acesso, com um escravo que aceita e responde sem espera, e derivada da máquina de estados. `o_ready` fica em `'1'` no ciclo seguinte à última borda da tabela.

| Acesso | Bordas |
| :--- | ---: |
| palavra (leitura ou escrita) | 3 |
| linha (leitura ou escrita) | 6 |

Cada espera do escravo acrescenta um ciclo à fase em que ocorre.

## 4. Integração

- O interconector AXI4 (`ext_axi_interconnect`, do repositório Insper-RISC-V) instancia a ponte como mestre e liga a saída AXI ao roteador. Ele escolhe, a cada acesso, entre o acesso direto do core (palavra) e o acesso da cache (palavra ou linha), e fixa `i_byteena_x` em todos os bits em `'1'`. A saída `o_err` não é usada.
- O topo de simulação da cache de dados liga a ponte diretamente a um escravo de palavra, sem roteador.
- O lado do contrato de palavra é o mesmo de uma ponte de memória do core, e o lado AXI é aceito pelo roteador AXI do repositório Insper-RISC-V e por `axi_slave_word_bridge`.

Veja [DCACHE_AXI.md](../../DCACHE_AXI.md) para o caminho completo do dado e [AXI_UNALIGNED_BYTE_STORE.md](../../bugs/AXI_UNALIGNED_BYTE_STORE.md) para o motivo de o endereço sair alinhado à palavra.

## 5. Verificação

| Cobertura | Onde |
| :--- | :--- |
| ponte com a cache e o escravo de palavra, ponta a ponta | testes `DataCache` e `DataCacheWriteThrough` em `tests/python/tests.json` |
| prova formal | [formal/axi_master](../../../formal/axi_master/props.sv), executada por `bash formal/axi_master/run.sh` |

A prova formal usa o netlist sintetizado do VHDL, trata o core e o escravo como entradas livres sujeitas a suposições do contrato e garante o seguinte.

1. `valid` é mantido até o `ready` correspondente, com o conteúdo estável (endereço, proteção, dado, `wstrb` e `wlast`).
2. Cada acesso gera um único pedido, com endereço alinhado e comprimento 3 ou 0 conforme `i_line`, e nunca há escrita e leitura ao mesmo tempo.
3. Tamanho 4 bytes, INCR e proteção zero em toda transação, e `wlast` exatamente no último beat.
4. As palavras 1 a 3 enviadas são as que o core deu, e `bready` e `rready` só sobem depois do pedido aceito.
5. `o_ready` permanece em nível até `i_mem_advance`, `o_rdata` e `o_rdata_x` só mudam nessa borda e `o_err` implica `o_ready`.
6. Um acesso termina em até 20 clocks quando o escravo aceita e responde em até 3 clocks por canal e o core avança o pipeline no clock seguinte a `o_ready`.

A prova de segurança é por indução sem limite de profundidade. Sete cenários de cobertura (leitura e escrita de palavra e de linha, W ainda oferecido depois de AW aceito, AW ainda oferecido depois de W aceito e resposta de erro) precisam ser alcançáveis, e seis mutantes do VHDL precisam falhar (B aceito sem esperar AW e W, `wstrb` errado, W sem esperar `wready`, `ready` sem `i_mem_advance`, `wlast` sempre em `'1'` e `arlen` errado). O método geral está em [FORMAL.md](../../FORMAL.md).

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
