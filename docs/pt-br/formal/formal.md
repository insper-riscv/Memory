# Verificação formal do árbitro da SDRAM

O árbitro divide a interface de pedidos do controlador da SDRAM entre a ponte de dados do core, a ponte de instruções do core e a porta de depuração. Uma simulação exercita os casos em que um testbench pensa, e uma prova formal cobre todos os estados que o bloco pode alcançar. Este documento descreve o que é provado, sob quais suposições, e o que a prova não cobre.

## 1. O bloco

Três mestres enviam pedidos a um controlador: A (a ponte de dados do core, em outro clock), I (a ponte de instruções do core, no mesmo clock de A) e B (o mestre de depuração). Um pedido é a inversão de um toggle com a sua palavra nos barramentos, e é respondido pela inversão do toggle de resposta. O árbitro atende um pedido pendente por vez e, quando vários mestres esperam, atende-os em revezamento: o mestre atendido por último vai para o fim da ordem A, I, B. Os toggles de A e de I cruzam um sincronizador de dois flip-flops cada um, dentro do árbitro.

## 2. Método

1. O GHDL sintetiza o VHDL numa netlist Verilog (`ghdl --synth --out=verilog`).
2. O Yosys lê a netlist junto com as propriedades, escritas em SystemVerilog ao redor dela.
3. O SymbiYosys roda um motor sobre o resultado, que é um solver SMT (`yices`, `bitwuzla` ou `boolector`, pelo `smtbmc`) ou o verificador de modelos limitado do ABC (`abc bmc3`). A seção 9 diz o que cada motor roda e como o CI decide entre eles.

Uma cópia da netlist expõe como saídas nove registradores internos (o estado, o mestre atendido e o último mestre atendido, com dois flags cada, o toggle travado e o sincronizador de A e de I). A lógica é a mesma, e os registradores deixam a prova enunciar invariantes do árbitro, de que a indução precisa para descartar estados que não podem ocorrer.

## 3. Suposições sobre o ambiente

| Ambiente | Suposição |
| :--- | :--- |
| Reset | Um clock de reset no início, com todo toggle no seu valor de reset |
| Um mestre | Inverte o seu toggle só depois de o pedido anterior ser respondido, e segura os barramentos da inversão até a resposta (A, I e B igualmente) |
| O controlador | Só responde um pedido pendente, com o toggle desse pedido, em até 4 clocks |
| Clocks | Um clock para todos, e os sincronizadores de A e de I são os dois flip-flops do próprio árbitro |

## 4. Propriedades

| Propriedade | Verificação | Resultado |
| :--- | :--- | :--- |
| No máximo um pedido ao controlador por vez, com os barramentos mantidos enquanto ele está pendente | Prova por indução | Vale |
| Toda concessão leva a palavra de um mestre que esperava | Prova por indução | Vale |
| Todo pedido é respondido uma vez, com o toggle desse pedido, e nunca dois mestres no mesmo clock | Prova por indução | Vale |
| O dado de leitura de um mestre é o que o controlador devolveu, e só muda com a sua resposta | Prova por indução | Vale |
| Um pedido de qualquer dos três mestres é respondido em até 20 clocks (o controlador responde em até 4) | Verificação limitada, profundidade 60 | Vale |

A prova por indução não tem limite de profundidade. A verificação limitada cobre toda execução de até 60 clocks.

## 5. Verificações que protegem a prova

| Verificação | Propósito | Resultado |
| :--- | :--- | :--- |
| Cobertura das situações (uma concessão a cada mestre, uma concessão com os três esperando e a ponte de instruções atendida, uma resposta a cada mestre, uma resposta enquanto outro espera) | As suposições não excluem os casos interessantes | Todas alcançadas |
| O limite de 19 clocks | O limite de 20 é o menor que vale | Falha, como exigido |
| Um mutante que devolve o dado de leitura errado a A | As propriedades detectam uma resposta errada | Pego |
| Um mutante que responde sem esperar o controlador | As propriedades detectam uma resposta prematura | Pego |

