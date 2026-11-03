# Cache de dados e barramento externo AXI4

## 1. O caminho

```
                     ┌─ dcache ─┐
porta do core ── split ──┤          ├── axi_master_bridge ── axi_router ──┬── axi_slave_word_bridge ── sdram_cpu_bridge ── árbitro ── controlador ── chip
 (bit 31)            └─ direto ─┘                                       └── axi_slave_periph_bank ── p_* (oito slots de periférico)
```

Os endereços com o bit 31 em zero são o espaço da SDRAM e passam pela cache, exceto os últimos 4 KB (0x43FFF000 a 0x43FFFFFF). Os endereços com o bit 31 em um são a janela de periféricos (os bits 30:28 escolhem o periférico e os bits 9:2 a palavra). As duas exceções vão direto ao mestre, sem cache. Os últimos 4 KB guardam as palavras que o hospedeiro compartilha com o programa (tohost, fromhost, stdout), que o hospedeiro lê e escreve pela porta de depuração da SDRAM, atrás da cache. Todos os blocos à esquerda da ponte da SDRAM rodam no clock do core, e a ponte cruza para o clock da memória como antes.

As duas pontes (`axi_master_bridge` e `axi_slave_word_bridge`) ficam neste repositório (`src/barramento/soc/`). O roteador, o banco de periféricos e o interconector AXI4 decodificam o mapa da plataforma e conhecem os periféricos, então ficam no Insper-RISC-V (`src/interconnect/`).

O lado do core do conjunto é o contrato do barramento externo privado. O acesso fica na porta enquanto o estágio está parado, `ready` é um nível até `mem_advance`, e `rdata` fica no último load concluído até o próximo terminar, porque o load do último estágio ainda o lê enquanto o acesso seguinte está na porta. O lado do periférico é a mesma porta `p_*` com um pulso por acesso, então um periférico (a UART sobre JTAG) é o mesmo VHDL em qualquer dos dois barramentos.

O periférico 7 (0xF0000000) é o controle da cache: uma escrita na sua primeira palavra inicia um flush, e uma leitura dá 1 enquanto um flush está em andamento e 0 no resto do tempo. Com o bit 1 do valor ligado, ele também descarta todas as linhas depois, o que uma boot ROM faz quando um teste termina, antes de o hospedeiro carregar o próximo programa atrás da cache. Um acesso que não usa a cache espera enquanto um flush roda, e o acesso do core que já é dono do mestre quando um flush começa termina primeiro, com o flush seguindo depois dele.

## 2. Cache de dados

| Propriedade | Valor |
| :--- | :--- |
| Tamanho | 4 KB, mapeamento direto |
| Linha | 16 bytes, quatro palavras |
| Política de escrita | Write-back, write-allocate |
| Divisão do endereço (64 MB de SDRAM) | Bits 25:12 tag, 11:4 linha, 3:2 palavra |
| Contrato com o core | O acesso fica na porta enquanto o estágio está parado, `ready` é um nível até `mem_advance`, e `rdata` muda só nessa borda |
| Acerto | Pronto em 2 clocks (as RAMs leem com registrador, como as RAMs de bloco) |
| Falha limpa | Um pedido de linha (uma rajada de quatro beats no barramento), depois as quatro palavras para a RAM |
| Falha suja | As quatro palavras da linha antiga saem da RAM, um pedido de escrita de linha, e depois o pedido de linha acima |
| `WRITE_THROUGH` (genérico) | Todo store também vai à memória antes de terminar, e um store que falha não traz a linha, então nenhuma linha fica suja e a memória sempre guarda o que o core escreveu. Uma porta de depuração que lê a SDRAM atrás da cache (o hospedeiro da plataforma da SDRAM) precisa disso |
| Reset | Todas as linhas inválidas |
| `flush` | Um pedido, atendido antes de qualquer acesso que espera: escreve de volta toda linha suja (uma varredura das 256 linhas, três clocks para cada limpa), as linhas continuam válidas e ficam limpas, e `busy` fica alto do clock seguinte ao pedido até `flush_done` pulsar |

O AXI4-Lite não tem rajada, então uma linha se move como quatro acessos de uma palavra. Outro mestre que escreve na SDRAM (a porta de depuração JTAG) deve fazê-lo enquanto a cache não guarda nada desses endereços, depois do reset ou depois de um `flush` para o dado que a cache ainda guarda sujo.

## 3. Pontes AXI4

O barramento leva os campos de rajada (comprimento, tamanho, tipo de rajada) e os flags de último de W e R. Os IDs têm largura 0 (são omitidos) e uma transação acontece por vez, então não há regras de ordenação. Todo beat tem 4 bytes. O endereço de um acesso de byte ou meia palavra sai alinhado à palavra, e as habilitações de byte dizem quais bytes valem.

