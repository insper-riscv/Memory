# Pedidos de linha do controlador da SDRAM

## 1. O que é um pedido de linha

Um pedido com `line = 1` move as quatro palavras que começam no endereço de palavra dado (seus dois bits baixos são ignorados), os 16 bytes de uma linha de cache, numa só abertura da linha de memória.

| Parte | Acesso de palavra | Acesso de linha |
| :--- | :--- | :--- |
| Comandos | ACTIVE, um READ ou WRITE com auto-precharge | ACTIVE, quatro READ ou WRITE com dois clocks de intervalo, auto-precharge no último |
| Beats nos pinos de dados | 2 | 8, sem intervalo |
| Handshakes entre domínios de clock | 1 | 1 |
| Dados | `wdata`, `be`, `rdata` | palavra 0 como antes; palavras 1 a 3 em `wdata_x`, `be_x`, `rdata_x`, 32 bits cada, com a palavra 1 nos bits mais baixos |

As quatro palavras de uma linha ficam na mesma linha de memória e no mesmo banco, porque a linha de cache é alinhada em 16 bytes e a coluna são os bits baixos do endereço de palavra.

## 2. Tempo

| Item | Regra |
| :--- | :--- |
| Espaçamento dos comandos | 2 clocks, o tamanho de uma rajada de dois |
| Dado de leitura | O beat m (0 a 7) é amostrado CAS latency + 2 + m clocks depois do primeiro READ |
| Próximo ACTIVE depois de uma linha | O maior entre tRC, o último READ mais a latência CAS e a rajada, e o último WRITE mais a rajada, tWR e tRP |
| Modelo do chip | Aceita um segundo READ dois clocks depois do primeiro numa linha aberta; reprova a simulação em qualquer violação de tempo |

## 3. Onde é usado

O árbitro leva um pedido de linha do mestre A (a ponte do core) com as palavras extras e responde com as palavras extras; o mestre B (a porta de depuração) move uma palavra por vez. A ponte do core (`sdram_cpu_bridge`) recebe `line` com `rden` ou `wren` e mantém o contrato de que `rdata` e `rdata_x` só mudam em `mem_advance`.

Uma leitura de linha leva 7 clocks do core, contra 20 de quatro leituras de palavra no teste de sistema (clock do core 8 vezes mais lento que o da SDRAM).
