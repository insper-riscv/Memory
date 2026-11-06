# block_ram

🌐 [Português](../../pt-br/block_ram/block_ram.md) · [English](../../en/block_ram/block_ram.md)

Memória em bloco da FPGA, de uma ou duas portas, que encapsula o megafunção `altsyncram` da Intel e é a única instância dele no repositório.

## 1. Função do componente

`boot_memory`, `flash`, `flash_store` e `ram` são instâncias desta entidade e só diferem nos genéricos que passam. O generic map do `altsyncram` existe numa só entidade, em `src/block_ram/altera/` (pasta de fornecedor), e as quatro memórias não repetem os parâmetros que têm em comum.

A entidade precisa da biblioteca `altera_mf` do Quartus, ausente da imagem de ferramentas, e por isso o `make check` não a analisa. A simulação do topo de hardware no Insper-RISC-V a elabora com os modelos `altera_mf` da Intel.

## 2. Interface

### 2.1. Generics

| Generic | Tipo | Padrão | Significado |
| :--- | :--- | :--- | :--- |
| `operation_mode` | `string` | `"SINGLE_PORT"` | `"SINGLE_PORT"` (só a porta A) ou `"BIDIR_DUAL_PORT"` (as portas A e B leem e escrevem) |
| `word_count` | `positive` | 1024 | Quantidade de palavras |
| `address_width` | `positive` | 10 | Largura do endereço de palavra |
| `data_width` | `positive` | 32 | Largura da palavra, múltipla de `byte_lanes` |
| `byte_lanes` | `positive` | 1 | Bytes habilitáveis por palavra na escrita da porta A (1 escreve a palavra inteira; mais de 1 só no modo de uma porta) |
| `init_file` | `string` | `"UNUSED"` | Arquivo `.mif` de inicialização |
| `instance_name` | `string` | `""` | Nome da instância para o editor de conteúdo em sistema do Quartus; vazio não expõe a memória pela JTAG |
| `block_depth` | `natural` | 0 | Palavras por bloco (`maximum_depth`); 0 deixa o Quartus escolher |
| `device_family` | `string` | `"Cyclone V"` | Família do dispositivo para o Quartus |

### 2.2. Portas

| Porta | Direção | Largura | Padrão | Significado |
| :--- | :--- | ---: | :--- | :--- |
| `i_clk_a` | entrada | 1 | `'1'` | Clock da porta A |
| `i_address_a` | entrada | `address_width` | | Índice da palavra da porta A |
| `i_byteena_a` | entrada | `byte_lanes` | todos `'1'` | Habilita de bytes da escrita da porta A |
| `i_data_a` | entrada | `data_width` | zeros | Dado de escrita da porta A |
| `i_rden_a` | entrada | 1 | `'1'` | Habilita a leitura da porta A |
| `i_wren_a` | entrada | 1 | `'0'` | Habilita a escrita da porta A |
| `o_q_a` | saída | `data_width` | | Palavra lida pela porta A |
| `i_clk_b` | entrada | 1 | `'1'` | Clock da porta B |
| `i_address_b` | entrada | `address_width` | zeros | Índice da palavra da porta B |
| `i_data_b` | entrada | `data_width` | zeros | Dado de escrita da porta B |
| `i_rden_b` | entrada | 1 | `'1'` | Habilita a leitura da porta B |
| `i_wren_b` | entrada | 1 | `'0'` | Habilita a escrita da porta B |
| `o_q_b` | saída | `data_width` | | Palavra lida pela porta B, zero no modo de uma porta |

As portas B são ignoradas no modo de uma porta.

## 3. Comportamento

A leitura é síncrona e a saída não tem registrador: o endereço é capturado na borda de subida do clock da porta e a palavra aparece na saída logo depois dela, com um ciclo de latência. Numa leitura e escrita no mesmo endereço da mesma porta, a leitura devolve o dado novo (`NEW_DATA_NO_NBE_READ`).

Os parâmetros do `altsyncram` que não dependem dos genéricos são fixos: `clock_enable_*` em `BYPASS`, `outdata_reg_*` em `UNREGISTERED`, `outdata_aclr_*` em `NONE` e `power_up_uninitialized` em `FALSE`. O Quartus rejeita parâmetros e portas que o modo não usa (`clock1`, `byteena_a` e `byte_size` com um só byte, e os parâmetros da porta B no modo de uma porta). Por isso a arquitetura tem três ramos de geração (uma porta com a palavra inteira, uma porta com escrita por byte e duas portas), e cada ramo só cita o que o seu modo usa. A síntese de cada instância é a de um `altsyncram` escrito à mão: a DE0-CV mantém os mesmos registradores e bits de memória em bloco. A escrita por byte (`byte_lanes` maior que 1) só existe no modo de uma porta.

Com `instance_name` não vazio, o `lpm_hint` vira `ENABLE_RUNTIME_MOD=YES,INSTANCE_NAME=<nome>`. O Quartus Lite não aceita essa opção em duas portas.

## 4. Onde é usado

| Instância | Modo | `byte_lanes` | `init_file` | `instance_name` |
| :--- | :--- | ---: | :--- | :--- |
| [boot_memory](../rom/boot_memory.md) | uma porta | 1 | `./boot_memory_init.mif` | |
| [flash](../rom/flash.md) | duas portas | 1 | `./init.mif` | |
| [flash_store](../rom/flash_store.md) | uma porta | 1 | `./flash_init.mif` | `FLASH` |
| [ram](../ram/ram.md) | uma porta | 4 | | `RAM` |

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
