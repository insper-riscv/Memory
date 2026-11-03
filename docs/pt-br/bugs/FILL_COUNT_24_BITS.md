# Um preenchimento da SDRAM inteira foi lido como um preenchimento de nada

## 1. Resumo

O comando de preenchimento da porta de depuração toma o seu comprimento de um registrador de contagem que tinha 24 bits de largura. Um preenchimento da SDRAM inteira são $2^{24}$ palavras, que precisam de 25 bits, então a contagem dava a volta para 0 e o preenchimento não fazia nada, sem erro.

| | |
| :--- | :--- |
| Sintoma | Zerar a RAM a partir do hospedeiro terminava em 0,6 s e imprimia OK, e um dump depois ainda guardava os dados antigos |
| Causa | O registrador de contagem guardava os bits 23 a 0 do valor enviado, e $2^{24}$ tem só o bit 24 ligado |
| Correção | O registrador de contagem tem 25 bits de largura |
| Teste | O registrador de contagem lê $2^{24}$ depois do comando que o define, e antes da correção lia 0 |

## 2. O mecanismo

A SDRAM tem $2^{24}$ palavras de 32 bits. O comando de preenchimento escreve um valor em `count` palavras a partir de um endereço, e a contagem é definida por outro comando cujo campo de dados a carrega. O registrador que guardava a contagem tomava só os 24 bits baixos desse campo, então o maior valor que ele podia guardar era $2^{24} - 1$.

| Contagem pedida | Contagem guardada (24 bits) | Contagem guardada (25 bits) |
| ---: | ---: | ---: |
| 64 | 64 | 64 |
| $2^{24} - 1$ | $2^{24} - 1$ | $2^{24} - 1$ |
| $2^{24}$ (a SDRAM inteira) | 0 | $2^{24}$ |

Uma contagem 0 significa "não escrever nada" no comando de preenchimento, então o hospedeiro recebeu um sucesso rápido e silencioso.

## 3. Por que os testes não viram

Todo preenchimento em simulação usava alguns milhares de palavras. Preencher $2^{24}$ palavras leva cerca de 250 milhões de clocks do controlador, o que é longo demais para uma simulação, então o maior valor legal nunca foi exercitado. O valor é uma fronteira do campo, e só um teste da fronteira o encontra: o teste novo confere o registrador depois de definir $2^{24}$ e $2^{24} - 1$, sem rodar o preenchimento.

## 4. Como evitar

Uma contagem que pode ser igual ao tamanho do que ela conta precisa de um bit a mais do que um índice nesse conjunto. O mesmo erro se esconde em qualquer pedido de "tudo", e um comando que não faz nada para um valor ruim deve informar um erro, e não sucesso.
