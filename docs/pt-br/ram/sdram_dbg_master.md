# sdram_dbg_master

## 1. Função do componente no SoC

O mestre de depuração da SDRAM executa, no clock do controlador, os comandos de leitura, escrita e preenchimento que um hospedeiro envia pela porta JTAG. Ele é o mestre B do árbitro da SDRAM, ao lado da ponte de dados e da ponte de instruções do core, e acessa o mesmo chip que o core usa. O hospedeiro pode assim ler e escrever qualquer palavra com o core rodando, parado ou travado. A visão do hospedeiro (registradores JTAG, comandos e limites) está em [sdram_debug.md](sdram_debug.md), e este documento descreve o lado do controlador.

## 2. Interface

### 2.1. Generics

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | ---: | :--- |
| `timeout_cycles` | natural | $2^{16}$ | ciclos de espera pela resposta do árbitro antes de o comando ser descartado |
| `addr_bits` | natural de 23 a 25 | 24 | bits do endereço de palavra (23 é a SDRAM de 32 MB da DE0-Nano); com 25 (a SDRAM de 128 MB da DE2-115), o bit 3 de `i_op` é o bit 24 do endereço |

### 2.2. Portas

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_clk` | entrada | 1 | clock do módulo, o do controlador |
| `i_rst` | entrada | 1 | reset síncrono, ativo em `'1'` |
| `i_cmd_tog` | entrada | 1 | alternância de comando vinda do hospedeiro (de qualquer clock), cada inversão é um comando novo |
| `o_done_tog` | saída | 1 | alternância que confirma o comando concluído |
| `i_op` | entrada | 4 | código do comando, de 0 a 7 nos bits 2 a 0, e o bit 24 do endereço no bit 3 quando `addr_bits` vale 25 |
| `i_be` | entrada | 4 | habilita de bytes das escritas |
| `i_addr` | entrada | 24 | endereço de palavra do comando |
| `i_data` | entrada | 32 | dado de escrita ou, no comando 4, a quantidade de palavras do preenchimento |
| `o_rsp_addr` | saída | 24 | última palavra acessada |
| `o_rsp_data` | saída | 32 | dado devolvido pela porta B no último acesso |
| `o_rsp_status` | saída | 8 | bit 1 sinaliza erro (sem resposta do controlador), bit 2 sinaliza SDRAM inicializada, bit 4 sinaliza hold ativo, os demais valem 0 |
| `i_init_done` | entrada | 1 | a inicialização da SDRAM terminou, de qualquer clock |
| `o_b_req_tog` | saída | 1 | alternância de pedido ao árbitro |
| `i_b_ack_tog` | entrada | 1 | alternância de confirmação, igual a `o_b_req_tog` quando o pedido foi atendido |
| `o_b_we` | saída | 1 | escrita (`'1'`) ou leitura (`'0'`) |
| `o_b_addr` | saída | `addr_bits` | endereço de palavra |
| `o_b_wdata` | saída | 32 | dado de escrita |
| `o_b_be` | saída | 4 | habilita de bytes da escrita |
| `i_b_rdata` | entrada | 32 | dado lido |
| `o_core_hold` | saída | 1 | pedido de parada do núcleo, `'1'` mantém o núcleo em reset; vai a `'1'` e a `'0'` pelo comando 7 e volta a `'0'` no reset do módulo |

## 3. Comportamento

### 3.1. Protocolo de comando

Um comando é uma inversão de `i_cmd_tog`, com `i_op`, `i_be`, `i_addr` e `i_data` estáveis da inversão até a resposta, que é uma inversão de `o_done_tog`. `i_cmd_tog` e `i_init_done` atravessam um sincronizador de dois estágios para o clock do módulo, e há um comando pendente enquanto o `i_cmd_tog` sincronizado difere de `o_done_tog`. Quando o comando termina, `o_done_tog` recebe o valor do `i_cmd_tog` sincronizado, o que iguala os dois. O resultado (`o_rsp_*`) fica estável desde antes dessa inversão até o próximo comando ser aceito.

### 3.2. Comandos

| `i_op` | Efeito |
| ---: | :--- |
| 0 | nada, responde sem acessar a memória |
| 1 | lê a palavra em `i_addr` |
| 2 | escreve `i_data` na palavra em `i_addr`, bytes por `i_be` |
| 3 | escreve `i_data` (todos os bytes) em `count` palavras consecutivas a partir de `i_addr`; com `count` igual a 0, responde sem escrever |
| 4 | define `count` como os 25 bits baixos de `i_data`, até $2^{24}$ palavras, a SDRAM inteira |
| 5 | lê a palavra seguinte à acessada por último |
| 6 | escreve `i_data` na palavra seguinte à acessada por último, bytes por `i_be` |
| 7 | controle, escolhido pelos bits 2 a 0 de `i_be` (tabela abaixo) |

O bit 3 de `i_op` só tem efeito com `addr_bits` igual a 25, e fora disso os códigos 8 a 15 repetem os de 0 a 7.

| `i_be` (bits 2 a 0) | Controle | Efeito |
| ---: | :--- | :--- |
| 0 | hold | `o_core_hold` recebe `i_data(0)`, e o comando responde na hora |
| 1 | crc32 | lê $n$ palavras a partir de `i_addr`, com $n$ igual aos 25 bits baixos de `i_data`, e devolve em `o_rsp_data` o CRC-32 delas |
| 2 a 7 | nenhum | só respondem (o seek de 2 é do núcleo JTAG e não chega aqui) |

O CRC-32 usa o polinômio refletido $\texttt{0xEDB88320}$, valor inicial e inversão final todos em 1, e cada palavra entra com os bytes do menor para o maior endereço, o que dá o `zlib.crc32` dos bytes lidos. Com $n$ igual a 0 o resultado é 0 e nada é lido. `o_rsp_addr` termina na última palavra lida.

Com `addr_bits` igual a 23, o bit 23 de `i_addr` é ignorado, e `o_rsp_addr` devolve os 24 bits baixos da última palavra acessada (o bit 24 não aparece com 25).

O valor de `count` é 1 depois do reset e se mantém entre comandos. O registrador tem 25 bits porque o preenchimento da SDRAM inteira vale $2^{24}$, que não cabe em 24 bits (veja [FILL_COUNT_24_BITS.md](../bugs/FILL_COUNT_24_BITS.md)).

### 3.3. Máquina de estados

| Estado | Ação | Próximo estado |
| :--- | :--- | :--- |
| `ST_IDLE` | com comando pendente, trava `i_op`, `i_be` e `i_data`, limpa o erro e executa o comando; leituras e escritas emitem um pedido ao árbitro (endereço, `o_b_we`, dado e máscara, inversão de `o_b_req_tog`, zera o contador de espera), os comandos 0 e 4 e o 3 com `count` zero respondem na hora | `ST_WAIT`, ou permanece |
| `ST_WAIT` | espera `i_b_ack_tog` igual a `o_b_req_tog`; ao receber, grava a palavra acessada em `o_rsp_addr` e `i_b_rdata` em `o_rsp_data` | `ST_NEXT` |
| `ST_FIN` | no comando 7 com o CRC, `o_rsp_data` já tem o resultado, e este estado inverte `o_done_tog` um ciclo depois, para o resultado ficar estável antes da resposta | `ST_IDLE` |
| `ST_NEXT` | no comando 3 com palavras restantes, emite a escrita da palavra seguinte; nos demais casos responde | `ST_WAIT` ou `ST_IDLE` |

O preenchimento escreve $\text{count}$ palavras, com $\text{count} - 1$ delas restantes depois da primeira, e `o_rsp_addr` termina na última palavra escrita. O dado em `o_rsp_data` é copiado de `i_b_rdata` ao fim de todo acesso, escrita incluída, então só tem significado depois de uma leitura.

Se `i_b_ack_tog` não alcançar `o_b_req_tog` em $\text{timeout\_cycles} + 1$ ciclos de `ST_WAIT`, o bit de erro de `o_rsp_status` sobe, o comando é descartado (um preenchimento em curso termina ali) e `o_done_tog` responde. O pedido não é cancelado, e a alternância de pedido só volta ao valor inicial no reset.

### 3.4. Latência

O comando é visto 2 bordas de `i_clk` depois de a inversão de `i_cmd_tog` ser amostrada, pelo sincronizador de dois estágios, e a execução parte da borda seguinte. Cada acesso gasta 1 ciclo para emitir o pedido, o tempo do árbitro e do controlador até a confirmação e 1 ciclo em `ST_NEXT`. A taxa de um preenchimento é a do árbitro com o controlador, em torno de 15 ciclos por palavra segundo [sdram_debug.md](sdram_debug.md).

## 4. Integração

| Item | Descrição |
| :--- | :--- |
| Instanciado em | `src/cyclone-v/de0-cv/de0-cv_top.vhd` do repositório Insper-RISC-V (instância `SDRAM_DEBUG`, no clock do controlador) e `src/RAM/SoC/sim/sdram_system.vhd` (instância `u_dbg`) |
| Recebe comandos de | `sdram_jtag_core`, direto na simulação e pelo invólucro `src/RAM/FPGA/Cyclone-V/sdram_jtag_shell.vhd` (que contém o Virtual JTAG) na placa |
| Entrega pedidos a | a porta do mestre B de `sdram_arbiter`, que os leva ao controlador |
| Usa | o sincronizador `synchronizer` da biblioteca Common-Components, duas instâncias, uma para `i_cmd_tog` e uma para `i_init_done` |

O mapa de endereços do core vê a SDRAM a partir de `0x40000000`, e um endereço de palavra $a$ do comando corresponde ao endereço de byte $0\text{x}40000000 + 4a$ visto pelo core. O árbitro alterna entre os mestres quando mais de um espera, e o comportamento está em [sdram_debug.md](sdram_debug.md) e na prova de [formal.md](../formal/formal.md).

## 5. Verificação

Os testes cocotb de `tests/python/unittests/ram/sdram_debug_port.py` rodam o sistema completo (controlador, árbitro, mestre de depuração, núcleo JTAG e modelo do chip), declarado como `SdramDebugPort` em `tests/python/tests.json`. A entrada `SdramSystem` compila as mesmas fontes, mas seus testes exercitam o caminho do core e não os comandos de depuração.

| Teste | Verifica |
| :--- | :--- |
| `test_write_and_read_back` | uma escrita lê de volta e chega ao chip, incluindo o endereço de palavra mais alto e as máscaras de bytes |
| `test_the_core_and_the_host_see_the_same_memory` | o que o core escreve o hospedeiro lê, e o contrário |
| `test_fill` | o preenchimento escreve exatamente `count` palavras a partir do endereço e não altera as vizinhas |
| `test_the_host_reaches_the_upper_half_of_a_128_mb_sdram` | com o chip de 32 bits (entrada `SdramDebugPort32`), o bit 3 de `op` alcança a metade alta das $2^{25}$ palavras |
| `test_the_fill_count_reaches_the_whole_sdram` | o registrador `count` guarda $2^{24}$ e $2^{24} - 1$ |
| `test_next_word_commands` | os comandos 5 e 6 seguem a última palavra acessada |
| `test_traffic_from_the_core_and_the_host_together` | acessos simultâneos do core e do hospedeiro não se corrompem |
| `test_a_command_while_busy_is_dropped` | o comando que chega com o mestre ocupado é descartado e sinalizado |
| `test_other_instructions_are_a_bypass` | outra instrução do JTAG não envia nada à memória |
| `test_the_core_is_not_starved_by_a_long_fill` | um preenchimento longo não atrasa o core além do limite do árbitro |

Os testes do comando 7 estão em `tests/python/unittests/ram/sdram_dbg_master.py` (entrada `SdramDbgMaster`, com o árbitro modelado por um dicionário) e em `sdram_debug_port.py`.

Não há prova formal deste bloco. A prova de [formal.md](../formal/formal.md) cobre o árbitro, com o mestre B modelado pelas hipóteses sobre o ambiente.

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
