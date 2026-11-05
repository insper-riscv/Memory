# flash_jtag_core

Lógica atrás da instância do Virtual JTAG do carregador da FLASH, no clock da cadeia JTAG.

## 1. Função do componente no SoC

No clock da cadeia JTAG, o bloco desloca o comando de 64 bits ou as palavras do STREAM vindos do hospedeiro, devolve o estado do comando anterior e entrega o comando ao [flash_loader](flash_loader.md), que roda no clock da porta B da FLASH. A instância do Virtual JTAG fica em `src/ROM/Cyclone-V/flash_jtag_shell.vhd`, e em simulação o testbench conduz as portas do bloco diretamente. Os registradores, os comandos e os limites do ponto de vista do hospedeiro estão em [flash_loader](flash_loader.md).

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
| `o_cmd_tog` | saída | 1 | alternância que pede um comando ao carregador |
| `o_op` | saída | 4 | operação do comando |
| `o_addr` | saída | 24 | índice de palavra do comando |
| `o_data` | saída | 32 | dado do comando |
| `i_done_tog` | entrada | 1 | alternância que confirma o comando concluído |
| `i_rsp_addr` | entrada | 24 | endereço da resposta |
| `i_rsp_data` | entrada | 32 | dado da resposta |
| `i_rsp_status` | entrada | 8 | status do carregador |

Todos os registradores do bloco rodam em `i_tck`, e as saídas de comando mudam só na aceitação de um comando.

## 3. Comportamento

### 3.1. Registradores

| Registrador | Largura | Selecionado quando | Função |
| :--- | ---: | :--- | :--- |
| instrução | 2 | carregado a cada Update-IR | escolhe o registrador de dados |
| CMD e STREAM | 64 | instrução igual a 1 ou a 2 | recebe o comando ou as palavras e envia o estado |
| bypass | 1 | qualquer outra instrução | repete o bit de entrada |
| cursor | 24 | sempre | índice da próxima palavra do STREAM |
| contador de bits | 5 | instrução igual a 2 | marca a palavra de 32 bits completa |
| início | 1 | instrução igual a 2 | indica que o bit de início já passou |

### 3.2. Aceitação de um comando

1. No Update-DR do CMD, uma operação diferente de 0 e de 6 é aceita se o carregador não estiver ocupado, e nesse caso inverte `o_cmd_tog`.
2. Se o carregador estiver ocupado, o comando é descartado e o bit de sobrecarga acende, até o próximo comando aceito.
3. A operação 6 só atualiza o cursor, sem passar pelo carregador, e a operação 0 só lê o status.
4. As operações 3 e 4 deixam o cursor em `addr + 1`.

### 3.3. Aceitação de uma palavra do STREAM

No Shift-DR com a instrução 2, o bloco espera o primeiro bit de valor 1, o bit de início. Depois dele, o contador de bits conta de 0 a 31, e no trigésimo segundo bit a palavra completa é entregue ao carregador como uma escrita no cursor, que avança. O bloco espera um novo bit de início a cada Capture-DR.

## 4. Verificação

O teste `FlashLoader` conduz este bloco pelas portas `i_jtag_*` do topo `flash_system`, como o Virtual JTAG faria (ver [flash_loader](flash_loader.md)).

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
