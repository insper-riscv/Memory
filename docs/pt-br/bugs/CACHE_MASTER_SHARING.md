# A cache e os acessos do próprio core disputaram o mestre AXI4-Lite

## 1. Resumo

O tráfego de linhas da cache e os acessos do core que pulam a cache (periféricos, a janela compartilhada da SDRAM) usam o mesmo mestre AXI4-Lite. A primeira arbitragem escolhia o dono pelo endereço na porta do core, e dela saíram três falhas diferentes, todas achadas pelos testes de controle da cache.

| | |
| :--- | :--- |
| Sintoma | Um flush nunca terminava, uma leitura que esperava um flush nunca completava, e o core via `ready` em acessos que não tinha feito |
| Causa | O dono do mestre seguia o endereço do core, e não quem tinha um acesso em andamento |
| Correção | O core é dono do mestre só enquanto tem um acesso na porta e, ou já é dono, ou nenhum flush roda. O `d_ready` da cache e o `ready` do core são mascarados cada um pelo dono |
| Teste | No Insper-RISC-V, `ExtAxiCache`: os quatro testes travavam ou falhavam antes da correção e passam depois |

## 2. As três falhas

| # | Mecanismo | Efeito |
| :--- | :--- | :--- |
| 1 | O mestre era dado ao core sempre que o endereço na sua porta era de periférico, inclusive quando a porta só repousava ali sem acesso | Depois de uma escrita no controle da cache, o endereço ficava na porta, os write-backs do flush nunca chegavam ao mestre e o flush travava |
| 2 | Um acesso do core recebia o mestre e depois era segurado pelo flush em andamento, enquanto o flush precisava do mesmo mestre | O acesso e o flush esperavam um pelo outro |
| 3 | O `ready` do core era o `ready` do mestre sempre que o endereço era de periférico | O mestre terminava um write-back da cache e o core o tomava como a resposta ao seu próprio acesso |

## 3. A correção

Um registrador diz se o acesso do core tem o mestre (ligado quando ele é concedido, zerado quando o seu `mem_advance` chega). O core só recebe o mestre se tem um acesso na porta e, ou já é dono do mestre, ou a cache está ociosa. Um flush que começa enquanto o acesso do core roda espera esse acesso terminar, e um acesso que chega enquanto o flush roda espera o flush. O `d_ready` da cache e o `ready` do core são mascarados pelo dono, então um mestre que responde a um deles nunca é tomado como a resposta ao outro.

## 4. Como evitar

Um árbitro deve decidir por quem tem um pedido em andamento, nunca por um valor que pode ficar no barramento depois de o pedido terminar. Todo sinal de resposta compartilhado por dois solicitantes precisa da mesma máscara do pedido que ele responde.
