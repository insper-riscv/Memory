# ram_pkg

Tradução do endereço de byte de um acesso para o deslocamento dentro da janela de um chip de memória, escrita uma só vez para as memórias de janela.

## 1. Função do componente no SoC

Uma memória de chip ocupa uma janela dentro da região de 64 MiB, a partir de `base_kib` KiB. O endereço do acesso usa os 26 bits baixos, e o deslocamento na janela é a diferença entre esse endereço e a base. O pacote não tem portas nem estado e vale em elaboração e em síntese.

| Bloco | Uso |
| :--- | :--- |
| [ram_chip](ram_chip.md) | Índice de palavra do acesso, depois de testar a base |
| [sram_ctrl](sram_ctrl.md) | Teste de fora da janela e deslocamento do acesso à SRAM |
| [onchip_ram_port](onchip_ram_port.md) | Deslocamento do acesso ao bloco de RAM, depois de testar a base |

## 2. Interface

O pacote não tem generics nem portas. A função é pura.

### 2.1. Função `window_offset`

| Parâmetro | Tipo | Faixa | Significado |
| :--- | :--- | :--- | :--- |
| `addr` | `std_logic_vector(31 downto 0)` | 0 a $2^{32}-1$ | Endereço de byte do acesso; só os 26 bits baixos contam |
| `base_kib` | `natural` | 0 a 65535 | Base da janela dentro da região, em KiB |
| retorno | `unsigned(25 downto 0)` | 0 a $2^{26}-1$ | Deslocamento em bytes dentro da janela |

$$ \text{window\_offset} = \left(\text{addr}[25{:}0] - 1024 \cdot \text{base\_kib}\right) \bmod 2^{26} $$

Abaixo da base o resultado dá a volta em 26 bits. Quem usa a função testa a base antes, ou compara o resultado com o tamanho do chip, que é como cada bloco da tabela decide se o acesso está fora da janela.

## 3. Verificação

| Verificação | Cobertura |
| :--- | :--- |
| Entrada `RamPkg` de `tests/python/tests.json`, módulo `tests.python.unittests.ram.ram_pkg`, testbench `tests/vhdl/ram_pkg_tb.vhd` | Base zero; base de 512 KiB com o endereço igual à base, logo depois e longe dela; endereço abaixo da base, que dá a volta; bits acima dos 26 baixos ignorados |
| Entradas `RamChipOffset`, `OnchipRamOffset` e `SramCtrl` | O pacote em uso dentro de cada memória com base diferente de zero |

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
