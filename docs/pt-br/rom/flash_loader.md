# flash_loader

Carregador da FLASH interna: um hospedeiro grava a imagem de cada teste na única cópia da [flash](flash.md) pela JTAG, só com o núcleo parado.

## 1. Função do componente no SoC

A FLASH interna tem uma só cópia, de duas portas. A porta B é do estágio MEM, que lê a FLASH como dado, até o hospedeiro mandar o comando de parada. A saída `o_halt` do carregador é ligada ao reset do núcleo no topo, então parar o carregador para o núcleo. Com o núcleo parado a porta B passa a ser do carregador, que escreve e lê palavras a pedido do hospedeiro. O núcleo só lê a FLASH, porque a escrita existe apenas na porta B.

| Bloco | Clock | Papel |
| :--- | :--- | :--- |
| [flash_jtag_core](flash_jtag_core.md) | Clock da JTAG | Registradores de instrução e de dados e a passagem de um comando |
| `flash_loader` | Clock da porta B da FLASH | Executa o comando, comuta a porta B e guarda o estado de parada |
| `flash_jtag_shell` (`src/ROM/Cyclone-V/`) | | Instância do `virtual_jtag` do Common-Components (o `sld_virtual_jtag` da Intel) mais o `flash_jtag_core`, só para a FPGA |

### 1.1. Garantia de que o núcleo não lê durante a escrita

1. A habilitação de escrita da porta B é o pulso do carregador combinado com o estado de parada, então com o núcleo em execução ela vale `'0'` por construção, qualquer que seja o comando recebido.
2. Uma escrita ou uma leitura pedida com o núcleo em execução é recusada, não altera a memória e acende o bit de recusa do status até a próxima parada.
3. Com o núcleo parado o seletor da porta B escolhe o carregador, e o endereço do estágio MEM é ignorado.

### 1.2. Porta de depuração da FLASH

O carregador é a porta de depuração do backend de FLASH emulada, e a tabela da porta de depuração de cada backend está em [sdram_debug](../ram/sdram_debug.md), seção 7.

## 2. Interface

### 2.1. Generic

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | :--- | :--- |
| `addr_width` | `positive` | 13 | Largura em bits do índice de palavra da FLASH |

