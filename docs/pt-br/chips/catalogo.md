# Catálogo de chips de memória

## 1. Finalidade

A pasta `chips/` guarda um arquivo por chip de memória que alguma placa carrega. O controlador dono dos tempos mora neste repositório, e por isso o dado de chip também mora aqui, sem depender do repositório que escolhe a placa. O Tools lê a pasta com o módulo `board_schema` e a confere com o comando `check-boards`.

## 2. Campos

| Campo | Significado |
| :--- | :--- |
| `chip` | Nome, igual ao do arquivo |
| `extends` | Opcional, nome de outro chip cujos campos este herda e sobrescreve |
| `kind` | `sdram`, `sram`, `nor` ou `serial_flash` |
| `organization` | `words` e `width`, e na SDRAM também `banks`, `row_bits` e `col_bits` |
| `cas_latency` | Latência de coluna da SDRAM |
| `timing` | Tempos com os nomes do datasheet, em picossegundos quando o nome termina em `_ps` |
| `io_timing` | Setup, hold e acesso dos pinos, em nanossegundos, usados no `.sdc` |
| `sector_bytes`, `boot_sector_bytes` | Setor de apagamento da FLASH |
| `max_mhz` | Teto de relógio do grau |
| `source` | `datasheet` ou `inferido` |

## 3. Chips do catálogo

| Chip | Tipo | Capacidade | Origem dos valores |
| :--- | :--- | ---: | :--- |
| `IS42S16320D-7` | `sdram` | 64 MiB | Datasheet; valores do controlador da DE0-CV |
| `IS42S16320B-7` | `sdram` | 64 MiB por chip | Herda o `IS42S16320D-7`; inferido |
| `IS42S16160B-7` | `sdram` | 32 MiB | Inferido da série `-7` |
| `AS4C4M16SA-7BCN` | `sdram` | 8 MiB | Peça e organização pelo esquemático; tempos inferidos da série `-7` |
| `IS61WV102416BLL-10` | `sram` | 2 MiB | Inferido |
| `S29GL064N90` | `nor` | 8 MiB | Inferido; sufixo da peça não verificado |
| `EPCS64` | `serial_flash` | 8 MiB | Inferido |
| `W25Q16DV` | `serial_flash` | 2 MiB | Inferido; peça confirmada pelo esquemático |

A capacidade de uma SDRAM da placa é a do chip vezes o número de chips em paralelo.

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
