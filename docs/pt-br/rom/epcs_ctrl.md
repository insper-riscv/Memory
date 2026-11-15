# epcs_ctrl

Acesso de usuário à flash serial EPCS de configuração: leitura, programação de página e apagamento de setor por SPI, sem tocar no bitstream.

## 1. Função do componente no SoC

A flash serial EPCS64 das placas DE0-CV, DE2-115, DE0-Nano e DE10-Nano guarda o bitstream de configuração do FPGA, e sem este módulo só a ferramenta de programação a alcança. O `epcs_ctrl` entrega ao software um banco de registradores de 32 bits que lê o chip todo e que grava e apaga só a região de usuário, acima do arquivo de configuração. O módulo é uma composição de três entidades.

| Entidade | Papel |
| :--- | :--- |
| `epcs_cmd` | Registradores, buffer de uma página, guarda da região de usuário e sequenciador dos comandos |
| `epcs_spi` | Mestre SPI modo 0 que monta um quadro de instrução por pedido |
| `epcs_ctrl` | Topo estrutural: liga as duas e expõe o barramento e os quatro pinos SPI |

Os quatro pinos SPI vão a um bloco de interface do dispositivo (seção 8) ou ao `epcs_model` na simulação.

## 2. Placas

| Placa | Flash de configuração | Fonte |
| :--- | :--- | :--- |
| DE0-CV | EPCS64 | Manual da DE0-CV, seção 3.1 e figura do diagrama de blocos |
| DE2-115 | EPCS64 | Manual da DE2-115, seção 4.1 |
| DE0-Nano | EPCS64 Spansion | Manual da DE0-Nano, seção 1.1 (a lista da seção 3 e o capítulo de demonstração repetem EPCS64; não é EPCS16) |
| DE10-Nano | EPCS64 | Manual da DE10-Nano, seções 2.1, 2.2 e 3.2 |

O manual da DE0-Nano diz que a demonstração acessa a EPCS por pinos que o Quartus liga a um controlador de EPCS, e que é preciso apagar a EPCS antes de gravar nela. Nenhum dos manuais informa a organização interna do chip, os códigos de instrução nem a ocupação do bitstream; isso vem do datasheet da família (não incluído em `Docs`), e fica marcado como não confirmado onde é usado.

## 3. Interface

### 3.1. Generics do `epcs_ctrl`

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | ---: | :--- |
| `size_bytes` | `positive` | 8388608 | Tamanho do chip em bytes (EPCS64, 64 Mbits) |
| `user_base` | `natural` | 4194304 | Início da região de usuário em bytes, múltiplo do setor de 64 KB |
| `clk_div` | `positive` | 2 | Bordas de `i_clk` em cada meio período de `o_sck` |
| `gap_ticks` | `positive` | 8 | Meios períodos com `CS#` alto depois de cada quadro |

A frequência do clock SPI é

$$ f_{SCK} = \frac{f_{clk}}{2 \cdot \mathtt{clk\_div}} $$

e o padrão dá 12,5 MHz com o clock de 50 MHz. O limite do chip para cada instrução não está nos manuais da placa (não confirmado).

