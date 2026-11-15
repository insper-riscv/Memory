# sdram_jtag_core

## 1. Função do componente no SoC

O núcleo JTAG da depuração da SDRAM é a lógica atrás de uma instância do Virtual JTAG. No clock da cadeia JTAG, ele desloca um comando de 64 bits vindo do hospedeiro, devolve o estado do comando anterior e entrega o comando ao mestre de depuração (`sdram_dbg_master`), que roda no clock do controlador. Além do comando único, o núcleo move rajadas de até 128 palavras entre o hospedeiro e a SDRAM, como uma sequência de comandos de leitura e de escrita ao mesmo mestre, sem consulta de status no meio. O protocolo visto pelo hospedeiro está em [sdram_jtag_protocol.md](sdram_jtag_protocol.md).
 A instância do Virtual JTAG fica no invólucro de placa `src/RAM/FPGA/Cyclone-V/sdram_jtag_shell.vhd`, e em simulação o testbench conduz as portas do núcleo diretamente. Os registradores, os comandos e os limites do ponto de vista do hospedeiro estão em [sdram_debug.md](sdram_debug.md).

## 2. Interface

O componente não tem generics.

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_tck` | entrada | 1 | clock da cadeia JTAG |
| `i_tdi` | entrada | 1 | dado serial vindo do hospedeiro |
| `o_tdo` | saída | 1 | dado serial para o hospedeiro |
| `i_ir_in` | entrada | 2 | valor do registrador de instrução do Virtual JTAG |
| `i_state_cdr` | entrada | 1 | estado Capture-DR da cadeia virtual |
| `i_state_sdr` | entrada | 1 | estado Shift-DR da cadeia virtual |
| `i_state_udr` | entrada | 1 | estado Update-DR da cadeia virtual |
| `i_state_uir` | entrada | 1 | estado Update-IR da cadeia virtual |
| `o_cmd_tog` | saída | 1 | alternância que pede um comando ao mestre de depuração |
| `o_op` | saída | 4 | operação do comando |
| `o_be` | saída | 4 | habilita de bytes do comando |
| `o_addr` | saída | 24 | endereço de palavra do comando |
| `o_data` | saída | 32 | dado do comando (escrita ou quantidade do preenchimento) |
| `i_done_tog` | entrada | 1 | alternância que confirma o comando concluído |
| `i_rsp_addr` | entrada | 24 | última palavra acessada |
| `i_rsp_data` | entrada | 32 | dado da última leitura |
| `i_rsp_status` | entrada | 8 | status do mestre de depuração |

Todos os registradores do bloco rodam em `i_tck`, e as saídas de comando mudam só na aceitação de um comando.

## 3. Comportamento

### 3.1. Registradores

| Registrador | Largura | Selecionado quando | Função |
| :--- | ---: | :--- | :--- |
| instrução (`ir`) | 2 | carregado a cada Update-IR | escolhe o registrador de dados |
| DEBUG (`sr`) | 64 | instrução igual a 1 | recebe o comando e envia o estado |
| bypass | 1 | instrução igual a 0 ou não listada | repete o bit de entrada, sem enviar nada à memória |
| rajada de escrita | 32 por palavra | instrução igual a 2 | monta cada palavra que entra e a escreve na SDRAM; o que sai é o quadro de status e depois zeros |
| rajada de leitura | 64 mais 32 por palavra | instrução igual a 3 | envia o quadro de status e depois as palavras lidas da SDRAM |

`o_tdo` é o bit 0 do registrador de deslocamento `sr` nas instruções 1 a 3 e o bypass nos demais casos.

### 3.2. Formato do registrador DEBUG

| Sentido | Bits | Campo | Significado |
| :--- | :--- | :--- | :--- |
| entra | 63 a 60 | op | comando (os do `sdram_dbg_master`) |
| entra | 59 a 56 | be | habilita de bytes |
| entra | 55 a 32 | addr | endereço de palavra |
| entra | 31 a 0 | data | dado de escrita ou quantidade do preenchimento |
| sai | 63 a 56 | status | tabela abaixo |
| sai | 55 a 32 | word | última palavra acessada |
| sai | 31 a 0 | data | dado da última leitura |

| Bit do status | Origem | Significado |
| ---: | :--- | :--- |
| 0 | `busy` | o comando anterior não terminou, e `word` e `data` ainda não valem |
| 1 | bit 1 de `i_rsp_status` | o controlador não respondeu |
| 2 | bit 2 de `i_rsp_status` | a SDRAM está inicializada |
| 3 | `overrun` | um comando chegou com o mestre ocupado e foi descartado |
| 4 | `stream_err` | uma palavra da rajada anterior chegou tarde ou foi perdida |
| 5 | bit 4 de `i_rsp_status` | o mestre de depuração mantém o núcleo parado (hold) |
| 6 e 7 | constante | zero |

### 3.3. Ciclo de um deslocamento

| Estado da cadeia | Efeito com a instrução 1 | Efeito com outra instrução |
| :--- | :--- | :--- |
| Capture-DR | carrega o DEBUG com o status, `i_rsp_addr` e `i_rsp_data` | nenhum |
| Shift-DR | desloca o DEBUG um bit à direita, entrando `i_tdi` no bit 63 | grava `i_tdi` no bypass |
| Update-DR | aceita o comando se `op` for diferente de 0 | nenhum |
| Update-IR | carrega `ir` com `i_ir_in` | carrega `ir` com `i_ir_in` |

As instruções 2 e 3 não seguem as colunas acima, e a seção 3.5 descreve o que fazem.
No Update-DR com `op` diferente de 0, o comportamento depende de `busy`, que vale 1 enquanto `o_cmd_tog` difere de `i_done_tog` sincronizado.

| `busy` | Efeito |
| :--- | :--- |
| 0 | limpa `overrun`, registra `op`, `be`, `addr` e `data` nas saídas e inverte `o_cmd_tog` |
| 1 | sobe `overrun` e descarta o comando |

Um deslocamento com `op` igual a 0 só lê o status e não envia nada. A leitura do status então não gera comando por si, o que impede que cada consulta crie um novo comando que nunca termina (veja [JTAG_STATUS_POLL.md](../bugs/JTAG_STATUS_POLL.md)).

### 3.4. Travessia de clock e temporização

`i_done_tog` entra em `i_tck` por uma instância `u_sync_done` do `synchronizer` de dois estágios, interna ao bloco, e só avança em bordas de `i_tck`. O status é capturado no início do deslocamento, uma ou duas bordas de `i_tck` depois do envio do comando, de modo que o primeiro deslocamento depois de um comando ainda pode mostrar `busy` e o seguinte não, porque os 64 deslocamentos dão tempo ao sincronizador. `o_cmd_tog`, `o_op`, `o_be`, `o_addr` e `o_data` ficam estáveis até o próximo comando aceito, e o mestre de depuração os lê depois de sincronizar `o_cmd_tog` ao seu clock. `i_rsp_addr`, `i_rsp_data` e `i_rsp_status` são capturados direto no Capture-DR, sem sincronizador, e só valem quando `busy` é 0, porque o mestre de depuração os mantém estáveis desde antes da inversão de `i_done_tog`.

### 3.5. Rajadas

O ponteiro de rajada `sp` tem 25 bits e é o endereço de palavra da próxima palavra a mover. O comando 7 com `be` igual a 2 (seek), enviado pelo DEBUG, carrega `sp` com o endereço do comando (o bit 24 vem do bit 63). O seek não vai ao mestre de depuração e é aceito mesmo com `busy` igual a 1. Um contador `cnt` conta as bordas de Shift-DR desde o Capture-DR.

| Instrução | Capture-DR | A cada borda de Shift-DR |
| :--- | :--- | :--- |
| 2, escrita | carrega o quadro de status em `sr` e limpa `stream_err` depois de o quadro o ler | desloca `i_tdi` para o registrador de palavra; a cada 32 bits (até a 128ª palavra) escreve a palavra em `sp` e avança `sp`; se `busy` vale 1, em vez disso sobe `stream_err` e perde a palavra |
| 3, leitura | carrega o quadro, limpa `stream_err` e pede a leitura de `sp`; se `busy` vale 1, sobe `stream_err` | desloca `sr`; no último bit do quadro e no de cada palavra, carrega `i_rsp_data` em `sr` e pede a leitura de `sp` mais 1; `sp` avança quando o primeiro bit de uma palavra sai |

Na leitura, a palavra carregada só vale se `busy` vale 0 e `i_rsp_addr` é igual a `sp`; caso contrário `stream_err` sobe. O avanço de `sp` no primeiro bit de cada palavra mantém o ponteiro consistente quando o hospedeiro termina o deslocamento no meio, porque a última carga antecipada não é contada. Um comando aceito pelo DEBUG e um seek limpam `stream_err`.

Cada pedido de leitura ou de escrita usa os mesmos registradores de comando do DEBUG (`o_op`, `o_be`, `o_addr` e `o_data`) e inverte `o_cmd_tog`, com `o_be` igual a `"1111"`, e o bit 3 de `o_op` leva o bit 24 de `sp`. A palavra seguinte só é pedida depois de a anterior terminar, e a condição de tempo (32 clocks de `i_tck` por palavra) está em [sdram_jtag_protocol.md](sdram_jtag_protocol.md).

## 4. Integração

| Item | Descrição |
| :--- | :--- |
| Instanciado em | `src/RAM/FPGA/Cyclone-V/sdram_jtag_shell.vhd` (placa, ao lado do `sld_virtual_jtag`) e `src/RAM/SoC/sim/sdram_system.vhd` (instância `u_jtag`, conduzida pelo testbench) |
| Entrega comandos a | `sdram_dbg_master`, por `o_cmd_tog`, `o_op`, `o_be`, `o_addr` e `o_data` |
| Recebe de | `sdram_dbg_master`, por `i_done_tog`, `i_rsp_addr`, `i_rsp_data` e `i_rsp_status` |
| Hospedeiro | a instância do Virtual JTAG tem registrador de instrução de 2 bits, e a instrução 1 seleciona o DEBUG de 64 bits |

A porta JTAG da UART do barramento externo é outra instância do Virtual JTAG, descrita em [jtag_uart.md](https://github.com/insper-riscv/Peripherals/blob/main/docs/pt-br/UART/jtag_uart.md).

## 5. Verificação

Os testes de `tests/python/unittests/ram/sdram_debug_port.py` (entrada `SdramDebugPort` de `tests/python/tests.json`) conduzem `i_tck`, `i_tdi` e os estados da cadeia virtual do `sdram_system`, de modo que cada comando passa pelo núcleo JTAG real.

| Teste | Verifica no núcleo JTAG |
| :--- | :--- |
| `test_a_command_while_busy_is_dropped` | o comando que chega com `busy` em 1 sobe `overrun` e não executa |
| `test_other_instructions_are_a_bypass` | com outra instrução o registrador é de 1 bit e nada chega à memória |
| `test_write_and_read_back` e os demais de leitura e escrita | o formato dos 64 bits e a leitura do status até `busy` voltar a 0 |
| `test_seek_only_moves_the_pointer` | o seek não chega ao mestre e a rajada escreve a partir do seu endereço |
| `test_a_stream_write_moves_the_pointer_between_shifts`, `test_a_stream_write_of_the_largest_burst` e `test_a_partial_word_is_not_written` | palavras consecutivas entre deslocamentos, o limite de 128 palavras por deslocamento e bits que não fecham uma palavra |
| `test_a_stream_read_returns_the_words_in_order` e `test_a_seek_reaches_the_upper_half_of_a_128_mb_sdram` | a leitura continua de um deslocamento para o seguinte, e o endereço de 25 bits do ponteiro |
| `test_a_slow_master_flags_the_stream_error`, `test_a_late_read_word_is_flagged`, `test_a_wrong_word_in_a_stream_read_is_flagged` e `test_the_stream_error_clears_when_a_stream_starts` | o bit de erro de rajada por palavra tardia, por palavra de outro endereço e a sua limpeza |
| `test_the_status_reports_the_hold_of_the_master` e `test_the_control_commands_other_than_seek_reach_the_master` | o bit 5 do status e a passagem do hold e do CRC ao mestre |

Não há prova formal deste bloco.

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
