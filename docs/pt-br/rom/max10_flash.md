# max10_flash

Controlador de barramento da flash interna de usuário do MAX 10 da DE10-Lite, sobre a megafunção `altera_onchip_flash` do Quartus.

## 1. Função do componente no SoC

O MAX 10 10M50DA da DE10-Lite tem 5.888 Kbits de flash interna (manual da DE10-Lite, seção 1.3), que guardam o bitstream e, no que sobra, dados de usuário. A megafunção `altera_onchip_flash` expõe essa flash por duas interfaces Avalon-MM, uma de dados (leitura e escrita de uma palavra de 32 bits) e uma de registradores de controle e estado (CSR). O `max10_flash` entrega ao software um banco de oito registradores sobre as duas, de modo que ler uma palavra, gravar uma palavra e apagar um setor são comandos de um registrador, com estado ocupado e interrupção de fim de operação.

| Aspecto | Valor |
| :--- | :--- |
| Dispositivo | 10M50DAF484C7G |
| Configuração do IP gerado | Imagem única sem compressão e interface de dados paralela |
| Espaço de dados | 17 bits de endereço de palavra de 32 bits |
| Setor 1 (UFM1) | Palavras 0 a 8191, leitura e escrita |
| Setor 2 (UFM0) | Palavras 8192 a 16383, leitura e escrita |
| Setor 3 (CFM2, usado como flash de usuário) | Palavras 16384 a 114687, só leitura nessa geração |
| Setores 4 e 5 (CFM1 e CFM0) | Ocultos nesse modo; o IP os classifica como flash de configuração |

O controlador só apaga os setores liberados pelo generic `erase_allowed`, cujo padrão é os setores 1 e 2. O setor 3 fica só de leitura no IP gerado, e os setores 4 e 5, classificados pelo IP como flash de configuração, nem aparecem no espaço de dados.

## 2. Interface

### 2.1. Generics

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | ---: | :--- |
| `data_addr_bits` | `positive` | 17 | Largura do endereço de palavra da interface de dados da megafunção |
| `erase_allowed` | vetor de 5 bits | `00011` | O bit $k-1$ libera o apagar do setor $k$ |

### 2.2. Portas do barramento

| Porta | Direção | Largura | Significado |
| :--- | :--- | ---: | :--- |
| `i_clk` | entrada | 1 | Clock do módulo, o mesmo da megafunção |
| `i_rst` | entrada | 1 | Reset síncrono, ativo em `'1'` |
| `i_address` | entrada | 3 | Índice do registrador |
| `i_write` | entrada | 1 | Escrita no registrador |
| `i_read` | entrada | 1 | Leitura do registrador |
| `i_data_in` | entrada | 32 | Dado de escrita |
| `o_data_out` | saída | 32 | Dado de leitura, combinacional sobre `i_address` |
| `o_irq` | saída | 1 | Concluído com a interrupção habilitada |

### 2.3. Portas da megafunção

| Porta | Direção | Significado |
| :--- | :--- | :--- |
| `o_data_read`, `o_data_write` | saída | Pedido de dados, mantido até `i_data_wait` cair |
| `o_data_addr`, `o_data_wdata` | saída | Endereço de palavra e palavra a escrever |
| `i_data_wait` | entrada | O pedido ainda não foi aceito |
| `i_data_rvalid`, `i_data_rdata` | entrada | Palavra lida e sua validade |
| `o_csr_read`, `o_csr_write` | saída | Pedido ao CSR, de um ciclo |
| `o_csr_addr` | saída | `'0'` registrador de estado, `'1'` registrador de controle |
| `o_csr_wdata` | saída | Palavra de controle a escrever |
| `i_csr_rdata` | entrada | Palavra lida do CSR, válida um ciclo depois do pedido de leitura |

## 3. Registradores

