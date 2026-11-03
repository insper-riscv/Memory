# A leitura de status da porta de depuração iniciou um comando próprio

## 1. Resumo

A primeira versão da porta de depuração da SDRAM deixava o hospedeiro verificar o fim de um comando varrendo um comando de "status". Cada verificação era ela mesma um comando, então o status que devolvia nunca virava "ocioso".

| | |
| :--- | :--- |
| Sintoma | Todo comando parecia rodar para sempre: o flag busy ficava ligado em toda varredura |
| Causa | Uma varredura de status enviava um comando novo, e o status é lido antes de a resposta do comando anterior chegar ao domínio de clock da JTAG |
| Correção | Uma varredura de status não envia nada, e só os comandos que fazem algo iniciam uma transação |
| Teste | Todo teste da porta de depuração (escrita, leitura, preenchimento, palavra seguinte) falhava com "o comando de depuração nunca terminou" antes da correção e passa depois |

## 2. O mecanismo

O registrador de depuração é varrido no clock da JTAG, que é muito mais lento que o clock do controlador da SDRAM que executa o comando. A resposta de um comando ("pronto") cruza para o clock da JTAG por dois flip-flops, e eles só avançam nas bordas do clock da JTAG.

1. O hospedeiro varre um comando. Quando a varredura termina, o comando é enviado e o status vira busy.
2. O lado do controlador termina em nanossegundos e sinaliza pronto.
3. O hospedeiro varre de novo para ler o status. O status é capturado no início dessa varredura, só uma ou duas bordas do clock da JTAG depois de o comando ser enviado, então o sinal de pronto ainda não cruzou e busy continua aparecendo.
4. Aquela verificação era ela mesma um comando ("status" era uma op comum). Quando a sua varredura terminava, ela era enviada, e busy voltava na hora.

O ciclo se repete a cada verificação: a leitura do status sempre acontecia logo depois do comando da verificação anterior, nunca tempo suficiente depois.

## 3. A correção

Uma varredura cuja op é 0 é só um modo de ler o status, e não envia nada. Os comandos que fazem algo (read, write, fill, set count, read next, write next) são enviados como antes. Uma verificação passa a não custar uma transação, e os 64 clocks da JTAG da varredura dão tempo para o sinal de pronto cruzar, então a segunda varredura depois de um comando mostra busy limpo.

A primeira varredura depois de um comando ainda pode mostrar busy. A documentação diz isso, e o hospedeiro verifica até ele limpar.

## 4. Como evitar

Uma leitura de status que precisa estar livre de efeitos colaterais não pode ser um comando comum. Qualquer valor que cruza de um clock rápido para um lento só vale depois de o clock lento rodar algumas bordas, então uma captura feita bem no início de um acesso está velha por construção, e o protocolo precisa prever uma segunda leitura.
