# Depuração de Memória

Este guia descreve como o hospedeiro (o computador ligado à placa) alcança as memórias do SoC por JTAG, para trocar o programa entre testes e para ler os resultados depois da execução. Cada memória tem no máximo um caminho, e cada bloco que não tem caminho é citado com o motivo.

## 1. Quem tem JTAG

| Memória | Tem JTAG | Caminho | Leitura | Escrita | Uso |
| :--- | :---: | :--- | :---: | :---: | :--- |
| BOOT_ROM ([boot_rom1port](../rom/boot_rom1port.md)) | não | Gravada uma vez na compilação, com o `boot_rom_init.mif` | não | não | Carregador de partida |
| FLASH ([flash_store1port](../rom/flash_store1port.md)) | sim | Editor de memória do Quartus (seção 2) | sim | sim | Trocar o programa entre testes |
| RAM interna ([ram1port](../ram/ram1port.md)) | sim | Editor de memória do Quartus (seção 2) | sim | sim | Zerar a RAM e conferir o resultado nos desenhos sem SDRAM |
| SDRAM ([sdram_ctrl](../ram/sdram_ctrl.md)) | sim | Porta de depuração da SDRAM (seção 3) | sim | sim | Conferir o resultado e carregar dados |
| Caches ([dcache](../cache/dcache.md) e [icache](../cache/icache.md)) | não | Ficam entre o core e a memória e não têm lógica de JTAG | não | não | Não se aplica |
| Árbitros ([sdram_arbiter](../ram/sdram_arbiter.md) e [flash_arbiter](../cache/flash_arbiter.md)) | não | O `sdram_arbiter` carrega o acesso da depuração como o mestre B, e o `flash_arbiter` não está no caminho de nenhuma regravação | não | não | Não se aplica |

## 2. Editor de memória (FLASH e RAM interna)

Os IPs de memória do FPGA que declaram `ENABLE_RUNTIME_MOD=YES` e um `INSTANCE_NAME` aparecem como instâncias do In-System Memory Content Editor do Quartus. O hospedeiro abre uma sessão com `quartus_stp`, escolhe a instância pelo índice e lê ou escreve o conteúdo do bloco. Nenhum pino do IP participa, porque o editor acessa o bloco por dentro.

| Operação | O que faz |
| :--- | :--- |
| Escrita inteira | Sobrescreve a profundidade toda de uma instância a partir de um `.mif`, inclusive em várias instâncias numa só sessão |
| Escrita de uma palavra | Troca uma palavra num offset |
| Leitura de palavras | Lê de volta um intervalo |
| Dump | Salva o conteúdo inteiro de uma instância num `.mif` |

Duas regras valem para o editor.

1. O índice de cada instância segue a ordem de instanciação no topo da plataforma, e a plataforma fixa os índices no `config.yaml` (`quartus.rom_mem_instances` para a FLASH e `quartus.ram_mem_instance` para a RAM interna). Um IP sem `ENABLE_RUNTIME_MOD` não ocupa índice.
2. A escrita vai direto no bloco de memória, sem passar por cache, árbitro nem pelo modelo do chip. O hardware não a coordena com o core. O fluxo de teste a faz entre as execuções e reinicia o core depois, escrevendo o `fromhost` pelo HTIF.