| Índice | Nome | Acesso | Conteúdo |
| ---: | :--- | :--- | :--- |
| 0 | `STATUS` | leitura e escrita de 1 para limpar | Bit 0 ocupado, bit 1 concluído, bit 2 erro, bit 3 escrita habilitada. Escrever `'1'` nos bits 1 ou 2 limpa o bit |
| 1 | `CONTROL` | leitura e escrita | Bit 0 habilita a interrupção |
| 2 | `ADDRESS` | leitura e escrita | Endereço de palavra no espaço de dados |
| 3 | `DATA` | leitura e escrita | Palavra a gravar, e depois de uma leitura, a palavra lida |
| 4 | `SECTOR` | leitura e escrita | Número do setor a apagar, de 1 a 5 |
| 5 | `COMMAND` | escrita | Código do comando (seção 4) |
| 6 | `IP_STATUS` | leitura | Registrador de estado bruto da megafunção (10 bits) |
| 7 | reservado | leitura | Lê zero |

## 4. Comandos

| Código | Comando | Efeito |
| ---: | :--- | :--- |
| 1 | Ler | Lê a palavra em `ADDRESS` para `DATA` e confere o bit de leitura passou da megafunção |
| 2 | Gravar | Grava `DATA` em `ADDRESS` e confere o bit de escrita passou |
| 3 | Apagar | Apaga o setor de `SECTOR`, espera o fim pelo controle e pelo estado, confere o bit de apagamento passou e protege tudo de novo |
| 4 | Habilitar | Libera a escrita dos cinco setores no controle da megafunção e sobe o bit de escrita habilitada |
| 5 | Desabilitar | Protege os cinco setores e derruba o bit de escrita habilitada |

Qualquer outro código é ignorado. A megafunção nasce com todos os setores protegidos.

### 4.1. Regras de recusa

Um comando recusado sobe o bit de erro e não toca a megafunção.

| Situação | Resultado |
| :--- | :--- |
| Comando escrito com o controlador ocupado | Erro, o comando em andamento termina normalmente |
| Gravar ou apagar com a escrita desabilitada | Erro |
| Apagar um setor fora de 1 a 5 ou fora de `erase_allowed` | Erro |
| A megafunção acusa falha de leitura, escrita ou apagamento | Concluído com erro |

O apagar termina devolvendo a proteção, então o bit de escrita habilitada cai e o próximo gravar ou apagar pede um novo comando Habilitar.

## 5. Sequência de um comando

1. O software escreve `ADDRESS`, `DATA` e `SECTOR` conforme o comando.
2. O software escreve o código em `COMMAND`.
3. O bit de ocupado sobe e só cai no fim da operação, quando o bit de concluído sobe (e o de erro, se houve falha).
4. O software lê `DATA` (no comando Ler), limpa os bits de concluído e erro e segue.

A megafunção segura o pedido de dados até a espera cair, e o estado de uma operação de escrita ou apagamento é consultado por leitura repetida do CSR. O tempo de uma gravação e de um apagamento é o da megafunção, que carrega os limites de tempo do chip (para a 10M50, 305 µs de gravação e 350 ms de apagamento, valores do código gerado e não do manual da placa).

## 6. IP gerado e invólucro

O controlador não instancia a megafunção. O invólucro fino `max10_flash_ip` (`src/ROM/MAX-10/max10_flash_ip.vhd`) declara por `component` o IP `max10_flash_core`, gerado pelo Platform Designer por `src/ROM/MAX-10/max10_flash_core.tcl`, e expõe as portas com a polaridade do controlador. Para gerar o IP:

```bash
qsys-script --script=src/ROM/MAX-10/max10_flash_core.tcl
qsys-generate max10_flash_core.qsys --synthesis=VHDL --part=10M50DAF484C7G
```

O projeto Quartus inclui o `max10_flash_core.qip` gerado. O invólucro está em `tree.vhdl_style.exclude` do `paths.yaml`, porque a primitiva não consta de `vendor_primitives.yaml` do `riscv-tools`.

## 7. Modelo de simulação

