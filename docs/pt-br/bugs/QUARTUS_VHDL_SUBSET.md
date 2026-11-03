# Código que o GHDL aceita e o Quartus rejeita

## 1. Resumo

Duas construções de VHDL-2008 no controlador da SDRAM e no seu autoteste passaram em todas as simulações do GHDL e depois pararam a compilação do Quartus para a placa.

| | |
| :--- | :--- |
| Sintoma | A análise do Quartus falha: um erro de sintaxe numa atribuição condicional, e depois "object maximum is used but not declared" |
| Causa | O front end de VHDL do Quartus aceita um subconjunto menor do VHDL-2008 que o GHDL |
| Correção | Escrever a mesma lógica com um comando `if` e uma pequena função nossa |
| Por que os testes não viram | Os testes de simulação rodam só no GHDL, e a primeira compilação do Quartus do projeto foi a primeira vez que outra ferramenta leu os arquivos |

## 2. As duas construções

| Construção | GHDL | Quartus |
| :--- | :--- | :--- |
| `signal <= value when condition else other;` como comando dentro de um process | Aceita (VHDL-2008) | Erro de sintaxe no `when` |
| A função padrão `maximum` sobre dois números | Aceita (VHDL-2008) | "used but not declared" |

A atribuição condicional era uma saída de um bit do autoteste (o write-enable de um pedido), e o `maximum` calculava o menor tempo entre duas ativações de linha no controlador.

## 3. A correção

| Onde | Antes | Depois |
| :--- | :--- | :--- |
| O flag de escrita de um pedido | Uma atribuição condicional | Um `if` com uma atribuição em cada ramo |
| O tempo de linha para linha | Dois usos aninhados da função padrão | Uma função de dois argumentos, de mesmo nome e significado, declarada no controlador e aplicada do mesmo modo |

Nenhuma das mudanças altera o comportamento: os 18 testes de entidade do controlador e do autoteste dão os mesmos resultados antes e depois.

## 4. Como evitar

Tudo que vai para a placa é compilado pelo Quartus, então um arquivo de projeto precisa ficar no subconjunto que as duas ferramentas aceitam. A regra prática deste repositório é não usar atribuição condicional ou selecionada dentro de um process, e não usar os auxiliares numéricos padrão do VHDL-2008, como `maximum` e `minimum`, declarando as poucas funções necessárias. Uma mudança num arquivo que chega à placa só está terminada quando o Quartus a compila.