A FLASH do desenho de memória interna tem duas cópias físicas com o mesmo conteúdo ([flash1port](../rom/flash1port.md) e [flash_mem1port](../rom/flash_mem1port.md)), e a escrita atualiza as duas na mesma sessão. As ferramentas do hospedeiro são os módulos [mem_edit](https://github.com/insper-riscv/Tools/blob/main/docs/pt-br/modules/mem_edit.md), [rom_writer](https://github.com/insper-riscv/Tools/blob/main/docs/pt-br/modules/rom_writer.md) e [ram_dump](https://github.com/insper-riscv/Tools/blob/main/docs/pt-br/modules/ram_dump.md) da Tools.

## 3. Porta de depuração da SDRAM

A SDRAM fica fora do FPGA, então o editor de memória não a alcança. A porta de depuração é um segundo acesso ao controlador, ligado ao mesmo árbitro do core, e o hospedeiro a dirige por uma instância de Virtual JTAG.

| Etapa | Bloco | Clock | Função |
| :---: | :--- | :--- | :--- |
| 1 | `sdram_jtag_shell` | JTAG | Casca com a instância de Virtual JTAG, só para a placa |
| 2 | [sdram_jtag_core](../ram/sdram_jtag_core.md) | JTAG | Desloca o comando de 64 bits, devolve o estado do comando anterior e pede o comando ao mestre |
| 3 | [sdram_dbg_master](../ram/sdram_dbg_master.md) | Do controlador | Executa o comando, lendo, escrevendo ou preenchendo palavras |
| 4 | [sdram_arbiter](../ram/sdram_arbiter.md) | Do controlador | Serializa o acesso da depuração (mestre B) com os do core |
| 5 | [sdram_ctrl](../ram/sdram_ctrl.md) | Do controlador | Acessa o chip |

A passagem da etapa 2 para a 3 cruza os domínios de clock por inversão de sinal, como descreve o [contrato de memória](../contracts/contrato-de-memoria.md). O registrador de dados tem 64 bits, e o formato completo está em [sdram_jtag_core](../ram/sdram_jtag_core.md). Os comandos do mestre são os seguintes.

| Comando | Efeito |
| :---: | :--- |
| 0 | Nada, só devolve o estado |
| 1 | Lê a palavra no endereço |
| 2 | Escreve o dado na palavra do endereço, com os bytes escolhidos pela máscara |
| 3 | Preenche uma quantidade de palavras consecutivas com o dado |
| 4 | Define a quantidade do preenchimento, até a SDRAM inteira |
| 5 | Lê a palavra seguinte à última acessada |
| 6 | Escreve na palavra seguinte à última acessada |

O estado devolvido traz, entre outros bits, o bit 0 (`busy`, o comando anterior ainda não terminou) e o bit 1 (o controlador não respondeu). O endereço é de palavra de 32 bits contado a partir da base da SDRAM. O hospedeiro usa os módulos [sdram_debug](https://github.com/insper-riscv/Tools/blob/main/docs/pt-br/modules/sdram_debug.md) e [ram_target](https://github.com/insper-riscv/Tools/blob/main/docs/pt-br/modules/ram_target.md) da Tools, e a plataforma escolhe esse caminho com `quartus.ram_backend: sdram_debug`. O protocolo completo está em [SDRAM_DEBUG.md](../../SDRAM_DEBUG.md).

## 4. Coerência com as caches

A porta de depuração lê e escreve a SDRAM por baixo da cache de dados. Duas consequências valem para o hospedeiro.

| Sentido | Situação | Como é tratada |
| :--- | :--- | :--- |
| O hospedeiro lê o que o programa escreveu | Uma cache write-back guardaria o dado em linhas sujas, e a leitura veria a memória antiga | A cache de dados da plataforma é write-through, então todo store chega à SDRAM antes de completar |
| O hospedeiro escreve e o core lê depois | A cache pode guardar uma linha antiga do mesmo endereço | A cache começa vazia depois do reset, e a carga é feita antes de o core rodar |

O primeiro caso foi o defeito descrito em [CACHE_HOST_COHERENCE.md](../../bugs/CACHE_HOST_COHERENCE.md).

## 5. Fluxo de um teste

| Passo | Ação | Caminho |
| :---: | :--- | :--- |
| 1 | Gravar o programa na FLASH | Editor de memória |
| 2 | Carregar os dados do teste na SDRAM, se houver | Porta de depuração da SDRAM |
| 3 | Reiniciar o core | Escrita do `fromhost` pelo HTIF |
| 4 | Esperar o fim do programa | Leitura do `tohost` pelo HTIF |
| 5 | Ler o resultado | Dump da RAM, que na SDRAM guarda só as palavras que o golden nomeia |
| 6 | Comparar com o golden | Módulo `mem_validator` |

O `tohost` e o `fromhost` ficam dentro da RAM, então usam o mesmo caminho de acesso dela, que é o editor de memória nos desenhos sem SDRAM e a porta de depuração nos desenhos com SDRAM.

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