### 3.2. Portas

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_clk` | entrada | 1 | Clock do módulo |
| `i_rst` | entrada | 1 | Reset síncrono, ativo em `'1'` |
| `i_address` | entrada | 4 | Índice do registrador |
| `i_write` | entrada | 1 | Escrita no registrador |
| `i_read` | entrada | 1 | Leitura do registrador (só tem efeito em `BUFDATA`) |
| `i_data_in` | entrada | 32 | Dado de escrita |
| `o_data_out` | saída | 32 | Dado de leitura, combinacional sobre `i_address` |
| `o_irq` | saída | 1 | Concluído com a interrupção habilitada |
| `o_sck` | saída | 1 | Clock SPI, baixo em repouso |
| `o_cs_n` | saída | 1 | Seleção do chip, ativa em `'0'` |
| `o_mosi` | saída | 1 | Dado para o chip |
| `i_miso` | entrada | 1 | Dado do chip |

## 4. Registradores

| Índice | Nome | Acesso | Conteúdo |
| ---: | :--- | :--- | :--- |
| 0 | `STATUS` | leitura e escrita de 1 para limpar | Bit 0 ocupado, bit 1 concluído, bit 2 erro, bit 3 escrita habilitada (WREN concluído), bit 4 operação em andamento no chip (WIP do último RDSR), bits 15 a 8 último registrador de estado lido. Escrever `'1'` nos bits 1 ou 2 limpa o bit |
| 1 | `CONTROL` | leitura e escrita | Bit 0 habilita a interrupção, bit 1 faz o comando Ler usar FAST_READ |
| 2 | `ADDRESS` | leitura e escrita | Endereço de byte de 24 bits |
| 3 | `LENGTH` | leitura e escrita | Bytes de dado de Ler e Gravar página, de 1 a 256 |
| 4 | `COMMAND` | escrita | Código do comando (seção 5) |
| 5 | `ID` | leitura | Resposta do RDID: fabricante nos bits 23 a 16, depois tipo e capacidade |
| 6 | `USER_BASE` | leitura | Início da região de usuário |
| 7 | `SIZE` | leitura | Tamanho do chip em bytes |
| 8 | `BUFIDX` | leitura e escrita | Índice de palavra do buffer de página, de 0 a 63 |
| 9 | `BUFDATA` | leitura e escrita | Palavra do buffer em `BUFIDX`; cada acesso avança `BUFIDX` |

O buffer guarda a página de 256 bytes que Ler preenche e Gravar página envia, com o byte 0 nos bits 7 a 0 da palavra 0. O valor lido em `BUFDATA` reflete o índice de dois ciclos antes, então deixe dois ciclos entre acessos seguidos. Com o controlador ocupado, a leitura de `BUFDATA` devolve zero e a escrita é ignorada.

## 5. Comandos

| Código | Comando | Instrução SPI | Efeito |
| ---: | :--- | :--- | :--- |
| 1 | Identificar | RDID (`0x9F`) | Lê 3 bytes para `ID` |
| 2 | Estado | RDSR (`0x05`) | Lê o registrador de estado do chip |
| 3 | Habilitar escrita | WREN (`0x06`) | Ao concluir, sobe o bit de escrita habilitada |
| 4 | Ler | READ (`0x03`) ou FAST_READ (`0x0B`) | Lê `LENGTH` bytes de `ADDRESS` para o buffer |
| 5 | Gravar página | PP (`0x02`) | Grava `LENGTH` bytes do buffer em `ADDRESS` |
| 6 | Apagar setor | SE (`0xD8`) | Apaga o setor de 64 KB que contém `ADDRESS` |

Os códigos de instrução são os da família M25P que as EPCS seguem, e não estão nos manuais da placa (não confirmado). O módulo não envia outra instrução: nem o apagar do chip todo, nem a escrita do registrador de estado.

Depois de Gravar página e de Apagar setor o módulo repete RDSR até o bit WIP do chip cair, e só então sobe o concluído e derruba a escrita habilitada. O endereço do Apagar setor é alinhado ao início do setor.

## 6. Guarda do bitstream

A região de usuário vai de `user_base` ao fim do chip, e o arquivo de configuração fica abaixo dela.

| Comando | Condições para ser aceito |
| :--- | :--- |
| Ler | $1 \le \mathtt{LENGTH} \le 256$ e $\mathtt{ADDRESS} + \mathtt{LENGTH} \le \mathtt{size\_bytes}$ |
| Gravar página | Escrita habilitada, $1 \le \mathtt{LENGTH} \le 256$, $\mathtt{ADDRESS} \ge \mathtt{user\_base}$, a gravação cabe na página ($\mathtt{ADDRESS} \bmod 256 + \mathtt{LENGTH} \le 256$) e dentro do chip |
| Apagar setor | Escrita habilitada, início do setor $\ge \mathtt{user\_base}$ e `ADDRESS` dentro do chip |
| Habilitar escrita, Identificar, Estado | Sempre |

Um comando recusado sobe o bit de erro, derruba a escrita habilitada e não gera nenhum quadro SPI. Um comando escrito com o controlador ocupado também sobe o erro, e o comando em andamento termina. A leitura vale em todo o chip, o que inclui o bitstream, sem risco para ele.

### 6.1. Como escolher `user_base`

O bitstream ocupa o início do chip, e o tamanho dele depende do dispositivo e da compressão. Os manuais da placa não informam esse tamanho (não confirmado). O valor correto é o tamanho do arquivo de programação que o Quartus gera para o projeto (o `.pof` ou o `.jic`, e o `.rbf` para conferência), arredondado para cima ao múltiplo de 64 KB:

$$ \mathtt{user\_base} = 65536 \cdot \left\lceil \frac{\text{tamanho do arquivo}}{65536} \right\rceil $$

O padrão de 4 MB reserva a metade de baixo da EPCS64 ao bitstream, o que deixa folga ampla para os dispositivos das quatro placas (a conferir pelo tamanho real do arquivo de cada projeto). Um projeto que guarde mais de um bitstream (imagem de fábrica e de aplicação) soma os dois tamanhos antes de arredondar.

### 6.2. Atenção ao fluxo de programação

O passo Erase do Programmer do Quartus (manual da DE10-Nano, seção 8.4) apaga a EPCS inteira e leva junto os dados de usuário, então regravar o bitstream por ele exige guardar antes o conteúdo da região de usuário. A regravação do arquivo de configuração sem o passo Erase só toca os setores que o novo arquivo ocupa (não confirmado nos manuais).

## 7. O mestre SPI

O `epcs_spi` executa um quadro por pedido, em SPI modo 0 (o dado sai na descida do clock, e o chip amostra na subida), com `CS#` baixo do primeiro ao último bit.

