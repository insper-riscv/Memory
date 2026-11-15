# Protocolo JTAG da depuração da SDRAM

## 1. Escopo

Este documento define o que um hospedeiro envia e recebe pela instância do Virtual JTAG da depuração da SDRAM, com precisão suficiente para escrever uma ferramenta de carga e de despejo. Os blocos de hardware que o realizam estão em [sdram_jtag_core.md](sdram_jtag_core.md) e [sdram_dbg_master.md](sdram_dbg_master.md), e a visão geral em [sdram_debug.md](sdram_debug.md).

Todos os campos são enviados com o bit menos significativo primeiro, como um deslocamento do registrador de dados de uma instância do Virtual JTAG. Um endereço é sempre um endereço de palavra de 32 bits do chip (o endereço de byte dividido por 4), com 24 bits num chip de 64 MiB e 25 bits num chip de 128 MiB.

## 2. Instruções

A instância tem um registrador de instrução de 2 bits.

| Instrução | Registrador de dados | Comprimento do deslocamento | Uso |
| ---: | :--- | :--- | :--- |
| 0, e as não listadas | bypass | 1 bit | nenhum, não envia nada à memória |
| 1 | DEBUG | 64 bits | um comando por deslocamento, e o estado do anterior na saída |
| 2 | rajada de escrita | $32 \cdot N$ bits, $N$ de 1 a 128 | escreve $N$ palavras consecutivas na SDRAM |
| 3 | rajada de leitura | $64 + 32 \cdot N$ bits, $N$ de 1 a 128 | devolve $N$ palavras consecutivas da SDRAM |

Um deslocamento completo é Capture-DR, os bits de Shift-DR e Update-DR. A instrução é carregada antes, num Update-IR, e vale até a próxima.

## 3. O registrador DEBUG

### 3.1. Entrada e saída

| Sentido | Bits | Campo | Significado |
| :--- | :--- | :--- | :--- |
| entra | 63 a 60 | `op` | comando da seção 3.3; com o chip de 128 MiB, o bit 63 é o bit 24 do endereço |
| entra | 59 a 56 | `be` | habilita de bytes de uma escrita, ou o subcomando do comando 7 nos bits 58 a 56 |
| entra | 55 a 32 | `addr` | endereço de palavra, os 24 bits baixos |
| entra | 31 a 0 | `data` | valor a escrever, contagem de um preenchimento ou de um CRC, ou o nível do hold |
| sai | 63 a 56 | `status` | tabela da seção 3.2 |
| sai | 55 a 32 | `word` | última palavra acessada |
| sai | 31 a 0 | `data` | dado da última leitura, ou o CRC depois de um comando 7 com subcomando 1 |

### 3.2. Status

| Bit | Nome | Significado |
| ---: | :--- | :--- |
| 0 | `busy` | o comando anterior não terminou, então `word` e `data` ainda não valem |
| 1 | `error` | o controlador não respondeu ao comando anterior |
| 2 | `initialized` | a SDRAM terminou a sequência de energização |
| 3 | `overrun` | um comando chegou com a porta ocupada e foi descartado |
| 4 | `stream error` | uma palavra de uma rajada chegou tarde ou foi perdida (seção 5.3) |
| 5 | `hold` | o mestre de depuração mantém o núcleo parado |
| 7 e 6 | nenhum | valem 0 |

`overrun` fica em 1 até o próximo comando aceito. `stream error` fica em 1 até o próximo comando aceito, até um comando seek ou até o início da rajada seguinte (o quadro dessa rajada ainda mostra o valor antigo).

### 3.3. Comandos

| `op` | Nome | Efeito |
| ---: | :--- | :--- |
| 0 | status | não envia nada, só lê o status |
| 1 | read | lê a palavra em `addr` |
| 2 | write | escreve `data` na palavra em `addr`, com os bytes dados por `be` |
| 3 | fill | escreve `data` (todos os bytes) em $\text{count}$ palavras a partir de `addr` |
| 4 | set count | $\text{count} = \text{data}[24:0]$, até $2^{24}$ palavras; vale 1 depois do reset |
| 5 | read next | lê a palavra seguinte à última acessada |
| 6 | write next | escreve `data` na palavra seguinte à última acessada, com os bytes dados por `be` |
| 7 | control | subcomando nos bits 58 a 56 de `be`, tabela abaixo |

| Subcomando de `op` 7 | Nome | Efeito |
| ---: | :--- | :--- |
| 0 | hold | o hold do núcleo recebe `data[0]`; com 1, o SoC mantém o núcleo em reset |
| 1 | crc32 | lê $\text{count}$ palavras a partir de `addr`, com $\text{count} = \text{data}[24:0]$, e devolve o CRC-32 delas |
| 2 | seek | aponta o ponteiro das rajadas para `addr` (com o bit 24 vindo do bit 63) |
| 3 a 7 | nenhum | só respondem |

Um comando é aceito quando o deslocamento termina (Update-DR) com `op` diferente de 0 e `busy` igual a 0. Com `busy` igual a 1, o comando é descartado e `overrun` sobe. O seek não passa pelo mestre de depuração e é aceito mesmo com `busy` igual a 1.

