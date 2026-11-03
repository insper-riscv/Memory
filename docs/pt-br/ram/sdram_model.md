# sdram_model

## 1. Função do componente no SoC

Modelo comportamental da SDRAM SDR de 32M x 16 da placa, usado só em simulação. Guarda os dados escritos numa tabela esparsa e faz a simulação falhar (`severity failure`) quando o controlador quebra uma regra do chip. Um teste que termina sem falha prova, portanto, que o controlador cumpre os tempos de [sdram_pkg](sdram_pkg.md), a ordem dos comandos, a energização, o registrador de modo e o intervalo de refresh. O modelo também oferece portas de depuração que leem e corrompem a memória armazenada.

## 2. Interface

### 2.1. Generics

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | :--- | :--- |
| `tck_ps` | natural | `T_CK_PS` (7000) | período do clock em ps, convertido em tempo de simulação |
| `init_file` | string | vazio | arquivo com a imagem inicial do chip, vazio para o chip zerado |

### 2.2. Portas do chip

| Porta | Dir. | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_clk` | entrada | 1 | clock do chip |
| `i_cke` | entrada | 1 | habilita de clock, e sem ele o comando é ignorado |
| `i_cs_n` | entrada | 1 | seleção do chip, ativa em `'0'` |
| `i_ras_n` | entrada | 1 | strobe de endereço de linha, ativo em `'0'` |
| `i_cas_n` | entrada | 1 | strobe de endereço de coluna, ativo em `'0'` |
| `i_we_n` | entrada | 1 | habilita de escrita, ativo em `'0'` |
| `i_ba` | entrada | 2 | banco |
| `i_a` | entrada | 13 | endereço de linha ou de coluna |
| `i_dqm` | entrada | 2 | máscara de bytes dos dados, que mascara em `'1'` |
| `io_dq` | bidirecional | 16 | pinos de dados DQ |
| `i_reinit` | entrada | 1 | em `'1'` enquanto o controlador está em reset, e reinicia a sequência de energização do chip |

### 2.3. Portas de depuração

| Porta | Dir. | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_dbg_word_addr` | entrada | 24 | endereço de palavra lido direto da memória armazenada |
| `o_dbg_word_data` | saída | 32 | palavra armazenada nesse endereço, registrada no clock do chip |
| `i_dbg_flip` | entrada | 1 | uma borda de subida inverte um bit de uma palavra armazenada |
| `i_dbg_flip_addr` | entrada | 24 | endereço de palavra cujo bit é invertido |
| `i_dbg_flip_bit` | entrada | 5 | posição do bit invertido na palavra |
| `o_dbg_refreshes` | saída | 32 | quantidade de comandos AUTO REFRESH recebidos |
| `o_dbg_init_ok` | saída | 1 | `'1'` quando o registrador de modo foi carregado depois de uma sequência de energização aceita |

## 3. Comportamento

### 3.1. Armazenamento

A memória é uma tabela esparsa de meias-palavras de 16 bits, com 65536 baldes de listas encadeadas. A chave de cada meia-palavra é

$$
k = (\text{linha} \cdot 4 + \text{banco}) \cdot 1024 + \text{coluna}
$$

e uma posição nunca escrita vale zero. A palavra de endereço $w$ ocupa as meias-palavras $2w$ (bits 15 a 0) e $2w+1$ (bits 31 a 16). Na escrita, um byte só é gravado quando o seu bit de `i_dqm` vale `'0'`.

### 3.2. Imagem inicial

Com `init_file` não vazio, o modelo lê o arquivo no instante zero. Cada linha com ao menos 8 caracteres é uma palavra de 32 bits em hexadecimal, gravada a partir do endereço de palavra 0. A imagem representa o hospedeiro que carregou o chip pela porta de depuração antes de o núcleo ser liberado.

### 3.3. Comandos

O chip só reconhece um comando quando `i_cke` vale `'1'`, `i_cs_n` vale `'0'` e `i_reinit` vale `'0'`. A última condição faz o modelo ignorar o comando que o controlador ainda leva nos registradores na primeira borda de um reset, como detalha [SDRAM_MODEL_RESET_COMMAND.md](../bugs/SDRAM_MODEL_RESET_COMMAND.md).

Em `i_reinit` igual a `'1'`, o modelo reinicia o instante de energização, esquece o PRECHARGE e os refreshes vistos, fecha todos os bancos e zera a verificação de refresh.

### 3.4. Regras verificadas

Cada violação abaixo falha a simulação.

