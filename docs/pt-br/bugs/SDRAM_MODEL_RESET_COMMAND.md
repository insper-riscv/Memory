# O modelo do chip rejeitou um comando que o controlador dirigiu na borda do seu reset

## 1. Resumo

Quando um teste terminava e o seguinte reiniciava o sistema da SDRAM, o modelo do chip às vezes reprovava a execução com "first command before the power-up wait", embora o controlador estivesse correto.

| | |
| :--- | :--- |
| Sintoma | O segundo ou o terceiro teste de um arquivo falhava no primeiro clock do seu reset, só para alguns tempos do teste anterior |
| Causa | Os registradores do controlador ainda dirigiam o comando da execução anterior na primeira borda de clock do reset, e o modelo tinha acabado de reiniciar a sua espera de energização nessa mesma borda |
| Correção | O modelo ignora comandos numa borda em que `reinit` está alto |
| Teste | Os testes da cache de dados (7 testes num arquivo, com resets entre eles) falhavam antes da correção e passam depois. Os testes do sistema da SDRAM, da porta de depuração e do BIST não mudam |

## 2. O mecanismo

O modelo reinicia o seu temporizador de energização quando `reinit` está alto e, no mesmo clock, olha os pinos de comando. O controlador reinicia de forma síncrona, então nessa primeira borda as suas saídas ainda guardam o comando da execução anterior, que é um refresh ou um acesso, nunca um NOP. Um chip real ignora o que está nos pinos durante a sua própria energização, e o modelo contava o comando como o primeiro da execução nova, no tempo zero.

Quais testes falhavam dependia de quanto tempo o teste anterior rodava, então os testes da SDRAM escritos antes não mostravam isso.

## 3. Como evitar

Um modelo de uma peça que está sendo reiniciada não deve julgar os pinos na borda do reset. Um testbench que reinicia um projeto entre testes não deve contar com o projeto ocioso nessa borda.