### 3.4. Esperar o fim de um comando

O status de um comando só está atualizado alguns clocks do JTAG depois do envio. O hospedeiro envia deslocamentos com `op` 0 até `busy` valer 0 e usa `word` e `data` desse deslocamento.

## 4. Hold e CRC

### 4.1. Hold

O subcomando 0 do comando 7 liga e desliga `o_core_hold`, a saída do mestre de depuração que o topo leva ao reset do núcleo. O valor persiste entre comandos e volta a 0 no reset do mestre de depuração. O bit 5 do status mostra o valor atual.

### 4.2. CRC

O subcomando 1 do comando 7 calcula o CRC-32 das palavras, no clock do controlador, sem tráfego no JTAG. Cada palavra entra com os seus bytes do menor para o maior endereço (palavra little-endian), o valor inicial e a inversão final são todos 1 e o polinômio refletido é $\texttt{0xEDB88320}$, o que dá o mesmo valor que `zlib.crc32` sobre os bytes da imagem. Com contagem zero o resultado é 0. O resultado vem no campo `data` do deslocamento seguinte ao término do comando, e `word` traz a última palavra lida.

O custo é uma leitura do chip por palavra.

## 5. Rajadas

Uma rajada move até 128 palavras (4096 bits) em um só deslocamento, sem um comando por palavra nem consulta de status no meio. As rajadas usam o ponteiro de rajada do núcleo JTAG, um endereço de palavra de 25 bits que o seek aponta e que avança uma palavra por palavra movida.

### 5.1. Rajada de escrita (instrução 2)

1. O hospedeiro envia seek com o endereço da primeira palavra.
2. Carrega a instrução 2.
3. Desloca $32 \cdot N$ bits de dados, a primeira palavra primeiro, cada palavra com o bit menos significativo primeiro. A cada 32 bits, a placa escreve a palavra no ponteiro e o avança.
4. Os primeiros 64 bits que saem são o quadro de status da seção 3.1, com `word` e `data` do último comando. Com menos de 64 bits deslocados o quadro sai truncado.

Palavras além da 128ª num mesmo deslocamento são ignoradas, e bits que não completam uma palavra não escrevem nada. Depois do deslocamento, o hospedeiro volta à instrução 1 e espera `busy` valer 0 antes de enviar um comando, porque a última palavra ainda pode estar em escrita.

### 5.2. Rajada de leitura (instrução 3)

1. O hospedeiro envia seek com o endereço da primeira palavra.
2. Carrega a instrução 3.
3. Desloca $64 + 32 \cdot N$ bits (o que entra é ignorado). Os primeiros 64 bits que saem são o quadro de status, e depois saem as $N$ palavras, a primeira palavra primeiro, cada uma com o bit menos significativo primeiro.

A primeira palavra é lida durante o quadro de status e cada palavra seguinte é pedida quando a anterior vai para a saída. O ponteiro avança quando o primeiro bit de uma palavra sai, então só as palavras deslocadas contam, e uma rajada seguinte, sem novo seek, continua na palavra seguinte à última deslocada. A placa lê uma palavra além da última entregue, sem entregá-la e sem mover o ponteiro.

### 5.3. Tempo e erro de rajada

Cada palavra de uma rajada é um acesso ao chip por vez, pedido assim que a anterior termina, e o acesso tem de terminar antes de a palavra seguinte ser pedida, 32 clocks do JTAG depois. Com o clock do JTAG de $f_{tck}$ e o acesso de $t_{acc}$, a condição é

$$
t_{acc} < \frac{32}{f_{tck}}
$$

Com o clock de 24 MHz do USB-Blaster são 1,33 microssegundo, contra o acesso do mestre de depuração, de cerca de 15 clocks do controlador, mais a espera por um acesso de cada um dos outros mestres do árbitro. Se a condição falhar, o bit 4 do status sobe e a palavra é perdida numa escrita ou inválida numa leitura.

O hospedeiro confere o bit 4 depois de toda rajada (o status de um deslocamento com `op` 0). Com o bit em 1, refaz a rajada desde o seek do seu endereço inicial, o que é seguro, porque escrever as mesmas palavras de novo e ler de novo não têm efeito colateral.

## 6. Receitas do hospedeiro

### 6.1. Carregar uma imagem

1. Seek no endereço inicial e subcomando hold com `data` igual a 1 (o núcleo para).
2. Rajadas de escrita de até 128 palavras, cada uma seguida de uma espera por `busy` igual a 0 e da conferência do bit 4.
3. CRC com o endereço inicial e a quantidade de palavras, comparado com o CRC calculado no hospedeiro. A imagem só vale se forem iguais.
4. Subcomando hold com `data` igual a 0.

### 6.2. Despejar uma região

1. Seek no endereço inicial.
2. Rajadas de leitura de até 128 palavras, cada uma conferida pelo bit 4 do quadro.
3. Opcionalmente, o CRC da região na placa, para conferir o que foi lido.

O despejo é seguro com o núcleo rodando se a cache de dados escreve através da SDRAM. A escrita de uma região que o núcleo executa exige o hold da seção 4.1.

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
