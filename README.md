# Memory

🌐 [Português](README.md) · [English](README.en.md)

Memórias do SoC RISC-V RV32: os blocos de memória que o núcleo lê e escreve. O núcleo, os periféricos, os topos que os conectam e os programas de teste ficam em outros repositórios da organização [insper-riscv](https://github.com/insper-riscv).

## 1. Documentação

- [AUTHORS.md](AUTHORS.md): autores com commits no repositório, com nome e conta do GitHub.
- [CONTRIBUTING.md](CONTRIBUTING.md): regras obrigatórias de contribuição, norma VHDL-2008, nomenclatura, cabeçalhos, normas Python e verificação antes de abrir Pull Request.
- [CITATION.cff](CITATION.cff): metadados para citação do software.
- [contracts/02-barramento-e-memoria.md](https://github.com/insper-riscv/Core/blob/main/docs/pt-br/contracts/02-barramento-e-memoria.md): protocolo de barramento e de memória compartilhado por todas as famílias.

## 2. Estrutura do Repositório

| Caminho | Conteúdo |
| :--- | :--- |
| `src/common/` | Submódulo Common-Components, editado só na origem |
| `src/cache/soc/` | Cache de instruções e cache de dados da SDRAM, roteador por região, árbitro da FLASH e modelo do chip de FLASH; `sim/` guarda os sistemas de teste das caches |
| `src/ram/soc/` | Controlador da SDRAM da placa (32M x 16, 64 MB), ponte entre o clock do núcleo e o do controlador, autoteste que dirige o controlador sozinho (modos rápido, padrões, varredura do chip inteiro e aleatório), árbitro e mestre de depuração que deixam um hospedeiro ler e escrever a SDRAM por JTAG enquanto um núcleo a usa ([docs/SDRAM_DEBUG.md](docs/SDRAM_DEBUG.md); `src/ram/cyclone-v/` guarda a casca Virtual JTAG, só para a placa) e um pacote com os tempos do chip. `src/ram/soc/sim/` guarda o modelo do chip, que reprova a simulação quando o controlador quebra uma regra dele, e um topo que liga os três |
| `src/ram/cyclone-v/` | IP Quartus `RAM1PORT` e a casca Virtual JTAG do controle de depuração da SDRAM, só para a placa |
| `src/rom/soc/` | Modelo de simulação da ROM em VHDL puro com array que o cocotb consegue ler (`rom_simulation`) |
| `src/rom/cyclone-v/` | IPs Quartus (`altsyncram`) da ROM: `BOOT_ROM1PORT` (gravada uma vez), `FLASH1PORT` e `FLASH_MEM1PORT` (as duas cópias físicas da FLASH, reescritas por JTAG a cada teste) e `FLASH_STORE1PORT`. Também simulam no GHDL pelos modelos `altera_mf` da Intel |
| `src/barramento/soc/` | Interconector externo e a família de pontes AXI4 (mestre, roteador, escravo de palavra e banco de periféricos), com os sistemas de teste em `sim/` |
| `tests/python/` | Testes por entidade em cocotb, em `unittests/{cache,ram,rom,barramento}`, e o catálogo (`tests.json`) que os conduz |

## 3. Famílias de Memória


Há três famílias que compartilham uma única interface de escravo: modelos de simulação, IPs internos da FPGA e memória externa (RAM fora da FPGA, com controladores de vários ciclos), esta última em `src/ram/soc/`, onde a SDRAM é a primeira. Toda memória interna responde em um ciclo; o sinal `ready` só integra a interface com a memória externa. Os tempos do chip em `src/ram/soc/sdram_pkg.vhd` são os da folha de dados do chip, listados em `docs/SDRAM_TIMINGS.md`.

Os tamanhos dos IPs devem coincidir com o mapa de memória da plataforma (`Tests/platforms/internal-mem.yaml`), verificado por `riscv-tools check-memory-map`.

## 4. Verificação e Execução

```bash
git clone --recurse-submodules https://github.com/insper-riscv/Memory.git
cd Memory
uv sync

make check   # Verificação de sintaxe VHDL dos modelos de simulação (GHDL)
make test    # Testes por entidade em cocotb (make test TEST=RAM para um alvo)
make paths   # Existência de todos os caminhos listados na configuração
```

As ferramentas (GHDL e uv) vêm da imagem `ci-vhdl` do repositório [Infra](https://github.com/insper-riscv/Infra), onde a integração contínua executa. Os IPs não são analisados aqui, pois exigem a biblioteca `altera_mf` da Intel, ausente da imagem; a simulação do topo de hardware em [Tests](https://github.com/insper-riscv/Tests) os cobre.

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](LICENSE).
