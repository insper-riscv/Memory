# Decisões da cache de dados e do barramento AXI4-Lite

## 1. Escolhas

| Decisão | Escolhido | Por quê | Custo |
| :--- | :--- | :--- | :--- |
| Barramento do core | AXI4, um mestre, uma transação em andamento, rajadas INCR de quatro beats para linhas, IDs de largura 0 | IP de terceiros fala AXI. Com um só mestre não há necessidade de IDs nem de reordenação, e uma rajada é um pedido ao controlador | Todo acesso isolado paga cinco canais |
| Roteador | Sem clock de atraso, W espera pelo seu AW, DECERR onde nenhum escravo está mapeado | O core não paga clock extra por acesso, e um endereço ruim recebe resposta em vez de travar | Uma transação por direção |
| Organização da cache | 4 KB, mapeamento direto, linhas de 16 bytes | Uma RAM de bloco para as tags e quatro para os dados na FPGA, e uma linha são quatro palavras | Falhas de conflito entre endereços 4 KB distantes |
| Política de escrita da plataforma | Write-through, write-around | O hospedeiro lê a SDRAM atrás da cache sem flush (ver [CACHE_HOST_COHERENCE.md](../bugs/CACHE_HOST_COHERENCE.md)) | Um store leva a escrita completa na SDRAM |
| Política de escrita do módulo | Write-back é o padrão do módulo `dcache` | É o que um core sem porta de depuração atrás da cache usaria | Precisa de um flush antes de qualquer outra leitura da memória |
| Endereços sem cache | A janela de periféricos e os últimos 4 KB da SDRAM | Periféricos têm efeitos colaterais nas leituras, e a janela compartilhada é lida e escrita pelo hospedeiro | As palavras ali nunca acertam |
| Controle da cache | Periférico 7: uma escrita faz flush, o bit 1 também invalida, e uma leitura dá busy | Nenhuma instrução ou CSR novo no core | O programa ou a boot ROM precisa escrevê-lo |
| Flush | Varredura das 256 linhas, atendida antes de qualquer acesso que espera | Simples, e nenhum acesso roda enquanto as linhas se movem | No mínimo 768 clocks, a cada vez |
| Latência do acerto | Dois clocks | A RAM tem leitura com registrador, como as RAMs de bloco da FPGA, e um clock exigiria leitura combinacional | Todo load paga dois clocks |

## 2. O que a medição diz

Clocks do core (30 ns) na plataforma da SDRAM, do pedido até o avanço do pipeline:

| Acesso | Ponte direta | Cache e AXI4 |
| :--- | ---: | ---: |
| Leitura | 8 | 3,4 em média quando o dado é reutilizado, de 2 a 3 num acerto |
| Escrita | 6 | 16,4 (write-through) |
| Leitura da janela que pula a cache | 8 | 13 |

Tempo de programas inteiros, em ticks do clock base sem os 20 000 da energização da SDRAM, contra o mesmo programa com a RAM interna:

| Programas | Ponte direta | Cache, AXI4-Lite (linhas como quatro palavras) | Cache, AXI4 (linhas como rajadas) |
| :--- | ---: | ---: | ---: |
| 89 da suíte de testes, mediana | 1,81 | 2,86 | 2,97 |
| Soma de um vetor de 256 palavras, 16 passadas | 233 300 | não medido | 214 800 |
| Cópia de 128 palavras, 8 passadas | 113 900 | não medido | 167 700 |

A rajada faz o que deve (uma falha de leitura leva 24 clocks contra 56 como quatro palavras na simulação de unidade, e uma leitura de linha pelo barramento leva 13 clocks contra 36), mas não deixa os programas mais rápidos, por dois motivos que não dependem da rajada:

1. Neste clock do core, a SDRAM responde uma palavra em 8 clocks, perto de um acerto da cache, então há pouco a economizar numa leitura. A cache compensa quando o core é muito mais rápido que a memória.
2. Todo store vai à SDRAM por cinco canais e custa 16,4 clocks contra 6 na ponte direta. Os programas que escrevem (uma cópia, a limpeza de `.bss`, o buffer de stdout) perdem mais do que ganham nas leituras, e os programas da suíte são curtos e escrevem quase sempre.

## 3. O que mudaria o resultado

| Mudança | Efeito |
| :--- | :--- |
| Um clock de core mais rápido (a resposta da SDRAM continua em cerca de 60 ns) | Os acertos economizam mais clocks por acesso, e o ponto de equilíbrio é um core várias vezes mais rápido que a memória |
| Menos clocks num acesso isolado pelo barramento (o mestre aceita o pedido no clock em que ele chega, e o escravo aceita AW e W juntos e responde no clock do ready da memória) | Cerca de 5 dos 7 clocks extras de um acesso isolado |
| Uma cache write-back que descarrega sozinha as linhas sujas quando o programa escreve na janela que compartilha com o hospedeiro, com um flush que visita só as linhas sujas | Um store numa linha da cache custa de 2 a 3 clocks, e o hospedeiro ainda vê os resultados |
| Um buffer de stores na frente do write-through | O core não espera a escrita na SDRAM, mas uma sequência longa de stores fica limitada pela taxa da memória |