## 6. O que a prova não cobre

1. Resets depois do primeiro clock.
2. Um controlador que demora mais de 4 clocks, ou que responde sem um pedido.
3. O mestre A num clock independente do do árbitro: o sincronizador é modelado, e o cruzamento de clock não.
4. O limite de 20 clocks além da profundidade 60.

## 7. Execução

```bash
bash formal/run.sh                         # o árbitro sozinho
make formal                                # o árbitro e as pontes mestre e escrava AXI, de uma vez
make formal FORMAL_ENGINE=yices            # o mesmo, com outro motor
bash formal/test-aggregate.sh              # os testes da agregação da seção 9
```

Precisa de `ghdl`, `yosys`, `sby` e do solver do motor, todos na imagem de toolchain do insper-riscv/Infra. O script sai com falha quando qualquer expectativa da seção 5 muda, inclusive uma verificação que deveria falhar e passa.

## 8. Execução em paralelo e vereditos

As provas de um script são independentes, então rodam lado a lado, e o `make formal` também roda os três blocos lado a lado. No máximo `FORMAL_JOBS` provas rodam ao mesmo tempo (padrão: o número de núcleos, até 8), divididas entre todos os blocos. Os resultados são impressos numa ordem fixa, qualquer que seja a ordem em que as provas terminam.

O SymbiYosys termina com um código que distingue um veredito de uma falha da ferramenta:

| Código de saída | Significado | Resultado |
| :--- | :--- | :--- |
| 0 | A propriedade vale, ou o objetivo é coberto | PASS |
| 2 | Existe um contraexemplo, ou um objetivo não pode ser coberto | FAIL |
| Qualquer outro | A ferramenta não chegou a um veredito (4 desconhecido, 8 tempo esgotado, 16 erro) | ERROR |

Um FAIL esperado só vale para o código 2. Um ERROR faz a execução falhar com o código de saída e o log da prova, então um solver ou uma netlist quebrados nunca são tomados por um defeito que foi pego.

## 9. Motores e a decisão entre eles

`FORMAL_ENGINE` escolhe o que roda as provas (padrão `bitwuzla`). As provas, as profundidades e as propriedades são as mesmas para todo motor.

| Motor | O que roda | Provas que não roda |
| :--- | :--- | :--- |
| `yices`, `bitwuzla`, `boolector` | Um solver SMT, pelo motor `smtbmc` do SymbiYosys | Nenhuma |
| `abc-bmc3` | O verificador de modelos limitado do ABC, sem solver SMT, com a netlist entregue como lógica pura e os valores indefinidos como entradas livres | As coberturas e as provas por indução, que terminam como skip |

Cada execução escreve uma linha por verificação em `build/formal-results/result-<motor>.jsonl`, com a prova, o resultado esperado, o veredito (pass, fail, error ou skip), o código de saída e os segundos. O script `formal/aggregate.sh` lê os arquivos de todos os motores e decide cada prova. Um error (a ferramenta não chegou a um veredito) e um skip não são resposta.

| Respostas dos motores a uma prova | Resultado |
| :--- | :--- |
| Pelo menos uma, todas iguais e iguais ao resultado esperado | ok |
| Um pass e um fail | DISAGREEMENT |
| Todas iguais, mas diferentes do resultado esperado | WRONG |
| Nenhuma (só errors e skips) | NO ANSWER |

Toda prova precisa estar ok, então um motor quebrado não impede os outros de decidir, e um contraexemplo achado por um motor nunca é escondido pelo pass de outro. A tabela de provas por motor vai para o resumo do job. No CI, os jobs `formal - <motor>` rodam os motores e o job `formal` agrega os seus resultados. Só o `formal` é um check obrigatório, porque um check obrigatório exige que todos os seus jobs passem, o que faria um único motor quebrado bloquear os pull requests. Num push na `main` cujo resultado é reaproveitado do pull request (o job `reuse`), os motores e a agregação são pulados, como os outros jobs.