### 2.2. Portas

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_clk` | entrada | 1 | clock da porta B da FLASH |
| `i_rst` | entrada | 1 | reset, ativo em `'1'`; não pode depender de `o_halt` |
| `i_cmd_tog` | entrada | 1 | alternância que pede um comando |
| `o_done_tog` | saída | 1 | alternância que confirma o comando |
| `i_op` | entrada | 4 | código do comando |
| `i_addr` | entrada | 24 | índice de palavra do comando |
| `i_data` | entrada | 32 | dado de escrita |
| `o_rsp_addr` | saída | 24 | índice da última leitura ou contagem de escritas |
| `o_rsp_data` | saída | 32 | dado da última leitura ou soma de verificação |
| `o_rsp_status` | saída | 8 | bit 0 núcleo parado, bit 1 pedido recusado |
| `o_halt` | saída | 1 | núcleo parado, para ligar ao reset do núcleo |
| `i_mem_address` | entrada | `addr_width` | índice de palavra pedido pelo estágio MEM |
| `i_mem_rden` | entrada | 1 | habilita de leitura do estágio MEM |
| `o_address_b` | saída | `addr_width` | índice de palavra da porta B da FLASH |
| `o_rden_b` | saída | 1 | habilita de leitura da porta B |
| `o_wren_b` | saída | 1 | habilita de escrita da porta B |
| `o_data_b` | saída | 32 | dado de escrita da porta B |
| `i_q_b` | entrada | 32 | palavra lida pela porta B |

## 3. Protocolo do hospedeiro

A instância do Virtual JTAG tem um registrador de instrução de 2 bits.

| Instrução | Registrador | Uso |
| ---: | :--- | :--- |
| 1 | CMD, 64 bits | um comando por deslocamento |
| 2 | STREAM, comprimento livre | um bit de início e, depois dele, uma palavra por 32 bits deslocados, escrita no cursor |
| outra | bypass, 1 bit | não envia nada |

### 3.1. Registrador CMD

| Sentido | Bits | Campo | Significado |
| :--- | :--- | :--- | :--- |
| entra | 63 a 60 | op | comando |
| entra | 55 a 32 | addr | índice de palavra |
| entra | 31 a 0 | data | dado de escrita |
| sai | 63 a 56 | status | tabela abaixo |
| sai | 55 a 32 | addr | índice da última leitura ou contagem de escritas |
| sai | 31 a 0 | data | dado da última leitura ou soma de verificação |

| Bit do status | Significado |
| ---: | :--- |
| 0 | ocupado: o comando anterior não terminou, e `addr` e `data` ainda não valem |
| 1 | parado: o núcleo está parado e a porta B é do carregador |
| 2 | recusado: um pedido chegou com o núcleo em execução (limpo pela próxima parada) |
| 3 | sobrecarga: uma palavra ou um comando chegou com o carregador ocupado e foi descartado |

O comando sai quando o deslocamento termina. O status de um comando só está atualizado alguns clocks da JTAG depois do envio, então o primeiro deslocamento após um comando ainda pode mostrar ocupado e o seguinte não.

### 3.2. Comandos

| op | Nome | Efeito |
| ---: | :--- | :--- |
| 0 | status | Não envia nada, só lê o status |
| 1 | parar | Para o núcleo, zera a soma de verificação e a contagem |
| 2 | liberar | Libera o núcleo, que reinicia pela BOOT_MEMORY |
| 3 | escrever | Escreve `data` na palavra `addr`, e o cursor passa a `addr + 1` |
| 4 | ler | Lê a palavra `addr`, e o cursor passa a `addr + 1` |
| 5 | resumo | Devolve a soma de verificação em `data` e a quantidade de palavras escritas em `addr` |
| 6 | cursor | Posiciona o cursor do STREAM em `addr` |

### 3.3. Soma de verificação

A cada escrita o carregador acumula o dado e o índice da palavra.

$$\text{soma} = \sum_{i} \left( \text{dado}_i + \text{endereço}_i \right) \bmod 2^{32}$$

O hospedeiro calcula a mesma soma sobre a imagem que enviou e compara com a do comando 5 e com a contagem. Uma palavra perdida, repetida ou fora de lugar muda a soma.

### 3.4. Registrador STREAM

Uma varredura de $32N + 1$ bits escreve $N$ palavras seguidas, a partir do cursor, que avança a cada palavra. O primeiro bit é o bit de início, de valor 1, e as palavras vêm depois dele, a primeira nos bits menos significativos. O hospedeiro envia uma imagem inteira numa só varredura, sem uma varredura por palavra. Os bits antes do bit de início e os que não completam uma palavra são descartados, então o quadro não depende dos clocks que o hub do Virtual JTAG põe entre os sinais de estado e o dado. Uma palavra que chega com o carregador ocupado é descartada e acende o bit de sobrecarga, o que só acontece se o clock do carregador for lento demais para o clock da JTAG.

## 4. Passo a passo de uma carga

1. O hospedeiro envia o comando 1, e o núcleo para.
2. Envia o comando 6 com o índice da primeira palavra e uma varredura do STREAM com a imagem.
3. Envia o comando 5 e compara a soma e a contagem com as da imagem.
4. Envia o comando 2, e o núcleo reinicia pela BOOT_MEMORY e executa o teste novo.

## 5. Comportamento

### 5.1. Sincronização

O comando atravessa de `i_tck` para `i_clk` pela inversão de `i_cmd_tog`, sincronizada por uma instância `u_sync_cmd` do `synchronizer` de dois estágios, mais um registrador que guarda o valor anterior e mostra a inversão (três registradores em série ao todo). O sincronizador amostra a cada borda de `i_clk`, também durante o reset, e o reset espera que o toggle esteja parado, o que vale com o reset mais longo que três bordas de `i_clk`. `i_op`, `i_addr` e `i_data` ficam estáveis da inversão até a resposta, que é uma inversão de `o_done_tog`. `o_rsp_*` ficam estáveis desde antes dessa inversão até o próximo comando aceito.

### 5.2. Temporização das portas

| Comando | Ciclos de `i_clk` entre a aceitação e a resposta |
| :--- | :--- |
| escrever | 1 (a escrita ocorre no ciclo seguinte à aceitação) |
| ler | 3 (endereço aplicado, captura na porta B, palavra na saída) |
| os demais | 1 |

## 6. Verificação

A entrada `FlashLoader` de `tests/python/tests.json` roda `tests/python/unittests/rom/flash_loader.py` sobre o topo de simulação `flash_system`, que liga o modelo [flash_simulation](flash_simulation.md), o carregador e o [flash_jtag_core](flash_jtag_core.md) como no topo da FPGA. Os testes cobrem a leitura da mesma cópia pelas duas portas, a escrita e a leitura de volta com o núcleo parado, a recusa de escrita com o núcleo em execução, o STREAM com cursor, a soma de verificação, a sobrecarga e a posse da porta B.

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