| Comando | Regra |
| :--- | :--- |
| primeiro comando | só depois de `T_INIT_PS` desde o início da energização |
| LOAD MODE REGISTER | depois de um PRECHARGE de todos os bancos e de pelo menos dois refreshes, fora do intervalo de um refresh, com o valor `MODE_REG` |
| PRECHARGE | fora do intervalo de um refresh; um banco aberto só fecha depois de `T_RAS_PS` e, no PRECHARGE de um banco, de `T_WR_PS` desde o último dado de escrita |
| AUTO REFRESH | depois de um PRECHARGE de todos os bancos, com todos os bancos fechados e fora do tempo de PRECHARGE, e fora do intervalo de outro refresh |
| ACTIVE | depois do registrador de modo, depois de `T_MRD_CK` clocks, fora de um refresh, com o banco fechado, depois de `T_RP_PS` do fechamento do banco e de `T_RC_PS` do ACTIVE anterior do mesmo banco |
| READ ou WRITE | depois do registrador de modo, com o banco aberto, depois de `T_RCD_PS` do ACTIVE, sem sobrepor a rajada anterior e com coluna par |
| refresh periódico | depois do registrador de modo, dois refreshes nunca ficam mais de `T_REFI_PS` afastados |

O modelo não verifica o intervalo entre ACTIVE de bancos diferentes. O controlador mantém uma linha aberta por vez, e o tempo $t_{RRD}$ não se aplica.

### 3.5. Leitura e escrita

Um READ põe a meia-palavra de endereço da coluna e a seguinte num pipeline de leitura. O primeiro beat aparece nos pinos DQ $CL$ bordas depois da borda em que o chip amostra o comando, e o segundo beat uma borda depois. Fora desses dois clocks o modelo solta os pinos (alta impedância).

Num WRITE a primeira meia-palavra é gravada na borda do comando e a segunda na borda seguinte, cada uma com a máscara de bytes daquele clock.

Com o bit 10 do endereço em `'1'`, o comando faz auto-precharge. O banco fecha e só aceita ACTIVE depois do instante

$$
t_{idle} = t_{pre} + T_{RP}, \quad t_{pre} = \max\left(t_{cmd} + 2\,T_{CK},\; t_{act} + T_{RAS}\right)
$$

para o READ. No WRITE, $t_{cmd} + 2\,T_{CK}$ é trocado por $t_{cmd} + T_{CK} + T_{WR}$. Cada comando de rajada ocupa o barramento por $2\,T_{CK}$, então o segundo READ de uma linha precisa vir dois clocks depois do primeiro.

### 3.6. Depuração

`o_dbg_word_data` entrega, um clock depois de `i_dbg_word_addr`, a palavra armazenada. Um pulso de subida em `i_dbg_flip` inverte o bit `i_dbg_flip_bit` da palavra em `i_dbg_flip_addr`, e um segundo pulso desfaz a inversão. A inversão serve para provar que uma verificação nota uma memória corrompida.

## 4. Integração

| Instância | Onde | Ligação |
| :--- | :--- | :--- |
| `u_chip` em `sdram_system` | topo de simulação do subsistema | `tck_ps` e `init_file` vindos dos generics do topo, `i_reinit` ligado ao reset do lado do controlador, portas de depuração levadas à porta do topo |
| `u_chip` em `teste_sdram_system` | topo de simulação do autoteste | generics padrão e `i_reinit` ligado ao reset do autoteste |

O topo une os pinos DQ. O [sdram_ctrl](sdram_ctrl.md) os dirige quando `o_dram_dq_oe` vale `'1'`, e o modelo dirige nos demais casos. O topo do subsistema é por sua vez usado pelos topos da cache de dados e do escravo AXI.

## 5. Verificação

O modelo não tem teste dedicado. Ele é o juiz dos testes de controlador, e as portas de depuração são o meio de conferir o conteúdo do chip.

| Entrada de `tests.json` | Módulo de teste | Uso do modelo |
| :--- | :--- | :--- |
| `SdramSystem` | [sdram_system.py](../../../tests/python/unittests/ram/sdram_system.py) | confere cada palavra lida com o conteúdo do chip, exige `o_dbg_init_ok` e ao menos 8 refreshes após a energização, conta refreshes em 60 µs e usa `i_dbg_flip` para provar que um bit invertido aparece na leitura |
| `SdramBist` e `SdramBistRegisteredPins` | [sdram_bist.py](../../../tests/python/unittests/ram/sdram_bist.py) | o autoteste sobre o modelo, com o controle de um bit invertido no chip |
| `SdramDebugPort` | [sdram_debug_port.py](../../../tests/python/unittests/ram/sdram_debug_port.py) | leituras e escritas do hospedeiro conferidas no chip |
| `DataCache`, `DataCacheWriteThrough` e `AxiSdramSlave` | [axi_sdram_slave.py](../../../tests/python/unittests/barramento/axi_sdram_slave.py) e os módulos da cache | conferência do conteúdo do chip após acessos de linha e de palavra |

Nenhum teste preenche o chip por `init_file`.

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
