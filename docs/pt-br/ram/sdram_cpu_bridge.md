# sdram_cpu_bridge

## 1. Função do componente no SoC

Ponte entre o estágio de memória do núcleo, no clock do núcleo, e o pedido por alternância do controlador da SDRAM, em outro clock. A ponte recebe um acesso de palavra ou de linha, guarda os campos num registrador, pede o acesso por uma inversão de toggle e devolve ao núcleo um sinal de pronto que permanece em nível alto até o pipeline avançar. O dado lido só muda na borda em que o pipeline avança, porque o load que ainda está no estágio de write-back lê o valor anterior até lá.

A mesma ponte serve ao caminho de dados e ao de instruções, em duas instâncias. O acesso de linha move as quatro palavras de uma linha de cache, como descrito em [sdram_line.md](sdram_line.md). A seleção de bytes de um load e a geração das habilitações de um store acontecem no núcleo, como explica [sdram_subword_read.md](sdram_subword_read.md).

## 2. Interface

### 2.1. Lado do núcleo

| Porta | Dir. | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_clk_cpu` | entrada | 1 | clock do núcleo |
| `i_rst_cpu` | entrada | 1 | reset do lado do núcleo, ativo em `'1'` |
| `i_addr` | entrada | 32 | endereço de byte do acesso |
| `i_wdata` | entrada | 32 | dado de escrita (palavra 0) |
| `i_byteena` | entrada | 4 | habilita de bytes da escrita, um bit por byte |
| `i_rden` | entrada | 1 | pedido de leitura |
| `i_wren` | entrada | 1 | pedido de escrita |
| `i_mem_advance` | entrada | 1 | o pipeline avançou neste ciclo, e o acesso em andamento pode ser concluído |
| `o_ready` | saída | 1 | acesso concluído, com o dado lido válido |
| `o_rdata` | saída | 32 | dado lido (palavra 0) |
| `i_line` | entrada | 1 | acesso de linha de quatro palavras (padrão `'0'`) |
| `i_wdata_x` | entrada | 96 | palavras 1 a 3 do dado de escrita, a palavra 1 nos bits mais baixos (padrão zero) |
| `i_byteena_x` | entrada | 12 | habilita de bytes das palavras 1 a 3 (padrão zero) |
| `o_rdata_x` | saída | 96 | palavras 1 a 3 do dado lido |

### 2.2. Lado do controlador

Os generics da ponte descrevem o chip e a janela da região dentro dele.

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | :--- | :--- |
| `addr_bits` | natural | 24 | largura do endereço de palavra de 32 bits do chip, 25 com o chip de 32 bits da DE2-115 |
| `fixed_msb` | `std_logic` | `'U'` | `'0'` ou `'1'` força o bit mais significativo do endereço de palavra do chip, e a ponte só alcança a metade escolhida; qualquer outro valor deixa o bit como veio do núcleo |
| `word_offset` | natural | 0 | deslocamento constante, em palavras de 32 bits, somado ao endereço depois do bit fixo, módulo $2^{\text{addr\_bits}}$; 0 não gera somador |

| Porta | Dir. | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `o_req_tog` | saída | 1 | cada inversão é um pedido novo |
| `i_ack_tog` | entrada | 1 | toggle de confirmação do controlador, sincronizado dentro da ponte |
| `i_init_done` | entrada | 1 | a inicialização da SDRAM terminou, sincronizada dentro da ponte |
| `o_c_we` | saída | 1 | escrita (`'1'`) ou leitura (`'0'`) |
| `o_c_addr` | saída | `addr_bits` | endereço de palavra no chip: os bits `addr_bits` + 1 a 2 de `i_addr` com a janela da seção 3.2 |
| `o_c_wdata` | saída | 32 | dado de escrita |
| `o_c_be` | saída | 4 | habilita de bytes |
| `i_c_rdata` | entrada | 32 | dado lido |
| `o_c_line` | saída | 1 | acesso de linha |
| `o_c_wdata_x` | saída | 96 | palavras 1 a 3 do dado de escrita |
| `o_c_be_x` | saída | 12 | habilita de bytes das palavras 1 a 3 |
| `i_c_rdata_x` | entrada | 96 | palavras 1 a 3 do dado lido |

## 3. Comportamento

### 3.1. Máquina de estados

| Estado | Ação | Saída para o estado seguinte |
| :--- | :--- | :--- |
| `ST_IDLE` | com `i_rden` ou `i_wren` em `'1'` e a inicialização sincronizada em `'1'`, copia os campos do acesso para os registradores de saída, inverte `o_req_tog` e vai para `ST_WAIT` | pedido aceito |
| `ST_WAIT` | espera o toggle de confirmação sincronizado igualar `o_req_tog` e guarda o dado lido | confirmação recebida |
| `ST_DONE` | mantém `o_ready` em `'1'` até `i_mem_advance` | avanço do pipeline, que volta a `ST_IDLE` |

No avanço de uma leitura o dado guardado vai para `o_rdata` e `o_rdata_x`. No avanço de uma escrita essas saídas não mudam. Se `i_rden` e `i_wren` valem `'1'` juntos, o acesso é uma escrita. Depois do avanço a ponte volta ao estado livre e aceita, na borda seguinte, o acesso que estiver nas entradas.

### 3.2. Endereço e janela no chip

O endereço enviado ao controlador é o endereço de palavra do núcleo, com o bit mais significativo forçado por `fixed_msb` e somado a `word_offset`:

$$
a = \text{i\_addr}[\text{addr\_bits}+1:2]
$$

$$
\text{o\_c\_addr} = \left(a \text{ com o bit mais significativo igual a } \text{fixed\_msb} + \text{word\_offset}\right) \bmod 2^{\text{addr\_bits}}
$$

Com os padrões (`'U'` e 0) vale $\text{o\_c\_addr} = \text{i\_addr}[\text{addr\_bits}+1:2]$, sem nenhuma lógica no caminho do endereço. O tamanho de cada região no chip vem do mapa da plataforma, e uma mesma SDRAM serve duas regiões de qualquer tamanho. Na SDRAM de 64 MiB da DE0-CV (1 MiB são $2^{18}$ palavras), a região de instruções ocupa o início do chip, com o mesmo endereço que o núcleo usa, e a de dados vem depois dela:

| Divisão instruções / dados | Ponte de instruções | Ponte de dados |
| :--- | :--- | :--- |
| 32 MiB / 32 MiB | `fixed_msb` `'0'`, `word_offset` 0 | `fixed_msb` `'1'`, `word_offset` 0 |
| 16 MiB / 48 MiB | padrões | `word_offset` 4194304 (16 MiB) |
| 48 MiB / 16 MiB | padrões | `word_offset` 12582912 (48 MiB) |

Com `fixed_msb` forçado a ponte só alcança a metade escolhida, por construção, qualquer que seja o endereço do núcleo. Com `word_offset` a janela vale enquanto o roteador de região entrega à ponte só endereços da sua região.

Os dois bits baixos do endereço do núcleo escolhem o byte dentro da palavra e não vão ao controlador. Os bits acima de `addr_bits + 1` não são usados: com `addr_bits` igual a 24 (padrão), o endereço de palavra cobre os 64 MB do chip, e com 25 cobre os 128 MiB dos dois chips da DE2-115. Num acesso de linha, o controlador ignora ainda os dois bits baixos do endereço de palavra e usa a linha de 16 bytes alinhada que contém o endereço.

### 3.3. Cruzamento de clocks

O toggle de confirmação e o sinal de fim de inicialização atravessam, cada um, um sincronizador de dois flip-flops. Os barramentos de pedido mudam na mesma borda que inverte `o_req_tog` e ficam estáveis até a confirmação. O controlador só os amostra depois de ver a inversão, então eles precisam apenas de uma restrição de atraso menor que a latência do sincronizador, e não de sincronizadores próprios.

### 3.4. Latência

As contagens usam $e$ como a primeira borda do clock do controlador que amostra a inversão de `o_req_tog`, com o controlador livre e sem refresh pendente. O árbitro escolhe o pedido em $e+2$, o controlador decide o ACTIVE em $e+3$, e o árbitro confirma ao mestre depois da resposta do controlador.

| Acesso | Borda em que o árbitro inverte a confirmação, contada desde $e$ |
| :--- | ---: |
| leitura de palavra | 13 |
| escrita de palavra | 8 |
| leitura de linha | 19 |
| escrita de linha | 14 |

Depois disso a confirmação atravessa o sincronizador de volta ao clock do núcleo, e a ponte ainda gasta uma borda do núcleo para mudar de `ST_WAIT` para `ST_DONE`. Os valores de cada acesso do controlador estão em [sdram_ctrl](sdram_ctrl.md) e os do árbitro em [sdram_arbiter](sdram_arbiter.md).

## 4. Integração

| Instância | Mestre do árbitro | Observações |
| :--- | :--- | :--- |
| `u_bridge` em `sdram_system` | A, o caminho de dados | leitura, escrita e linha completas |
| `u_ibridge` em `sdram_system` | I, o caminho de instruções | `i_wren` e os dados de escrita fixos em zero, por isso só lê |

As duas instâncias de `sdram_system` recebem a janela por generics próprios (`data_fixed_msb`, `data_word_offset`, `ins_fixed_msb` e `ins_word_offset`).

A ponte e o árbitro ficam no caminho do barramento. A memória externa (SDRAM, SRAM e FLASH externa real) é lida pelo núcleo através do barramento, o que o mapa da plataforma declara com `on_bus: true`, e só a memória de porta dedicada (`on_bus: false`) é lida direto da porta do núcleo sem passar por elas. A ponte de instruções não pressupõe o que há além dela: atende a leitura de instruções e de constantes da face da FLASH e qualquer outro mestre de leitura que siga o contrato da seção 1, como a porta de instruções que alcança a RAM de dados.

As outras pontes do repositório seguem o mesmo contrato do lado do núcleo, entre elas a do mestre AXI, a cache de dados e o modelo de RAM externa.

O sincronizador vem de Common-Components (`src/common/src/synchronizer.vhd`). O fim da inicialização usado para liberar acessos é o `o_init_done` do controlador.

## 5. Verificação

| Entrada de `tests.json` | Módulo de teste | O que exercita na ponte |
| :--- | :--- | :--- |
| `SdramSystem` | [sdram_system.py](../../../tests/python/unittests/ram/sdram_system.py) | escrita e leitura com todas as máscaras de bytes, dado lido que só muda quando o pipeline avança (pipeline parado por ciclos extras depois do pronto), clocks do núcleo e do controlador em relações diferentes (14 ns, 53 ns com deslocamento e 100 ns com deslocamento, contra 7 ns), limites de latência em ciclos do núcleo, acessos de linha e mistura de linhas e palavras |
| `SdramDebugPort` | [sdram_debug_port.py](../../../tests/python/unittests/ram/sdram_debug_port.py) | acessos do núcleo concorrentes com o hospedeiro, com limite de espera |
| `DataCache`, `DataCacheWriteThrough` e `AxiSdramSlave` | [axi_sdram_slave.py](../../../tests/python/unittests/barramento/axi_sdram_slave.py) e os módulos da cache | a ponte atrás da cache e do escravo AXI, com rajadas de linha e de palavra |
| `SdramCpuBridgeWindowNeutral`, `SdramCpuBridgeWindowMsb0`, `SdramCpuBridgeWindowMsb1`, `SdramCpuBridgeWindow16`, `SdramCpuBridgeWindow48` e `SdramCpuBridgeWindowMsb1Offset` | [sdram_cpu_bridge_window.py](../../../tests/python/unittests/ram/sdram_cpu_bridge_window.py) | o endereço que o controlador recebe para cada combinação de `fixed_msb` e `word_offset`, em leitura, escrita e linha |
| `SdramWindow` | [sdram_window.py](../../../tests/python/unittests/ram/sdram_window.py) | as duas pontes no `sdram_system` com o controlador e o modelo do chip: a de dados escreve na metade alta, a de instruções lê só a metade baixa, e o hospedeiro vê o chip inteiro |

A prova formal de `formal/sdram_cpu_bridge` verifica o endereço com os padrões e com uma janela (`fixed_msb` `'1'` e `word_offset` 16), e os mutantes dessa janela (bit fixo solto, deslocamento perdido e deslocamento errado) a reprovam.

A instância de instruções usa a mesma descrição da instância de dados, e só o teste de janela a dirige.

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
