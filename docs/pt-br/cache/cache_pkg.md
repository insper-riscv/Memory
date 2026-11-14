# cache_pkg

Funções que as caches, a ponte de busca e o roteador de região compartilham, para que a pertinência de um endereço a uma região e a largura do índice de linha existam uma só vez.

Os endereços dos blocos de memória são do tipo `addr_t` e a palavra de dados do núcleo é `word_t`, ambos do `config_pkg` de Common-Components, de modo que as larguras seguem `ADDR_BITS` e `XLEN` da plataforma. As janelas de endereço das caches vêm do mapa da plataforma (`FLASH_BASE`, `FLASH_END`, `RAM_BASE`, `RAM_END`, `I_CACHE_WINDOW_BITS` e `D_CACHE_WINDOW_BITS`), passadas pelos generics de cada bloco.

A linha de uma cache e os registradores `_x` que a carregam usam `XLEN` e `3 * XLEN` bits, e o byte enable usa `XLEN / 8` bits. As larguras físicas de dispositivo e de protocolo ficam em 32 bits: o barramento de dados do chip da FLASH e da SDRAM, a palavra do bloco de RAM, os registradores do JTAG, o BIST e os modelos de chip. Os blocos que ligam o núcleo a esses dispositivos (caches, ifetch_bridge, mem_region_router, controladores de FLASH, SRAM e SDRAM, `onchip_ram_port`, `ram_chip` e as duas pontes AXI) fazem a fatiação da palavra e supõem a palavra de 4 bytes e a linha de 16 bytes no mapa de bits do endereço, então só elaboram com `XLEN = 32` e falham a elaboração com um valor maior.

## 1. Função do componente no SoC

Cada bloco que separa a região da FLASH das demais testa o endereço contra a mesma faixa, e as duas caches calculam a largura do índice de linha do mesmo modo. O pacote reúne as duas contas. Ele não guarda estado, vale em elaboração e em síntese e não tem portas.

| Bloco | Uso |
| :--- | :--- |
| [icache](icache.md) | `in_window` na tag e no preenchimento, `index_bits_of` no tamanho da memória de linhas |
| [dcache](dcache.md) | `in_window` na tag, na escrita e na leitura de linha, `index_bits_of` no tamanho da memória de linhas |
| [ifetch_bridge](ifetch_bridge.md) | `in_window` no endereço do pedido à memória |
| [mem_region_router](mem_region_router.md) | `in_window` na seleção da região da FLASH |

## 2. Interface

O pacote não tem generics nem portas. Cada função é pura e recebe os parâmetros abaixo.

### 2.1. Função `in_window`

| Parâmetro | Tipo | Faixa | Significado |
| :--- | :--- | :--- | :--- |
| `addr` | `addr_t` | 0 a $2^{ADDR\_BITS}-1$ | Endereço de byte testado |
| `base_kib` | `natural` | 0 a $2^{22}-1$ | Primeiro KiB da região |
| `end_kib` | `natural` | 0 a $2^{22}-1$ | KiB seguinte ao último da região |
| retorno | `std_logic` | `'0'` ou `'1'` | `'1'` quando o endereço está na região |

$$ \text{in\_window} = \begin{cases} \texttt{'1'} & 1024 \cdot \text{base\_kib} \le \text{addr} < 1024 \cdot \text{end\_kib} \\ \texttt{'0'} & \text{caso contrário} \end{cases} $$

Com `base_kib` igual a `end_kib` a região é vazia e o resultado é sempre `'0'`. Os padrões das caches são `base_kib` 524288 e `end_kib` 1048576, a região da FLASH de `0x20000000` a `0x3FFFFFFF`.

### 2.2. Função `index_bits_of`

| Parâmetro | Tipo | Faixa | Significado |
| :--- | :--- | :--- | :--- |
| `bits` | `positive` | potência de dois, no mínimo 256 | Tamanho da memória de dados da cache, em bits |
| retorno | `natural` | no mínimo 1 | Bits do índice de linha |

$$ \text{index\_bits\_of}(b) = \log_2 b - 7 $$

A linha tem 128 bits, então $b \ge 256$ garante duas linhas no mínimo. Um tamanho que não é potência de dois, ou menor que 256, falha a elaboração.

## 3. Verificação

| Verificação | Cobertura |
| :--- | :--- |
| Entrada `CachePkg` de `tests/python/tests.json`, módulo `tests.python.unittests.cache.cache_pkg`, testbench `tests/vhdl/cache_pkg_tb.vhd` | Endereço uma unidade abaixo da base, igual à base, uma unidade acima, uma unidade abaixo do fim, igual ao fim e uma unidade acima; região vazia; região que termina no último KiB do espaço de endereços; larguras de índice de 256 bits a 1 Mibit |
| Provas formais de `icache`, `dcache` e `mem_region_router` | Compilam o pacote junto com a entidade, e os mutantes que trocam a pertinência à região continuam pegos |

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
