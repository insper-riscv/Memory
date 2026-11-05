# Contrato de uma Memória

Este documento define o contrato que um bloco de memória cumpre para quem o usa, seja o core, uma cache ou uma ponte. Vale para RAM, ROM, FLASH e SDRAM, dentro do FPGA ou fora dele, e não depende da tecnologia do bloco. O protocolo visto pelo lado do core está em [02-barramento-e-memoria.md](https://github.com/insper-riscv/Core/blob/main/docs/pt-br/contracts/02-barramento-e-memoria.md).

## 1. Pinos

Seja $W$ a largura da palavra guardada, em bits, e $B = W/8$ o número de bytes de uma palavra. Um bloco com $N$ palavras tem $N = \text{tamanho em bytes} / B$.

| Pino | Direção | Largura | Função | RAM | ROM |
| :--- | :---: | :---: | :--- | :---: | :---: |
| `i_clk` | entrada | 1 | Clock do bloco, que pode ser o do core ou outro (seção 4) | sim | sim |
| `i_addr` | entrada | $\log_2 N$ | Endereço da palavra, e não do byte | sim | sim |
| `i_re` | entrada | 1 | Habilita a leitura | sim | sim |
| `i_we` | entrada | 1 | Habilita a escrita | sim | não |
| `i_data` | entrada | $W$ | Dado de escrita | sim | não |
| `i_mask` | entrada | $B$ | Máscara de bytes da escrita, um bit por byte, com `1` para escrever o byte | sim | não |
| `o_q` | saída | $W$ | Dado lido | sim | sim |

Uma RAM de 256 KB com $W = 32$ tem $N = 65536$ palavras, então `i_addr` tem 16 bits.

### 1.1. Correspondência com os blocos do repositório

Os nomes do contrato seguem o prefixo `i_` e `o_` do CONTRIBUTING. Os IPs do Quartus têm nomes gerados pelo assistente, e os modelos de simulação têm nomes próprios.

| Contrato | IP do Quartus | `ram_simulation` | `rom_simulation` |
| :--- | :--- | :--- | :--- |
| `i_clk` | `clock` | `i_clk` | `i_clk` |
| `i_addr` | `address` | `i_addr` | `i_addr` |
| `i_re` | `rden` | `i_re_ram`, junto com `i_en_ram` | `i_re` |
| `i_we` | `wren` | `i_we_ram` | não tem |
| `i_data` | `data` | `i_data_in` | não tem |
| `i_mask` | `byteena`, só no `ram` | `i_mask` | não tem |
| `o_q` | `q` | `o_data_out` | `o_data` |

Os IPs de ROM (`boot_rom` e `flash_store`) têm `wren` e `data`, porque o bloco de memória do FPGA é o mesmo de uma RAM, mas o desenho da placa os mantém em zero. O `rom_simulation` tem ainda uma segunda porta de leitura, com `i_addr2`, `i_clk2`, `i_re2` e `o_data2`.

## 2. Tempo

| Operação | Condição na borda de subida de `i_clk` | Efeito |
| :--- | :--- | :--- |
| Leitura | `i_re` em `'1'` | `o_q` traz a palavra de `i_addr` a partir da borda seguinte, um ciclo depois |
| Escrita | `i_we` em `'1'` | Cada byte cuja posição em `i_mask` vale `'1'` é gravado, e os demais bytes não mudam |
| Load do core | `i_mask` em zero | Não há escrita |

Fora da tabela, o contrato fixa o seguinte.

- Os bytes seguem a ordem little-endian, com o byte 0 nos bits $[7:0]$ de cada palavra.
- Os blocos internos não têm reset. O conteúdo inicial vem do arquivo de inicialização (`.mif` ou `.hex`), e a ROM só muda por regravação externa, como a da JTAG, nunca pelo core.
- Leitura e escrita no mesmo ciclo não fazem parte do contrato. O `ram_chip` e a ponte AXI, se receberem os dois pedidos, deixam a escrita vencer. Com leitura e escrita na mesma borda e no mesmo endereço, a RAM de simulação devolve o valor antigo.
- O valor de `o_q` com `i_re` em `'0'` não é definido pelo contrato. Quem lê só usa `o_q` no ciclo seguinte a um `i_re` em `'1'`.

## 3. Memórias de latência variável

SDRAM, FLASH atrás de cache e RAM externa levam vários ciclos, e a resposta de um ciclo só do contrato acima não basta. Esses chips acrescentam dois pinos e usam o endereço de byte de 32 bits em vez do endereço de palavra.

| Pino | Direção | Função |
| :--- | :---: | :--- |
| `o_ready` | saída | Nível que sobe quando o dado está pronto e permanece em `'1'` até o `advance` |
| `i_advance` | entrada | Indica que o pedido foi consumido, e o chip pode aceitar o seguinte (no `ram_chip` chama-se `i_mem_advance`) |

O pedido (endereço, dado, máscara, `i_re` e `i_we`) fica estável até `o_ready` subir, e o dado lido só muda no pedido seguinte. Um pedido de linha acrescenta `i_line`, que move quatro palavras, e três portas extras de 32 bits para as palavras 1 a 3 do dado e da leitura. Os chips documentados com esse contrato são [ram_chip](../ram/ram_chip.md), [flash_chip](../rom/flash_chip.md) e, do lado da SDRAM, a ponte [sdram_cpu_bridge](../ram/sdram_cpu_bridge.md).

## 4. Clock

O clock é um pino separado, e o bloco só enxerga a borda que recebe. Há dois casos.

| Caso | Quando acontece | O que fazer |
| :--- | :--- | :--- |
| Mesmo clock do core | Os blocos internos da placa, como o `BOOT_ROM` (ligado ao clock `pll_clk_if`) e o armazenamento da FLASH (ligado ao `pll_clk_idexmem`), ambos clocks de 50 MHz do core | Ligar direto, sem sincronização |
| Clock diferente | O controlador da SDRAM e a porta de depuração, a 142,857 MHz, enquanto o core roda a 50 MHz | Cruzar o domínio por um pedido que inverte um sinal (`req_tog`) e uma resposta que inverte outro (`ack_tog`), cada um lido por dois flip-flops de sincronização, com endereço, dado e máscara estáveis da inversão do pedido até a resposta |

O cruzamento por inversão é o que a ponte [sdram_cpu_bridge](../ram/sdram_cpu_bridge.md) e o árbitro [sdram_arbiter](../ram/sdram_arbiter.md) usam. Um bloco nunca deve receber `i_re`, `i_we` ou `i_addr` de um domínio de clock que não seja o seu sem passar por essa sincronização.

## 5. Memória de duas portas

Uma memória de duas portas tem dois conjuntos independentes de pinos de acesso, e cada porta atende um acesso por ciclo ao mesmo tempo que a outra. O contrato das seções 1 e 2 vale para cada porta, e a porta 2 repete os pinos da porta 1 com o sufixo `2`, como no `rom_simulation`.

| Porta 1 | Porta 2 | Função |
| :--- | :--- | :--- |
| `i_clk` | `i_clk2` | Clock da porta, que pode ser diferente do da outra porta |
| `i_addr` | `i_addr2` | Endereço da palavra |
| `i_re` | `i_re2` | Habilita a leitura |
| `i_we` | `i_we2` | Habilita a escrita, só nas portas que escrevem |
| `i_data` | `i_data2` | Dado de escrita |
| `i_mask` | `i_mask2` | Máscara de bytes da escrita |
| `o_q` | `o_q2` | Dado lido |

Há três arranjos de portas, e o repositório usa dois deles.

| Arranjo | Portas | Onde aparece |
| :--- | :--- | :--- |
| Duas leituras | As duas só leem | O `rom_simulation` lê o mesmo vetor por duas portas, cada uma com o seu clock. O Core usa a segunda para ler constantes da FLASH no estágio MEM (`o_flash_addr2` e `o_flash_rden2`) enquanto o estágio IF busca instruções |
| Uma leitura e escrita e uma só leitura | A porta 1 lê e escreve, e a porta 2 só lê | O `ram_chip` tem a porta de dados do core, a porta de instruções (`i_ins_*`) e a porta de depuração por palavra (`i_dbg_word_addr`), todas com `o_ready` e `advance` |
| Duas de leitura e escrita | As duas leem e escrevem | Nenhum bloco do repositório. Todos os IPs do Quartus usam `SINGLE_PORT` |

As regras de uso são estas.

1. Cada porta cumpre o tempo da seção 2 com o seu próprio clock. Se os clocks das portas diferem, quem aciona cada porta atravessa o domínio como descreve a seção 4.
2. Duas leituras da mesma palavra, uma em cada porta, não interferem entre si.
3. Uma escrita numa porta e uma leitura da mesma palavra na outra, no mesmo ciclo, têm resultado que o contrato não define. Quem usa a memória deve evitar o caso. No `ram_chip`, uma leitura pedida depois de uma escrita já completa vê o dado novo, inclusive um store da porta de dados visto pela porta de instruções.
4. Duas escritas na mesma palavra, uma em cada porta, no mesmo ciclo, também não são definidas e devem ser evitadas.

### 5.1. Quando não há duas portas

Dois agentes que precisam do mesmo dispositivo têm três soluções.

| Solução | Quando usar | Custo |
| :--- | :--- | :--- |
| Memória de duas portas | Dois acessos simultâneos num bloco de memória do FPGA | Um bloco com duas portas |
| Duas cópias de porta única | Dois acessos simultâneos e regravação pelo editor de conteúdo em sistema no Quartus Lite | O dobro dos blocos, com o mesmo conteúdo nas duas cópias, regravadas juntas |
| Um dispositivo de porta única com árbitro | Chip que tem uma só interface, como a SDRAM e o chip de FLASH | Os acessos se serializam, e um mestre espera o outro, como em [sdram_arbiter](../ram/sdram_arbiter.md) e [flash_arbiter](../cache/flash_arbiter.md) |

O Quartus Lite deste projeto não compila um `altsyncram` em duas portas junto com `ENABLE_RUNTIME_MOD=YES`, que é o que dá acesso pelo editor de conteúdo em sistema. A FLASH do desenho de memória interna usa por isso uma só cópia de duas portas verdadeiras sem essa dica, [flash](../rom/flash.md), com a porta A na busca de instruções e a porta B na leitura de dados. A regravação passa por um carregador próprio, [flash_loader](../rom/flash_loader.md), que escreve na porta B pela JTAG só com o núcleo parado.

## 6. Largura da palavra guardada diferente da palavra do core

O core fala em palavras de 32 bits, com uma máscara de 4 bits (um bit por byte) e endereço de byte. Quando o dispositivo guarda palavras de $W \neq 32$ bits, um adaptador entre os dois reconcilia a diferença. O adaptador só vê a máscara de bytes na escrita e uma palavra inteira de 32 bits na leitura. Ele nunca recebe a largura da instrução, porque a seleção de byte ou meia palavra e a extensão de sinal acontecem no estágio WB do core. O tratamento completo está em [MEMORY_WIDTH.md](https://github.com/insper-riscv/Core/blob/main/docs/pt-br/MEMORY_WIDTH.md), e esta seção resume as regras.

### 6.1. Endereço

O adaptador descarta os dois bits baixos do endereço de byte e trabalha com o índice de palavra do core. Os acessos desalinhados que cruzam a palavra chegam como dois acessos independentes, cada um com o endereço de uma palavra alinhada, e o adaptador trata cada um como um acesso comum.

### 6.2. Memória mais estreita ($W < 32$)

Seja $n = 32 / W$ o número de fatias de uma palavra do core.

| Forma | Como funciona | Ciclos por acesso | Onde pode ficar |
| :--- | :--- | :--- | :--- |
| $n$ dispositivos em paralelo | Cada um recebe a sua fatia do dado e da máscara, com o mesmo endereço | Os de um dispositivo de 32 bits | Memória interna ou barramento externo |
| Um dispositivo em série | As $n$ fatias saem em sequência | $n$ ou mais | Só o barramento externo, com `o_ready` |

Na escrita, a fatia $k$ (com $k = 0$ a menos significativa) recebe os trechos abaixo.

$$
\text{dado}_k = \text{dado}[W(k+1)-1 : Wk] \qquad \text{máscara}_k = \text{máscara}\left[\tfrac{W}{8}(k+1)-1 : \tfrac{W}{8}k\right]
$$

Uma fatia com máscara toda em zero não precisa ser escrita. Na leitura, as fatias são lidas em sequência e concatenadas, com a fatia 0 nos bits baixos, e a palavra só vale quando a última chega.

$$
\text{palavra} = \text{fatia}_{n-1} \mathbin{\|} \dots \mathbin{\|} \text{fatia}_1 \mathbin{\|} \text{fatia}_0
$$

O chip de SDRAM da placa é o exemplo do caso em série. Ele tem 16 bits, então $n = 2$. Uma palavra de 32 bits é uma rajada de dois beats de 16 bits, o primeiro com a metade baixa e o segundo com a alta, e uma linha de quatro palavras é uma rajada de oito beats. A máscara de cada beat é o complemento dos dois bits da máscara do core para aquela metade, porque os pinos `dqm` do chip mascaram em `'1'`. A leitura não usa máscara.

### 6.3. Memória mais larga ($W > 32$)

Seja $m = W / 32$ o número de palavras do core em cada palavra do dispositivo. Os bits de endereço logo acima dos dois baixos escolhem a faixa de 32 bits.

$$
\text{faixa} = \text{endereço}\left[\log_2 m + 1 : 2\right]
$$

Na leitura, o adaptador devolve só a faixa escolhida, sem deslocá-la. Na escrita, ele coloca o dado de 32 bits na faixa escolhida e monta uma máscara de $W/8$ bits em que só os 4 bits dessa faixa vêm da máscara do core, e os demais bytes ficam desabilitados.

| Dispositivo | Máscara do core | Faixa | Máscara no dispositivo |
| :--- | :--- | :--- | :--- |
| 64 bits ($m = 2$) | `0011` | 0 | `0000 0011` |
| 64 bits ($m = 2$) | `0011` | 1 | `0011 0000` |
| 128 bits ($m = 4$) | `1111` | 2 | `0000 1111 0000 0000` |

Uma palavra larga permite mover várias palavras do core de uma vez. A cache de dados usa isso nas linhas de 16 bytes, movidas por um único pedido ao controlador da SDRAM.

### 6.4. Resumo das decisões

| Situação | Solução |
| :--- | :--- |
| $W < 32$ e um só dispositivo | Serializar em $n$ fatias, no barramento externo, com `o_ready` |
| $W < 32$ e $n$ dispositivos | Colocar em paralelo, sem custo de ciclo, com a fatia da máscara em cada um |
| $W > 32$ | Escolher a faixa pelo endereço e replicar o dado na escrita |
| Sem máscara de bytes no dispositivo | Ler, misturar e escrever, só no barramento externo |
| O dispositivo precisa de mais de um ciclo | Barramento externo com `o_ready`, nunca a memória interna |

## 7. Blocos que cumprem o contrato

| Tipo | Blocos |
| :--- | :--- |
| Memória de um ciclo | [ram](../ram/ram.md), [ram_simulation](../ram/ram_simulation.md), [boot_rom](../rom/boot_rom.md), [flash_store](../rom/flash_store.md), [rom_simulation](../rom/rom_simulation.md) |
| Memória de latência variável | [ram_chip](../ram/ram_chip.md), [flash_chip](../rom/flash_chip.md), [sdram_ctrl](../ram/sdram_ctrl.md) |
| Memória de duas portas | [rom_simulation](../rom/rom_simulation.md) (duas leituras) e [ram_chip](../ram/ram_chip.md) (dados, instruções e depuração) |

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
