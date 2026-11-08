# Cruzamento de domínios de clock entre o núcleo e a SDRAM

## 1. Os dois domínios

O núcleo e o controlador da SDRAM rodam em clocks sem relação de fase. Cada acesso à memória atravessa a fronteira duas vezes, uma no pedido e outra na resposta.

| Domínio | Clock | Blocos |
| :--- | :--- | :--- |
| Núcleo | `i_clk_cpu` | `sdram_cpu_bridge` (uma instância para dados e outra para instruções) |
| Memória | `i_clk_mem` | `sdram_arbiter`, `sdram_ctrl`, mestre de debug e modelo do chip |

A fronteira fica entre a ponte e o árbitro. O árbitro e o controlador estão no mesmo clock, então o controlador usa o toggle do árbitro direto, com o parâmetro `sync_req` em `false`.

## 2. Mecanismo

Um sinal de 1 bit que muda de nível pode atravessar com segurança por uma cadeia de flip-flops em série. Um barramento largo não pode, porque cada bit seria amostrado em um instante diferente. O cruzamento combina os dois casos.

| Sinal | Largura | Origem | Destino | Como atravessa |
| :--- | ---: | :--- | :--- | :--- |
| `req_tog` | 1 | ponte | árbitro | sincronizador de dois flip-flops |
| `ack_tog` | 1 | árbitro | ponte | sincronizador de dois flip-flops |
| `init_done` | 1 | controlador | ponte | sincronizador de dois flip-flops |
| endereço, dado de escrita, habilita de bytes, `we`, `line`, palavras 1 a 3 | 24 + 32 + 4 + 1 + 1 + 96 + 12 | ponte | árbitro | direto, mantidos estáveis |
| dado lido, palavras 1 a 3 | 32 + 96 | árbitro | ponte | direto, mantidos estáveis |

### 2.1. Sincronizador de dois flip-flops

O primeiro flip-flop pode entrar em metaestabilidade quando a entrada muda perto da borda do clock de destino. O segundo flip-flop amostra a saída do primeiro um período depois, e só ele alimenta a lógica. Com $N$ estágios, a lógica de destino enxerga o sinal depois de $N$ bordas do clock de destino, contadas da primeira borda que captura a inversão, e a probabilidade de falha cai de forma exponencial com o tempo disponível para resolver.

A entidade `synchronizer` de Common-Components implementa a cadeia com $N$ estágios (mínimo 2) e marca os registradores para o Quartus, que os mantém sem fusão nem remoção e os inclui no relatório de MTBF. O árbitro instancia o `synchronizer` com dois estágios e um bit para cada toggle de pedido (`u_sync_a` para o mestre de dados e `u_sync_ins` para o de instruções), com o reset do árbitro ligado a `i_rst`. O `sdram_jtag_core` e o `flash_jtag_core` o instanciam, também com dois estágios, em `u_sync_done`, para a confirmação que chega a `i_tck`, e o `flash_loader` o instancia em `u_sync_cmd` para o comando que chega a `i_clk`.

### 2.2. Handshake por alternância

Cada pedido é uma inversão do nível de `req_tog`, e a resposta é uma inversão de `ack_tog`. Um acesso está em andamento quando os dois níveis diferem, e está concluído quando voltam a ser iguais.

| Situação | `req_tog` e `ack_tog` |
| :--- | :--- |
| livre | iguais |
| pedido em andamento | diferentes |
| resposta entregue | iguais de novo |

Um nível, e não um pulso, é o que garante a passagem: o toggle permanece no novo valor até a resposta, por mais lento que seja o clock de destino. Um pulso de um ciclo do núcleo poderia ser perdido por um clock de memória mais lento.

## 3. Sequência de um acesso

Os números 1 a 7 seguem a ordem temporal.

| Passo | Domínio | Ação |
| ---: | :--- | :--- |
| 1 | núcleo | a ponte, livre e com `init_done` sincronizado em `'1'`, copia endereço, dado, habilita de bytes e palavras extras para registradores de saída |
| 2 | núcleo | na mesma borda, a ponte inverte `req_tog` e entra em `ST_WAIT` |
| 3 | memória | o toggle atravessa os dois flip-flops do árbitro, que vê `req_tog` diferente de `ack_tog` |
| 4 | memória | o árbitro lê os barramentos de pedido, já estáveis, e repassa o acesso ao controlador |
| 5 | memória | o controlador move os dados, registra o dado lido e o árbitro inverte `ack_tog` |
| 6 | núcleo | `ack_tog` atravessa os dois flip-flops da ponte, que vê os toggles iguais e guarda o dado lido |
| 7 | núcleo | a ponte sobe `o_ready` e espera `i_mem_advance` para entregar o dado e voltar a `ST_IDLE` |