| Operação | Quadro enviado | Dado |
| :--- | :--- | :--- |
| RDID | `0x9F` | Recebe 3 bytes |
| RDSR | `0x05` | Recebe 1 byte |
| WREN | `0x06` | Nenhum |
| READ | `0x03`, endereço de 24 bits | Recebe $n$ bytes |
| FAST_READ | `0x0B`, endereço de 24 bits, 1 byte dummy | Recebe $n$ bytes |
| PP | `0x02`, endereço de 24 bits | Envia $n$ bytes |
| SE | `0xD8`, endereço de 24 bits | Nenhum |

Cada byte recebido sai num pulso com o índice dele no dado, e cada byte a enviar é pedido pelo índice, que o dono do buffer atende em até três bordas. O quadro termina com `CS#` alto por `gap_ticks` meios períodos, que precisa cobrir o tempo mínimo de `CS#` alto do chip (não confirmado), e então sobe o pulso de fim.

## 8. Interface com os pinos de configuração

Os pinos da flash de configuração (`DCLK`, `nCSO`, `ASDO` e `DATA0`) são dedicados, e o FPGA só os alcança pelo bloco ASMI da família. Cada família tem um invólucro fino que instancia o bloco por `component`, sem lógica, com a ligação que o `altserial_flash_loader` da Altera usa no Quartus 25.1.

| Invólucro | Famílias e placas | Bloco | Ligação |
| :--- | :--- | :--- | :--- |
| `epcs_asmi_cyclone_iv_e` | Cyclone IV E: DE0-Nano, DE2-115 | `cycloneii_asmiblock` | `dclkin` ao clock, `scein` à seleção, `sdoin` ao dado para o chip, `data0out` ao dado do chip, `oe` em `'0'` |
| `epcs_asmi_cyclone_v` | Cyclone V: DE0-CV, DE10-Nano | `cyclonev_asmiblock` | `dclk` ao clock, `sce` à seleção, `data0out` ao dado para o chip, `data1in` ao dado do chip, `data2out` e `data3out` em `'1'`, `oe` em `'0'` |

