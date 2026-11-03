# Um store de byte na janela compartilhada com o hospedeiro foi recusado pelo barramento

## 1. Resumo

O primeiro mestre AXI4 colocou no barramento o endereço de byte do core. Um store de um byte num endereço que não é múltiplo de 4 chegou ao escravo, que recusa endereços não alinhados em 4 bytes, então o store nunca chegou à memória.

| | |
| :--- | :--- |
| Sintoma | 3 de 89 programas falharam na plataforma com a cache: o buffer de stdout guardou cada caractere na sua própria palavra, um teste sinalizou FAIL e um leu zeros |
| Causa | O `sb` e o `sh` do core colocam o endereço de byte na porta com a habilitação de byte da faixa, e a ponte passou o endereço como estava |
| Correção | A ponte mestre envia o endereço alinhado à palavra, e as habilitações de byte dizem quais bytes valem |
| Teste | No Insper-RISC-V, `ExtAxiCache.test_a_byte_store_at_an_unaligned_address_changes_only_its_byte` falha sem a correção, e a prova formal do mestre enuncia o endereço alinhado |

## 2. O mecanismo

No barramento privado o endereço de palavra são os bits 25:2 e os bits baixos são ignorados, então um endereço de byte era inofensivo. Uma transferência AXI4 de tamanho 4 bytes precisa estar alinhada, e o escravo responde SLVERR a uma que não está: a escrita era descartada e o core, que não tem como receber um erro, seguia adiante.

## 3. Como evitar

Uma ponte entre um barramento que ignora os bits baixos do endereço e outro que os confere precisa zerá-los, e uma transferência recusada precisa ficar visível em algum lugar que o teste olha (aqui, os resultados do programa e o buffer de stdout, comparados com o Spike).