| Bloco | Papel |
| :--- | :--- |
| Ponte mestre | O contrato de palavra do core, com uma extensão de linha, para os cinco canais. Uma palavra é um beat, e uma linha (alinhada em 16 bytes) é uma rajada INCR de quatro beats. AW e W são oferecidos juntos, B e R só são aceitos depois de o pedido ser aceito, e uma leitura cujo último beat não carrega rlast é informada em `err` |
| Ponte escrava da SDRAM | Os cinco canais para o contrato de palavra da ponte da SDRAM. Uma rajada de quatro beats alinhada em 16 bytes é um acesso de linha do controlador, e qualquer outra rajada INCR é um acesso de palavra por beat. Um tamanho diferente de 4 bytes, um tipo de rajada diferente de INCR ou um endereço não alinhado em 4 bytes é respondido com SLVERR depois de todos os seus beats serem consumidos (uma leitura dá zeros), e nada chega à memória. W só é aceito depois de AW |
| Banco de periféricos | Os cinco canais para a porta `p_*` do periférico, com um pulso de `p_we` ou `p_re` por acesso e o dado lido no clock do pulso. Só um beat único é atendido, e uma rajada mais longa é respondida com SLVERR, consumida ou dada como zeros. Uma janela que ninguém responde lê 0 e uma escrita não tem efeito, ambos com OKAY |
| Roteador | Um mestre, dois escravos, sem clock de atraso. 0x40000000 a 0x43FFFFFF é a SDRAM, 0x80000000 em diante são os periféricos, e qualquer outro endereço é aceito, com todos os seus beats consumidos ou dados como zeros, e respondido com DECERR. Um W que chega antes do seu AW espera, e os beats depois do primeiro seguem a mesma decisão até o que tem wlast. B e R voltam do escravo que recebeu o pedido |

O controlador da SDRAM move as quatro palavras de uma linha numa só abertura da linha de memória (ver [sdram_line.md](../ram/sdram_line.md)), então a rajada do barramento é um pedido ao controlador, e não quatro.

## 4. Verificação

| O quê | Como |
| :--- | :--- |
| Cache, pontes e SDRAM juntas | `make test TEST=DataCache`: leituras e escritas contra uma cópia da memória em Python, habilitações de byte, espera depois de ready, evicções, 300 acessos aleatórios sobre linhas em conflito e flush. Depois de cada flush, o modelo do chip deve guardar exatamente a cópia |
| Os mesmos testes do barramento privado | No Insper-RISC-V, `make test TEST=ExtAxiBus` roda os testes do barramento externo privado (bytes da UART em ordem, pipeline parado que retira uma vez, filas cheias, janela sem mapa que lê 0, dado do load que se mantém enquanto o próximo acesso roda) neste barramento, com uma memória de palavra atrás do escravo da SDRAM |
| Roteador | No Insper-RISC-V, `make test TEST=AxiRouter`: os dois escravos para escritas e leituras, rajadas de quatro beats inteiras para um só escravo, W antes de AW, DECERR abaixo, entre e acima das janelas para beats únicos e rajadas, e acessos em sequência. Os mutantes (DECERR respondido como OKAY, W aceito antes do seu AW, uma decodificação errada) falham |
| Protocolo da ponte mestre | `bash formal/axi_master/run.sh`: valid mantido até ready com carga estável, um pedido por acesso, comprimento da rajada e wlast nos beats certos, as palavras depois da primeira são as que o core deu, respostas só depois do pedido, ready como nível e espera limitada. Cobertura e mutantes que devem falhar (inclusive um wlast errado e um comprimento errado). Prova ilimitada por indução |
| Protocolo da ponte escrava | `bash formal/axi_slave/run.sh` (cerca de dez minutos): handshakes, beats e flag de último, uma transação por vez, um pedido que não é atendido nunca chega à memória e espera limitada. Cobertura e 6 mutantes. A prova de segurança é limitada a 55 clocks a partir do reset (transações de até quatro beats), e a carga é conferida pelo teste de sistema abaixo |
| Escravo da SDRAM com o chip | `make test TEST=AxiSdramSlave`: uma rajada de linha é escrita e lida inteira, strobes de byte de cada beat, rajadas de 1, 2, 3, 5 e 8 beats alinhadas ou não, WRAP e FIXED, outros tamanhos e endereços não alinhados dão SLVERR e nunca chegam ao chip, e uma leitura de linha é mais rápida que quatro leituras isoladas |
| Mutantes da cache | Um acerto de escrita que não liga o dirty, um write-back que pula uma palavra e habilitações de byte ignoradas num acerto fazem os testes da cache falhar |

O banco de periféricos e o roteador são conferidos pelos testes acima e ainda não têm propriedades formais.

## 5. Custo do caminho

Medido na simulação da plataforma da SDRAM (clock do core de 30 ns, clock da SDRAM de 7 ns), em clocks do core, do pedido até o avanço do pipeline:

| Acesso | Ponte direta (sem cache) | Cache e AXI4 |
| :--- | ---: | ---: |
| Leitura no espaço da SDRAM | 8 | 3,4 em média num laço que reutiliza um vetor de 1 KB (um acerto custa de 2 a 3) |
| Escrita no espaço da SDRAM | 6 | 16,4 (write-through, um beat) |
| Leitura na janela que pula a cache | 8 | 13 |

Na simulação de unidade (clock do core 8 vezes mais lento que o da SDRAM), uma falha de leitura leva 24 clocks, contra 56 quando a linha se movia como quatro palavras AXI4-Lite.

A SDRAM responde uma palavra em cerca do tempo de um acerto da cache neste clock do core, então a cache economiza pouco nas leituras e o barramento custa mais em toda escrita e em todo acesso que pula a cache. Os programas que leem dados que reutilizam rodam um pouco mais rápido, e os que escrevem, ou leem uma vez, rodam mais devagar (ver [dcache_axi_decisions.md](dcache_axi_decisions.md)).