O `max10_flash_model` reproduz, nas portas Avalon-MM e nos registradores do CSR, o comportamento descrito na seção 5: a flash nasce apagada, uma gravação só leva bits de 1 para 0 e o apagar de setor devolve uns, uma escrita ou um apagar em setor protegido não altera o conteúdo e deixa o bit de passou em zero, e a leitura do CSR chega um ciclo depois do pedido. Os tempos de gravação e de apagamento são generics. O modelo não representa o apagar de página, a proteção de leitura por setor, o burst e os tempos reais do chip.

## 8. Exemplo em C

```c
#include <stdint.h>

/* Base do periférico no mapa da plataforma (a definir na integração). */
#define MAX10_FLASH_BASE  ((volatile uint32_t *)0x40000000u)

enum { STATUS, CONTROL, ADDRESS, DATA, SECTOR, COMMAND, IP_STATUS };
enum { CMD_READ = 1, CMD_WRITE, CMD_ERASE, CMD_ENABLE, CMD_DISABLE };
enum { ST_BUSY = 1u << 0, ST_DONE = 1u << 1, ST_ERR = 1u << 2 };

static int flash_run(uint32_t cmd)
{
    MAX10_FLASH_BASE[COMMAND] = cmd;
    while (MAX10_FLASH_BASE[STATUS] & ST_BUSY) {
    }
    uint32_t status = MAX10_FLASH_BASE[STATUS];
    MAX10_FLASH_BASE[STATUS] = ST_DONE | ST_ERR;
    return (status & ST_ERR) ? -1 : 0;
}

/* Lê uma palavra da flash de usuário; devolve 0 e a palavra em *out. */
int flash_read_word(uint32_t word_addr, uint32_t *out)
{
    MAX10_FLASH_BASE[ADDRESS] = word_addr;
    if (flash_run(CMD_READ) != 0) {
        return -1;
    }
    *out = MAX10_FLASH_BASE[DATA];
    return 0;
}

/* Apaga o setor (1 ou 2) e grava uma palavra nele. */
int flash_erase_and_write(uint32_t sector, uint32_t word_addr, uint32_t value)
{
    if (flash_run(CMD_ENABLE) != 0) {
        return -1;
    }
    MAX10_FLASH_BASE[SECTOR] = sector;
    if (flash_run(CMD_ERASE) != 0) {
        return -1;
    }
    if (flash_run(CMD_ENABLE) != 0) {
        return -1;
    }
    MAX10_FLASH_BASE[ADDRESS] = word_addr;
    MAX10_FLASH_BASE[DATA] = value;
    int rc = flash_run(CMD_WRITE);
    flash_run(CMD_DISABLE);
    return rc;
}
```

## 9. Verificação

| Verificação | Cobertura |
| :--- | :--- |
| Entrada `Max10Flash` de `tests/python/tests.json`, módulo `tests.python.unittests.rom.max10_flash`, sobre o banco `max10_flash_tb` | Estado após o reset; leitura de palavra apagada; leitura fora da flash com erro; gravar recusado sem habilitar; habilitar, gravar, ler de volta e desabilitar; gravação como E bit a bit; apagar de um setor sem tocar no outro; recusas do apagar; comando com o controlador ocupado; interrupção |
| Prova formal `formal/max10_flash/run.sh` | Ver [blocks](../formal/blocks.md): a megafunção nunca recebe uma gravação, um apagar ou uma palavra de controle fora das três permitidas, qualquer que seja o software e a resposta dela, com mutantes |
| Síntese no Quartus 25.1 | `10M50DAF484C7G`, controlador e IP: 661 elementos lógicos, 338 registradores e o bloco de flash de usuário (1 de 1) |

## 10. Referência

| Fonte | Conteúdo |
| :--- | :--- |
| Manual da DE10-Lite, seção 1.3 e capítulo 6 | 5.888 Kbits de flash de usuário e a configuração interna do MAX 10 |
| `altera_onchip_flash` do Quartus 25.1 (cabeçalho `altera_onchip_flash_regs.h` e Verilog do IP) | Registradores de estado e de controle do CSR e protocolo das interfaces Avalon-MM |

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