Os dois invólucros estão em `tree.vhdl_style.exclude` do `paths.yaml`, porque as duas primitivas não constam de `vendor_primitives.yaml` do `riscv-tools`.

### 8.1. Atribuições do projeto Quartus

O bloco ASMI exige que a configuração do projeto seja serial ativa.

| Família | Atribuição |
| :--- | :--- |
| Cyclone IV E | O padrão do Quartus já é serial ativa |
| Cyclone V (DE0-CV, DE10-Nano) | `set_global_assignment -name STRATIXV_CONFIGURATION_SCHEME "Active Serial x1"`; sem ela o ajuste falha com o erro 176289 |

Na DE10-Nano e na DE0-Nano, o modo de configuração do FPGA também depende das chaves MSEL da placa, que não são do escopo deste módulo.

### 8.2. O que não foi confirmado

| Item | Estado |
| :--- | :--- |
| Funcionamento em placa | Não testado: só simulação, prova formal e síntese no Quartus 25.1 |
| Polaridade de `scein` e `sce` | Tirada do `altserial_flash_loader` do Quartus, sem teste no pino |
| Códigos de instrução, bytes do RDID, tempos do chip e frequência máxima do SCK | Datasheet da família não está em `Docs`; valores de memória |
| Tamanho do bitstream de cada projeto | Depende do arquivo gerado, não dos manuais |

## 9. Modelo de simulação

O `epcs_model` é um escravo SPI modo 0 que imita a EPCS: registrador de estado com WIP e WEL, leitura (READ e FAST_READ), RDID, WREN, PP com volta na página e SE de setor de 64 KB, com a regra de que a gravação só leva bits de 1 para 0. O conteúdo nasce com um padrão que depende do endereço, e a parte abaixo de `protect_below` finge ser o bitstream. O modelo sobe `o_violation` quando o controlador faz o que um chip real ignora ou o que o bitstream não tolera.

| Violação | Causa |
| :--- | :--- |
| PP ou SE sem WREN | Quadro de gravação ou apagar com a escrita desabilitada no chip |
| PP ou SE abaixo de `protect_below` | Gravação ou apagar no bitstream |
| Instrução fora da lista | Qualquer código que não seja um dos sete |
| Instrução diferente de RDSR durante a gravação | O controlador não esperou o fim da operação |
| Quadro que termina fora de byte | Erro do mestre SPI |

## 10. Exemplo em C

