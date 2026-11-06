# latency_counter

Máquina de contagem de latência dos modelos de memória emulados. Um bloco-folha conta as bordas entre o início de um acesso e o instante em que o modelo o conclui, e é o mesmo na simulação e na placa.

## 1. Função do componente no SoC

O backend emulado de FLASH e de RAM imita o tempo de um dispositivo copiando para o generic `latency` os mesmos $n_{ciclos}$ do catálogo de chips. A contagem desse tempo existe uma só vez, aqui, e três blocos a reutilizam.

| Bloco | Contagens |
| :--- | :--- |
| [flash_chip](../rom/flash_chip.md) | Uma, carregada com `first_latency` num pedido novo e com `next_latency` entre as palavras de uma linha |
| [ram_chip](../ram/ram_chip.md) | Uma por porta (dados e instruções), carregadas com `latency` |
| [onchip_ram_port](../ram/onchip_ram_port.md) | Uma, carregada com `latency` quando o genérico é maior que zero |

## 2. Interface

### 2.1. Generics

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | ---: | :--- |
| `max_count` | `positive` | 255 | Maior valor de `i_count`, em bordas; define a largura do contador |

### 2.2. Portas

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_clk` | entrada | 1 | Clock do módulo |
| `i_rst` | entrada | 1 | Reset síncrono, ativo em `'1'`, que zera a contagem |
| `i_load` | entrada | 1 | Pulso de um ciclo que inicia uma contagem |
| `i_count` | entrada | `natural` de 0 a `max_count` | Bordas da contagem, lido junto com `i_load` |
| `o_last` | saída | 1 | `'1'` na última borda da contagem |
| `o_wait` | saída | 1 | `'1'` enquanto falta mais de uma borda |

## 3. Comportamento

Seja $E_0$ a borda em que `i_load` vale `'1'` e $N$ o valor de `i_count`, com $N = 0$ valendo 1. A contagem obedece à tabela.

| Sinal | Vale `'1'` | Leitura por quem comanda |
| :--- | :--- | :--- |
| `o_last` | Só na borda $E_N$ | O modelo age nessa borda: captura o dado, conclui o acesso ou pede a contagem seguinte |
| `o_wait` | De $E_1$ até $E_{N-1}$ | O acesso ainda não pode terminar |

Uma nova carga na borda em que `o_last` vale `'1'` tem prioridade sobre o fim e reinicia a contagem, que é como o `flash_chip` encadeia as quatro palavras de uma linha. Uma carga no meio da contagem a substitui. Sem nova carga a contagem termina em $E_N$ e os dois sinais voltam a `'0'`. Um reset em qualquer borda zera a contagem.

O contador guarda as bordas que faltam, contando a atual, e decrementa a cada borda até 1, de modo que `o_last` é a comparação com 1 e `o_wait` a comparação com um valor maior que 1.

## 4. Verificação

| Verificação | Cobertura |
| :--- | :--- |
| Entrada `LatencyCounter` de `tests/python/tests.json`, módulo `tests.python.unittests.latency.latency_counter` | A borda do fim para todo $N$ de 0 a 39, 100 e 255; silêncio sem carga; carga na borda do fim; carga no meio; reset no meio |
| Prova formal `formal/latency_counter/run.sh` | Um oráculo escrito nas propriedades diz em que borda cada saída sobe, e a prova por indução (ilimitada, com `max_count` igual a 6) mostra que o contador o segue em qualquer sequência de cargas e resets; cover das situações e sete mutantes do VHDL, todos pegos |

As entradas que exercitam o bloco por dentro dos modelos são as do `flash_chip`, do `ram_chip` e do `onchip_ram_port`.

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
