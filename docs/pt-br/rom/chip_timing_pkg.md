# chip_timing_pkg

Tempos de datasheet dos chips de memória de dispositivo (FLASH NOR e SRAM assíncrona) e a conversão de um tempo em ciclos de clock, lidos pelos controladores e pelos modelos de chip.

## 1. Função do componente no SoC

Um controlador de dispositivo conta, em ciclos do clock da memória, cada tempo que o chip exige. O pacote reúne os tempos num lugar só, em nanossegundos, e é o padrão dos generics de [nor_flash_ctrl](nor_flash_ctrl.md), [nor_flash_model](nor_flash_model.md), [sram_ctrl](../ram/sram_ctrl.md) e [sram_model](../ram/sram_model.md). O controlador e o modelo de um mesmo chip partem, assim, dos mesmos números, e o modelo mede em tempo de simulação o que o controlador contou em ciclos.

A fonte dos valores é o [catálogo de chips](../chips/catalogo.md), nos arquivos `chips/S29GL064N90.yaml` e `chips/IS61WV102416BLL-10.yaml`. O pacote é a forma que o VHDL lê, e `tests/python/check_chip_timing.py`, chamado por `make check`, falha se uma constante diferir do catálogo. Quem usa outro chip troca o valor do generic na instância e não edita uma constante dentro de uma entidade.

## 2. Tempos

Todos os valores estão em ns e valem para a DE2-115. Nenhum foi lido num datasheet: as peças e os tempos são `inferido` na ficha da placa, que os deduz de memória dos datasheets e de fóruns, e o esquemático e a pasta de datasheets do CD da placa os confirmam.

### 2.1. FLASH NOR S29GL064N90 (modo byte)

| Constante | Valor | Significado |
| :--- | ---: | :--- |
| `NOR_T_ACC_NS` | 90 | Acesso aleatório e de CE# |
| `NOR_T_PACC_NS` | 25 | Acesso dentro da página de 16 bytes |
| `NOR_T_OE_NS` | 35 | OE# baixo até o dado |
| `NOR_T_WC_NS` | 90 | Ciclo de escrita |
| `NOR_T_WP_NS` | 35 | Largura do pulso de WE# |
| `NOR_T_WPH_NS` | 30 | WE# alto entre dois pulsos |
| `NOR_T_DS_NS` | 45 | Dado estável antes da subida de WE# |
| `NOR_T_AH_NS` | 45 | Endereço estável depois da descida de WE# |
| `NOR_T_BUSY_NS` | 90 | Subida de WE# até a descida de RY# |
| `NOR_T_RP_NS` | 500 | Largura do pulso de RESET# |
| `NOR_T_RH_NS` | 50 | Subida de RESET# até o primeiro acesso |
| `NOR_T_PROG_NS` | 60000 | Gravação de um byte, típico |
| `NOR_T_ERASE_NS` | 500000000 | Apagar de um setor de 64 KB, típico |

### 2.2. SRAM IS61WV102416BLL-10

| Constante | Valor | Significado |
| :--- | ---: | :--- |
| `SRAM_T_AA_NS` | 10 | Acesso por endereço |
| `SRAM_T_RC_NS` | 10 | Ciclo de leitura |
| `SRAM_T_WC_NS` | 10 | Ciclo de escrita |
| `SRAM_T_SCE_NS` | 8 | CE# baixo até o fim da escrita |
| `SRAM_T_AW_NS` | 8 | Endereço válido até o fim da escrita |
| `SRAM_T_PWE_NS` | 8 | Largura do pulso de WE# |
| `SRAM_T_SD_NS` | 6 | Dado válido antes da subida de WE# |
| `SRAM_T_HA_NS` | 0 | Endereço mantido depois da subida de WE# |
| `SRAM_T_HD_NS` | 0 | Dado mantido depois da subida de WE# |

## 3. Conversão em ciclos

`cycles_of(t_ns, period_ns, margin_ns)` devolve o número de ciclos que cobrem o tempo $t$ mais a margem $m$ de pino e de placa, no mínimo um:

$$ n = \max\left(1, \left\lceil \frac{t + m}{T} \right\rceil\right) $$

`max_natural(a, b)` devolve o maior de dois naturais, porque o Quartus Lite não traz a função `maximum` do VHDL-2008 para `natural`. É a única cópia: o `flash_cmd_port` e o `sdram_ctrl` também a importam daqui.

## 4. Referência

| Fonte | Conteúdo |
| :--- | :--- |
| `Plans/Multi-FPGA/placas/de2-115.md`, seções 5.2 e 5.3 | Peças, larguras, endereços e tempos da SRAM e da FLASH, cada um com o selo `confirmado` ou `inferido` |
| `chips/*.yaml` | Campo `timing` de cada chip, com os nomes `access_ns`, `page_access_ns`, `write_cycle_ns` e os demais |
| `Plans/Multi-FPGA/01-ARQUITETURA.md`, seção 4 | A latência de um backend de dispositivo, $n_{ciclos} = \lceil t_{chip} / T \rceil$ |
| Datasheets Spansion S29GL064N90 e ISSI IS61WV102416BLL-10 | Origem dos valores, a conferir na pasta `DE2_115_datasheets` do CD da placa |

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
