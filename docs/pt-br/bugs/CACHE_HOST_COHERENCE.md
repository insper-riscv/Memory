# Uma cache write-back escondeu do hospedeiro os resultados do programa

## 1. Resumo

A primeira integração da cache de dados na plataforma da SDRAM era write-back. O hospedeiro lê a SDRAM pela porta de depuração, que fica atrás da cache, então o que o programa tinha escrito ainda estava na cache quando o hospedeiro comparou a memória com o golden.

| | |
| :--- | :--- |
| Sintoma | 87 de 89 programas falharam na comparação com o golden: os resultados liam 0, embora a caixa de correio dissesse PASS |
| Causa | Os stores ficaram em linhas sujas da cache, e nada os descarregou antes de a caixa de correio ser escrita |
| Correção | A cache da plataforma é write-through: um store chega à SDRAM antes de terminar |
| Teste | Os 89 programas da suíte, na plataforma com a cache: 88 passam (o outro estoura o tempo limite, que é um problema de velocidade e não de coerência). O `DataCacheWriteThrough` confere o chip depois de cada grupo de acessos, sem flush |

## 2. O mecanismo

| Programa | Como sinaliza o fim | Onde um flush poderia ficar |
| :--- | :--- | :--- |
| C | `RV32_PASS()` de um cabeçalho gerado | O cabeçalho poderia chamar o flush |
| Assembly | Um store de 1 no endereço da caixa de correio escrito em cada teste | Em lugar nenhum, a não ser editando todos os testes |

Um flush colocado no `_exit` ajudou só os programas em C que retornam de `main`, e nem todos os que chamam a macro. Descarregar por software não escala para programas que escrevem a caixa de correio por conta própria.

## 3. A correção e o seu preço

Uma cache write-through com write-around (um store que falha não traz a linha) não guarda dado sujo. O hospedeiro vê cada store assim que ele termina, sem flush, e os loads ainda acertam. O preço é que um store leva a escrita completa na SDRAM (14 clocks) em vez de 2.

O mesmo problema de coerência existe no sentido contrário: o hospedeiro escreve o programa seguinte atrás da cache, então as linhas do programa anterior seriam lidas no lugar dele. A boot ROM da plataforma escreve o controle da cache com o bit 1 ligado quando um teste termina, o que descarta todas as linhas, e os acessos à janela compartilhada (os últimos 4 KB da SDRAM) pulam a cache.

## 4. Como evitar

Todo mestre que lê ou escreve uma memória atrás de uma cache é um problema de coerência. Uma porta de depuração que não é coerente precisa de uma cache que mantém a memória atualizada, de uma invalidação antes de o hospedeiro escrever e de endereços sem cache para o que os dois lados usam.