```c
#include <stdint.h>

/* Base do periférico no mapa da plataforma (a definir na integração). */
#define EPCS_BASE  ((volatile uint32_t *)0x40001000u)

enum { STATUS, CONTROL, ADDRESS, LENGTH, COMMAND, ID, USER_BASE, SIZE,
       BUFIDX, BUFDATA };
enum { CMD_RDID = 1, CMD_RDSR, CMD_WREN, CMD_READ, CMD_PP, CMD_SE };
enum { ST_BUSY = 1u << 0, ST_DONE = 1u << 1, ST_ERR = 1u << 2 };

static int epcs_run(uint32_t cmd)
{
    EPCS_BASE[COMMAND] = cmd;
    while (EPCS_BASE[STATUS] & ST_BUSY) {
    }
    uint32_t status = EPCS_BASE[STATUS];
    EPCS_BASE[STATUS] = ST_DONE | ST_ERR;
    return (status & ST_ERR) ? -1 : 0;
}

/* Lê o identificador do chip (0 em caso de erro). */
uint32_t epcs_id(void)
{
    return epcs_run(CMD_RDID) == 0 ? EPCS_BASE[ID] & 0xFFFFFFu : 0;
}

/* Lê até 256 bytes de qualquer endereço do chip. */
int epcs_read(uint32_t addr, uint8_t *dst, uint32_t len)
{
    EPCS_BASE[ADDRESS] = addr;
    EPCS_BASE[LENGTH] = len;
    if (epcs_run(CMD_READ) != 0) {
        return -1;
    }
    EPCS_BASE[BUFIDX] = 0;
    for (uint32_t i = 0; i < len; i += 4) {
        uint32_t word = EPCS_BASE[BUFDATA];
        for (uint32_t b = 0; b < 4 && i + b < len; b++) {
            dst[i + b] = (uint8_t)(word >> (8 * b));
        }
    }
    return 0;
}

/* Apaga o setor de 64 KB que contém addr (precisa estar na região de usuário). */
int epcs_erase_sector(uint32_t addr)
{
    EPCS_BASE[ADDRESS] = addr;
    if (epcs_run(CMD_WREN) != 0) {
        return -1;
    }
    return epcs_run(CMD_SE);
}

/* Grava até 256 bytes dentro de uma página da região de usuário. */
int epcs_program_page(uint32_t addr, const uint8_t *src, uint32_t len)
{
    EPCS_BASE[BUFIDX] = 0;
    for (uint32_t i = 0; i < len; i += 4) {
        uint32_t word = 0xFFFFFFFFu;
        for (uint32_t b = 0; b < 4 && i + b < len; b++) {
            word &= ~(0xFFu << (8 * b));
            word |= (uint32_t)src[i + b] << (8 * b);
        }
        EPCS_BASE[BUFDATA] = word;
    }
    EPCS_BASE[ADDRESS] = addr;
    EPCS_BASE[LENGTH] = len;
    if (epcs_run(CMD_WREN) != 0) {
        return -1;
    }
    return epcs_run(CMD_PP);
}
```

Uma página só aceita bits que vão de 1 para 0, então a região precisa ter sido apagada antes de gravar. O endereço de uma gravação abaixo de `USER_BASE` (registrador 6) é recusado.

## 11. Verificação

| Verificação | Cobertura |
| :--- | :--- |
| Entrada `EpcsCtrl` de `tests/python/tests.json`, módulo `tests.python.unittests.rom.epcs_ctrl`, sobre o banco `epcs_ctrl_tb` | Registradores constantes; RDID e RDSR; Ler e FAST_READ em várias regiões contra o padrão do modelo; Ler fora do chip ou com tamanho inválido; Gravar e Apagar sem WREN sem quadro algum; apagar de um setor e espera do chip; gravação de página como E bit a bit; página inteira; bitstream protegido contra Gravar e Apagar; Gravar que atravessa a página; comando com o controlador ocupado; interrupção. Todo teste confere que o modelo não marcou violação |
| Prova formal `formal/epcs_ctrl/run.sh` | Ver [blocks](../formal/blocks.md): nos pinos SPI, só as sete instruções saem, PP e SE só depois de um WREN terminado, só na região de usuário, o SE alinhado ao setor e o PP sem sair da página, com mutantes |
| Síntese no Quartus 25.1 | Controlador e invólucro, ajustados em EP4CE22F17C6 (594 elementos lógicos), EP4CE115F29C7 (580), 5CSEBA6U23I7 (244 ALMs) e 5CEBA4F23C7 (245 ALMs), 232 registradores e 2048 bits de memória em todos |

## 12. Referência

| Fonte | Conteúdo |
| :--- | :--- |
| Manual da DE10-Nano, seções 2.1, 2.2 e 3.2 | EPCS64 de configuração |
| Manual da DE0-Nano, seção 1.1 e demonstração de EPCS | EPCS64 Spansion; a EPCS precisa ser apagada antes de ser gravada |
| Manuais da DE0-CV (seção 3.1) e da DE2-115 (seção 4.1) | EPCS64 de configuração |
| `altserial_flash_loader` do Quartus 25.1 | Ligação dos blocos ASMI das famílias Cyclone IV E e Cyclone V |

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