O primeiro estágio de cada sincronizador pode capturar a inversão na borda mais próxima ou na seguinte, então a travessia custa entre $N$ e $N+1$ bordas do clock de destino, mais uma borda para a máquina de estados agir. Os valores de ciclos por acesso estão em [sdram_cpu_bridge](sdram_cpu_bridge.md).

## 4. Por que os barramentos largos não têm sincronizador

Os bits de um barramento atravessam por caminhos de atraso diferentes, e um sincronizador por bit poderia entregar uma palavra com bits de dois valores. O protocolo evita o problema porque nenhum barramento é lido enquanto muda.

| Barramento | Quando muda | Quando é lido |
| :--- | :--- | :--- |
| pedido (ponte para árbitro) | na mesma borda do núcleo que inverte `req_tog` | depois que o árbitro vê a inversão sincronizada |
| dado lido (árbitro para ponte) | antes da inversão de `ack_tog` | depois que a ponte vê a inversão sincronizada |

Os dois barramentos ficam estáveis até o próximo pedido, que só nasce depois de a ponte ver a resposta. Para a leitura ser sempre correta, o atraso do dado precisa ser menor que a latência mínima do toggle correspondente:

$$
t_{dado} + t_{setup} < N \cdot T_{dest}
$$

com $N = 2$ nos dois sentidos. O lado que lê é o árbitro no pedido e a ponte na resposta, então $T_{dest}$ é $T_{mem}$ no pedido e $T_{cpu}$ na resposta.

## 5. Restrições de temporização

Sem relação de fase entre os clocks, o analisador de tempo não pode verificar esses caminhos como síncronos. O arquivo `.sdc` da plataforma limita todos os cruzamentos entre os clocks da memória e os do núcleo.

| Restrição | Efeito |
| :--- | :--- |
| `set_max_delay` de 10 ns nos dois sentidos | o caminho de dados precisa chegar antes que o toggle apareça no destino |
| `set_min_delay` de -10 ns nos dois sentidos | dispensa a verificação de hold nesses caminhos |

O valor de 10 ns precisa continuar menor que $N \cdot T_{dest}$ do clock mais lento que recebe um barramento. Se o clock do núcleo ou o da memória mudar, essa desigualdade é revalidada.

## 6. Reset e inicialização

| Item | Regra |
| :--- | :--- |
| Reset dos toggles | os dois toggles voltam a `'0'` e os sincronizadores são zerados, então o par começa em "livre" |
| Domínios de reset | `i_rst_cpu` zera a ponte e `i_rst_mem` zera o árbitro e o controlador; os dois lados são resetados juntos, porque um toggle em `'1'` sem o outro lado resetado seria lido como pedido ou resposta |
| Fim da inicialização | `init_done` sobe uma vez e atravessa por um sincronizador próprio; enquanto a ponte o vê em `'0'`, não aceita acessos |

## 7. Ordem dos acessos

O handshake mantém um acesso em andamento por ponte. A ponte não aceita um acesso novo antes de o pipeline avançar, e o árbitro atende um pedido por vez entre os mestres, em revezamento. Por isso o cruzamento não reordena nem intercala acessos.

| Propriedade | Situação |
| :--- | :--- |
| Ordem entre acessos de um mesmo mestre | preservada |
| Acesso de linha (quatro palavras) | um único pedido e uma única resposta, sem estado intermediário visível ao núcleo |
| Leitura seguida de escrita atômica (read-modify-write) | não é fornecida; exigiria reserva ou trava no núcleo ou no controlador |

## 8. Verificação

O teste `SdramSystem` ([sdram_system.py](../../../tests/python/unittests/ram/sdram_system.py)) executa as escritas, as leituras e os acessos de linha com o clock do núcleo em 14 ns, em 53 ns com deslocamento e em 100 ns com deslocamento, contra 7 ns do clock da memória, e a variante `SdramSystem100MHz` repete o teste com o controlador e o modelo do chip a 10 ns (`tck_ps` = 10000). Isso cobre relações de fase e de frequência diferentes nos dois sentidos da travessia, inclusive a razão 1 para 1 entre o clock do núcleo a 100 MHz e o do controlador.

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
