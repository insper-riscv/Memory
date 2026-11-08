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

## 10. Provas que um motor pula

Para saber o que um motor pula, leia a lista da variável do motor no `run.sh` do bloco (`bitwuzla_slow` em `formal/nor_flash_ctrl/run.sh`). O `prove` de `formal/common.sh` encerra na hora, com veredito skip, a prova cujo nome está na lista do motor em execução, e os outros motores rodam a prova normalmente.

| Bloco | Motor | Prova pulada | Profundidade | Quem responde |
| :--- | :--- | :--- | :--- | :--- |
| `nor_flash_ctrl` | `bitwuzla` | `safety_a_program`, configuração A, cenário `program` | 80 | `yices` |
| `nor_flash_ctrl` | `bitwuzla` | `safety_b_read`, configuração B, cenário `read` | 60 | `yices` |

Siga este procedimento ao mexer em uma lista.

1. Confirme que a prova não fecha no motor dentro do `FORMAL_TIMEOUT` do bloco (1500 s no `nor_flash_ctrl`), com `FORMAL_JOBS` igual ao da CI.
2. Confirme que pelo menos um outro motor fecha a prova. O agregador `formal/aggregate.sh` continua exigindo veredito de pelo menos um motor para cada prova, então o pulo nunca esconde uma prova.
3. Pule só o motor que não fecha, e só os nomes exatos. Os mutantes e as coberturas do mesmo bloco continuam rodando em todos os motores.
4. Atualize a tabela acima quando a lista mudar.

No `nor_flash_ctrl`, o `yices` fecha as duas provas (773 s e 62 s), o `boolector` fecha a segunda e o `bitwuzla` não termina nenhuma das duas em 1500 s.

## 11. Avisos são erros

Um aviso do GHDL, do Yosys ou do SymbiYosys indica código fora da norma ou no limite dela, e por isso faz a execução falhar. A correção é no código, na prova ou na netlist, e nenhuma opção `-Wno-*` nem lista de avisos ignorados é permitida.

| Etapa | Onde o aviso é detectado | Efeito |
| :--- | :--- | :--- |
| `ghdl -a` e `ghdl --synth` | Saída de erro do GHDL, lida por `ghdl_run` | O comando falha e imprime cada aviso com o arquivo e a linha do VHDL |
| `sby` de cada prova e de cada mutante | Log completo da prova, lido por `prove` | O veredito vira ERROR, mesmo quando o código de saída foi 0 ou 2, e a mensagem aponta `<log>:<linha>` |

Um aviso é uma linha com a palavra `warning` ou `warnings`, em qualquer caixa, como palavra inteira. Nomes que apenas contêm a palavra (`no_warnings.sv`) e o resumo do Yosys com contagem zero (`Warnings: 0 unique messages, 0 total`) não contam. A única exceção são três mensagens do ABC, aceitas só no log do motor `abc-bmc3` (o relógio do módulo de propriedades sem driver, a contagem de bits sem driver e as saídas lidas como restrições); a leitura da netlist pelo ABC as produz e elas não saem do projeto. Yices, Bitwuzla e Boolector não têm exceção, e qualquer outra mensagem do ABC continua sendo erro. As notas informativas `found RAM` do GHDL não são avisos e não aparecem no terminal.

Três regras mantêm as netlists sem aviso.

1. O atributo `altera_attribute` do sincronizador orienta o Quartus e não significa nada para o GHDL, então a netlist formal é gerada de uma cópia do VHDL sem esse atributo.
2. Um sinal exposto como `dbg_<sinal>` que o GHDL removeu da netlist (porque um mutante tirou o único leitor) é ligado a zero, nunca deixado sem driver, pois um fio sem driver é livre e podia fazer uma propriedade falhar sem que o defeito fosse a causa.
3. Um mutante cuja falha depende de um sinal observado pelas propriedades mantém esse sinal lido. O `inv_inverted` do `dcache` inverte a condição da invalidação, em vez de remover o seu leitor.

Os testes da guarda estão em `formal/test-aggregate.sh`.
