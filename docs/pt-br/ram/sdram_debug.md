# Porta de depuração da SDRAM

## 1. O que é

Um meio de um hospedeiro ler e escrever qualquer palavra da SDRAM pela JTAG enquanto um core a usa, ou enquanto o core está parado ou travado. É um segundo mestre do controlador da SDRAM, atrás de um árbitro, conduzido por uma instância do Virtual JTAG.

| Bloco | Clock | Papel |
| :--- | :--- | :--- |
| Núcleo Virtual JTAG | Clock da JTAG | Os registradores de instrução e de dados, e a passagem de um comando |
| Mestre de depuração | Clock do controlador (142,857 MHz) | Executa um comando: lê, escreve e preenche |
| Árbitro | Clock do controlador | Atende o core e o mestre de depuração, um pedido por vez, alternando quando os dois esperam |

Um acesso do hospedeiro nunca muda o que o core vê, porque os dois leem e escrevem o mesmo chip.

## 2. Os registradores da JTAG

A instância tem um registrador de instrução de 2 bits. A instrução 1 seleciona o registrador de dados DEBUG de 64 bits, e qualquer outra deixa um bypass de 1 bit.

### 2.1 Entrada (hospedeiro para a placa), bit menos significativo primeiro

| Bits | Campo | Significado |
| :--- | :--- | :--- |
| 63:60 | op | O comando (seção 3) |
| 59:56 | be | Habilitação de bytes de uma escrita, em que o bit $i$ habilita o byte $i$ da palavra |
| 55:32 | addr | Endereço de palavra, $2^{24}$ palavras de 32 bits, com endereço de byte $= 4 \cdot \text{addr}$ a partir da base da SDRAM |
| 31:0 | data | O valor a escrever, ou a contagem de um preenchimento |

### 2.2 Saída (placa para o hospedeiro)

| Bits | Campo | Significado |
| :--- | :--- | :--- |
| 63:56 | status | Ver abaixo |
| 55:32 | word | A última palavra acessada |
| 31:0 | data | O que a última leitura devolveu |

| Bit de status | Significado |
| :--- | :--- |
| 0 busy | O comando anterior não terminou, então `word` e `data` ainda não valem |
| 1 error | O controlador não respondeu ao comando anterior |
| 2 initialized | A SDRAM terminou a sequência de energização |
| 3 overrun | Um comando chegou com a porta ocupada e foi descartado (limpo pelo próximo comando aceito) |

O comando sai quando a varredura termina. O status de um comando só está atualizado alguns clocks da JTAG depois de ele ser enviado, então a primeira varredura depois de um comando ainda pode mostrar busy, e a seguinte não.

## 3. Comandos

| op | Nome | Efeito |
| ---: | :--- | :--- |
| 0 | status | Não envia nada, só lê o status |
| 1 | read | Lê a palavra em `addr` |
| 2 | write | Escreve `data` na palavra em `addr`, com os bytes dados por `be` |
| 3 | fill | Escreve `data` (todos os bytes) em `count` palavras a partir de `addr` |
| 4 | set count | `count` $=$ `data[24:0]`, até $2^{24}$ palavras, a SDRAM inteira (começa em 1) |
| 5 | read next | Lê a palavra seguinte à última acessada |
| 6 | write next | Escreve `data` na palavra seguinte à última acessada, com os bytes dados por `be` |

Um preenchimento roda sozinho no clock do controlador, então zerar uma faixa não exige uma varredura por palavra. À taxa do controlador, de cerca de 15 clocks por palavra, os 64 MB inteiros levam cerca de dois segundos (uma estimativa, e a documentação da plataforma tem a medição na placa).

## 4. Uma leitura, passo a passo

1. Carregar a instrução 1 (uma vez).
2. Varrer um comando com op 1 e o endereço de palavra.
3. Varrer op 0 até o status mostrar busy $= 0$ (normalmente na segunda varredura).
4. A varredura que encontra busy $= 0$ traz a última palavra acessada e o dado lido.

Uma escrita é igual sem o passo 4. Para um bloco, op 5 e op 6 continuam da última palavra, então o hospedeiro envia só os dados.

## 5. O árbitro

A ponte do core é o mestre A e o mestre de depuração é o mestre B. Quando os dois esperam, o árbitro alterna, então um acesso do core espera no máximo um acesso de depuração (cerca de 13 clocks do controlador). Com um preenchimento longo em andamento, os acessos do core levaram no máximo 7 ciclos do core, num clock de 56 ns, contra 5 sem tráfego de depuração.

## 6. Limites

A vazão é a do cabo JTAG, uma palavra por comando e alguns milissegundos cada, então ler um quilobyte leva cerca de um segundo. O preenchimento é a exceção, porque roda dentro da placa. Uma cache entre o core e a SDRAM precisa escrever através (ou ser descarregada) para o hospedeiro ler o que o core escreveu.

## 7. A porta de depuração de cada backend (contrato K5)

Todo backend de RAM e de FLASH oferece uma porta de depuração ao hospedeiro, e o hospedeiro usa a mesma da região qualquer que seja a realização dela.

| Realização | Porta de depuração | Observação |
| :--- | :--- | :--- |
| RAM emulada | `i_dbg_word_addr` e `o_dbg_word_data` do modelo; no FPGA, o carregador de memória pela JTAG | Leitura sem cache |
| SDRAM e SRAM | Mestre de depuração que é o segundo mestre do controlador | O cruzamento de domínio é por inversão de sinal, como na ponte da SDRAM |
| FLASH emulada | Porta B do armazenamento, dona do carregador com o núcleo parado | Escrita só com o núcleo em reset |
| FLASH de dispositivo | Controlador de FLASH usando os comandos de [flash_cmd_port](../rom/flash_cmd_port.md) | O carregador de JTAG usa os mesmos comandos |
