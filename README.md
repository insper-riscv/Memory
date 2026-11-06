# Memory

🌐 [Português](README.md) · [English](README.en.md)

Memórias do SoC RISC-V RV32: os blocos de memória que o núcleo lê e escreve. O núcleo, os periféricos, os topos que os conectam e os programas de teste ficam em outros repositórios da organização [insper-riscv](https://github.com/insper-riscv).

## 1. Documentação

- [AUTHORS.md](AUTHORS.md): autores com commits no repositório, com nome e conta do GitHub.
- [CONTRIBUTING.md](CONTRIBUTING.md): regras obrigatórias de contribuição, norma VHDL-2008, nomenclatura, cabeçalhos, normas Python e verificação antes de abrir Pull Request.
- [CITATION.cff](CITATION.cff): metadados para citação do software.
- [contracts/02-barramento-e-memoria.md](https://github.com/insper-riscv/Core/blob/main/docs/pt-br/contracts/02-barramento-e-memoria.md): protocolo de barramento e de memória compartilhado por todas as famílias.
- [contrato-de-memoria.md](docs/pt-br/contracts/contrato-de-memoria.md): contrato de uma memória (pinos, tempo, clock e palavra de largura diferente da do core).
- Documentação por componente, uma por bloco, em português (`docs/pt-br/`) e em inglês (`docs/en/`), agrupada por tipo.
  - `docs/pt-br/cache/` (caches e roteamento de região): [dcache](docs/pt-br/cache/dcache.md), [icache](docs/pt-br/cache/icache.md), [ifetch_bridge](docs/pt-br/cache/ifetch_bridge.md), [mem_region_router](docs/pt-br/cache/mem_region_router.md), [flash_arbiter](docs/pt-br/cache/flash_arbiter.md).
  - `docs/pt-br/ram/` (SDRAM, RAM externa e RAM interna): [sdram_ctrl](docs/pt-br/ram/sdram_ctrl.md), [sdram_arbiter](docs/pt-br/ram/sdram_arbiter.md), [sdram_cpu_bridge](docs/pt-br/ram/sdram_cpu_bridge.md), [sdram_pkg](docs/pt-br/ram/sdram_pkg.md), [sdram_model](docs/pt-br/ram/sdram_model.md), [sdram_bist](docs/pt-br/ram/sdram_bist.md), [sdram_dbg_master](docs/pt-br/ram/sdram_dbg_master.md), [sdram_jtag_core](docs/pt-br/ram/sdram_jtag_core.md), [ram_chip](docs/pt-br/ram/ram_chip.md), [ram](docs/pt-br/ram/ram.md), [ram_simulation](docs/pt-br/ram/ram_simulation.md), [onchip_ram_port](docs/pt-br/ram/onchip_ram_port.md).
  - `docs/pt-br/rom/` (FLASH, BOOT_MEMORY e modelo da ROM): [flash_chip](docs/pt-br/rom/flash_chip.md), [flash_cmd_port](docs/pt-br/rom/flash_cmd_port.md), [boot_memory](docs/pt-br/rom/boot_memory.md), [flash](docs/pt-br/rom/flash.md), [flash_loader](docs/pt-br/rom/flash_loader.md), [flash_jtag_core](docs/pt-br/rom/flash_jtag_core.md), [flash_simulation](docs/pt-br/rom/flash_simulation.md), [flash_store](docs/pt-br/rom/flash_store.md), [rom_simulation](docs/pt-br/rom/rom_simulation.md).
  - `docs/pt-br/latency/` (contagem de latência dos modelos emulados): [latency_counter](docs/pt-br/latency/latency_counter.md).
  - `docs/pt-br/barramento/` (pontes AXI4): [axi_master_bridge](docs/pt-br/barramento/axi_master_bridge.md), [axi_slave_word_bridge](docs/pt-br/barramento/axi_slave_word_bridge.md).
- Documentos de projeto (decisões, protocolo, verificação e defeitos corrigidos) em `docs/pt-br/barramento/` ([dcache_axi](docs/pt-br/barramento/dcache_axi.md), [dcache_axi_decisions](docs/pt-br/barramento/dcache_axi_decisions.md)), em `docs/pt-br/ram/` ([sdram_debug](docs/pt-br/ram/sdram_debug.md), [sdram_line](docs/pt-br/ram/sdram_line.md), [sdram_subword_read](docs/pt-br/ram/sdram_subword_read.md), [sdram_timings](docs/pt-br/ram/sdram_timings.md), [sdram_clock_crossing](docs/pt-br/ram/sdram_clock_crossing.md)), em `docs/pt-br/formal/` ([formal](docs/pt-br/formal/formal.md), [blocks](docs/pt-br/formal/blocks.md)) e em `docs/pt-br/bugs/` (um documento por defeito). Os documentos por componente linkam para eles. O interconector externo e a UART sobre JTAG ficam documentados no Insper-RISC-V e no Peripherals.

## 2. Estrutura do Repositório

| Caminho | Conteúdo |
| :--- | :--- |
| `src/common/` | Submódulo Common-Components, editado só na origem |
| `src/cache/SoC/` | Cache de instruções, ponte de busca de instrução sem cache e cache de dados da SDRAM, roteador por região, árbitro da FLASH, modelo do chip de FLASH e a porta de comandos dele (`flash_cmd_port`, que apaga, grava e protege); `sim/` guarda os sistemas de teste das caches |
| `src/RAM/SoC/` | Controlador da SDRAM da placa (32M x 16, 64 MB), ponte entre o clock do núcleo e o do controlador, árbitro que divide a SDRAM entre o núcleo e o mestre de depuração ([docs/pt-br/ram/sdram_debug.md](docs/pt-br/ram/sdram_debug.md)) e um pacote com os tempos do chip. `src/RAM/SoC/sim/` guarda o modelo do chip, que reprova a simulação quando o controlador quebra uma regra dele, e os topos que o ligam ao controlador. O `onchip_ram_port` põe o bloco de RAM interna da FPGA atrás do mesmo contrato de linha da memória externa, para uma RAM interna poder ficar atrás de cache ([docs/pt-br/ram/onchip_ram_port.md](docs/pt-br/ram/onchip_ram_port.md)) |
| `src/latency/SoC/` | Máquina de contagem de latência (`latency_counter`) que o modelo do chip de FLASH, o modelo da RAM externa e o adaptador da RAM interna compartilham |
| `src/RAM/FPGA/Cyclone-V/` | IP Quartus `RAM`, só para a placa |
| `src/RAM/FPGA/debug/sdram/` | Núcleo Virtual JTAG (`sdram_jtag_core`) e mestre de depuração (`sdram_dbg_master`) que deixam um hospedeiro ler e escrever a SDRAM pela JTAG, só para a placa |
| `src/ROM/SoC/` | Modelo de simulação da ROM em VHDL puro com array que o cocotb consegue ler (`rom_simulation`), modelo da FLASH de duas portas (`flash_simulation`), carregador da FLASH pela JTAG (`flash_loader`, com a porta JTAG `flash_jtag_core`) e, em `sim/`, o topo que os liga (`flash_system`) |
| `src/ROM/Cyclone-V/` | IPs Quartus (`altsyncram`) da ROM: `BOOT_MEMORY` (gravada uma vez), `FLASH` (a única cópia da FLASH interna, de duas portas, reescrita pelo carregador JTAG a cada teste) e `FLASH_STORE`, mais a casca Virtual JTAG do carregador (`flash_jtag_shell`, só para a placa). Também simulam no GHDL pelos modelos `altera_mf` da Intel |
| `src/barramento/SoC/` | As duas pontes AXI4 genéricas, que só dependem do contrato de memória do core: o mestre (`axi_master_bridge`, do core para um escravo AXI4) e o escravo de palavra (`axi_slave_word_bridge`, AXI4 na frente de uma memória), com o sistema de teste em `sim/`. O interconector externo, o roteador AXI4 e o banco de periféricos decodificam o mapa da plataforma e conhecem os periféricos, então ficam no Insper-RISC-V, em `src/interconnect/` |
| `src/tests/` | Autoteste da SDRAM (`teste_sdram`), que dirige o controlador sozinho em modos rápido, padrões, varredura do chip inteiro e aleatório, e o sistema que o liga ao modelo do chip (`teste_sdram_system`) |
| `tests/python/` | Testes por entidade em cocotb, em `unittests/{cache,ram,rom,barramento}`, e o catálogo (`tests.json`) que os conduz |
| `tests/vhdl/` | Banco de teste do controlador da SDRAM (`sdram_ctrl_tb`) |
| `formal/` | Propriedades em SystemVerilog e scripts das provas, uma pasta por bloco, e o agregador dos engines ([documentação](docs/pt-br/formal/formal.md)) |
| `docs/pt-br/`, `docs/en/` | Um documento por componente, agrupado em `cache`, `ram`, `rom` e `barramento`, mais `contracts`, `formal` e `bugs` |

## 3. Famílias de Memória


Há três famílias que compartilham uma única interface de escravo: modelos de simulação, IPs internos da FPGA e memória externa (RAM fora da FPGA, com controladores de vários ciclos), esta última em `src/RAM/SoC/`, onde a SDRAM é a primeira. Toda memória interna responde em um ciclo; o sinal `ready` só integra a interface com a memória externa. Os tempos do chip em `src/RAM/SoC/sdram/sdram_pkg.vhd` são os da folha de dados do chip, listados em `docs/pt-br/ram/sdram_timings.md`.

Os tamanhos dos IPs devem coincidir com o mapa de memória da plataforma (`src/simulation/internal-mem/platform.yaml` do [Insper-RISC-V](https://github.com/insper-riscv/Insper-RISC-V)), verificado ali por `make memory-map`.

## 4. Verificação e Execução

### 4.1. Execução local

```bash
git clone --recurse-submodules https://github.com/insper-riscv/Memory.git
cd Memory
uv sync

make check   # Verificação de sintaxe VHDL dos modelos e das memórias (GHDL)
make test    # Testes por entidade em cocotb (make test TEST=RAM para um alvo)
make paths   # Caminhos do paths.yaml e árvore do repositório (riscv-tools check-tree)
make formal  # Provas formais (SymbiYosys) com o engine de FORMAL_ENGINE (bitwuzla por padrão)
```

Os IPs de `Cyclone-V/` não são analisados no `make check`, pois exigem a biblioteca `altera_mf` da Intel, ausente da imagem; a simulação do topo de hardware no [Insper-RISC-V](https://github.com/insper-riscv/Insper-RISC-V) os cobre.

### 4.2. Execução via Docker

A imagem `ghcr.io/insper-riscv/ci-vhdl:latest` publicada pelo repositório [insper-riscv/Infra](https://github.com/insper-riscv/Infra) já traz o GHDL (backend LLVM), Yosys, SymbiYosys, os solvers Yices, Bitwuzla e Boolector, `uv`, Python 3.14 e cocotb pré-instalados:

```bash
docker run --rm -v "$PWD:/workspace" -w /workspace ghcr.io/insper-riscv/ci-vhdl:latest \
  bash -c "uv sync && make check && make test && make paths && make formal"
```

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](LICENSE).
