# sdram_pkg

## 1. Função do componente no SoC

Pacote VHDL que reúne os números do chip de SDRAM da placa DE0-CV (32M x 16, 4 bancos, 13 bits de linha e 10 de coluna, grau -7, latência CAS 3) e a codificação dos comandos. O controlador e o modelo do chip leem os mesmos valores, de modo que o modelo reprova a simulação quando o controlador viola qualquer tempo do pacote. Mudar um tempo exige editar só este arquivo.

A origem de cada valor no datasheet e a comparação com os ciclos do controlador estão em [SDRAM_TIMINGS.md](../../SDRAM_TIMINGS.md).

## 2. Interface

O pacote não tem portas nem generics. Exporta constantes, uma função e nenhum tipo novo.

### 2.1. Tempos e contagens

| Constante | Valor | Significado |
| :--- | ---: | :--- |
| `T_CK_PS` | 7000 | período do clock que as contagens de ciclos assumem, em ps |
| `T_RCD_PS` | 15000 | ACTIVE até READ ou WRITE, em ps |
| `T_RP_PS` | 15000 | PRECHARGE até ACTIVE, em ps |
| `T_RAS_PS` | 42000 | ACTIVE até PRECHARGE, em ps |
| `T_RC_PS` | 60000 | ACTIVE até ACTIVE no mesmo banco, em ps |
| `T_RFC_PS` | 63000 | AUTO REFRESH até qualquer comando, em ps |
| `T_WR_PS` | 14000 | último dado de escrita até PRECHARGE, em ps |
| `T_MRD_CK` | 2 | LOAD MODE REGISTER até qualquer comando, em clocks |
| `T_INIT_PS` | 200000000 | espera com clock estável antes do primeiro comando, em ps |
| `T_REFI_PS` | 7812500 | intervalo entre refreshes, em ps |
| `INIT_REFRESHES` | 8 | comandos AUTO REFRESH da sequência de energização |
| `CAS_LATENCY` | 3 | latência CAS, em clocks |

### 2.2. Registrador de modo

`MODE_REG` tem 13 bits e é colocado no barramento de endereço durante o LOAD MODE REGISTER.

| Bits | Valor | Significado |
| :--- | :--- | :--- |
| 2 a 0 | `001` | rajada de 2 beats de 16 bits, o que forma uma palavra de 32 bits |
| 3 | `0` | rajada sequencial |
| 6 a 4 | `011` | latência CAS 3 |
| 9 | `0` | escritas também em rajada |
| 12 a 10 e 8 a 7 | `0` | reservados |

### 2.3. Comandos

Cada comando é o vetor formado por chip select, RAS, CAS e write enable, todos ativos em nível baixo.

| Constante | Código (cs, ras, cas, we) | Comando |
| :--- | :--- | :--- |
| `CMD_NOP` | `0111` | sem operação |
| `CMD_ACTIVE` | `0011` | abre uma linha |
| `CMD_READ` | `0101` | leitura |
| `CMD_WRITE` | `0100` | escrita |
| `CMD_PRECHARGE` | `0010` | fecha linhas |
| `CMD_REFRESH` | `0001` | AUTO REFRESH |
| `CMD_LOAD_MODE` | `0000` | carrega o registrador de modo |

### 2.4. Função

| Função | Parâmetros | Retorno |
| :--- | :--- | :--- |
| `cycles` | `ps` e `tck_ps`, ambos `natural` | número de clocks que cobrem `ps`, arredondado para cima |

## 3. Comportamento

A função de arredondamento é

$$
\text{cycles}(t, T_{CK}) = \left\lceil \frac{t}{T_{CK}} \right\rceil
$$

Com $T_{CK} = 7000$ ps, os tempos do pacote viram as contagens abaixo, que o controlador usa como constantes locais.

| Tempo | Ciclos |
| :--- | ---: |
| $T_{RCD}$ | 3 |
| $T_{RP}$ | 3 |
| $T_{RAS}$ | 6 |
| $T_{RC}$ | 9 |
| $T_{RFC}$ | 9 |
| $T_{WR}$ | 2 |
| $T_{INIT}$ | 28572 |
| $T_{REFI}$ | 1117 |

O controlador não usa $T_{RAS}$, porque o auto-precharge do chip já espera esse tempo antes de fechar a linha. A sequência de energização do controlador emite `INIT_REFRESHES` refreshes, e o modelo do chip exige apenas dois antes do registrador de modo, sem usar essa constante.

Todos os valores são iguais ou mais conservadores que o mínimo do datasheet, conforme a tabela de [SDRAM_TIMINGS.md](../../SDRAM_TIMINGS.md). O endereçamento do chip vem da geometria e não de constantes do pacote, e está descrito em [sdram_ctrl.md](sdram_ctrl.md).

## 4. Integração

| Quem usa | Constantes lidas |
| :--- | :--- |
| [sdram_ctrl](sdram_ctrl.md) | todos os tempos exceto $T_{RAS}$, `MODE_REG`, `CAS_LATENCY`, `INIT_REFRESHES`, os códigos `CMD_*` e `cycles` |
| [sdram_model](sdram_model.md) | todos os tempos, `MODE_REG`, `CAS_LATENCY`, os códigos `CMD_*` |
| topos de simulação do subsistema | `cycles`, `T_INIT_PS`, `T_REFI_PS` e `T_CK_PS` como valores padrão dos generics de espera e de refresh |

Em `tests/python/tests.json` o pacote vem antes do controlador e do modelo na lista de fontes de todo teste que compila um deles.

## 5. Verificação

O pacote não tem teste próprio. Os valores são exercitados pelos testes que compilam o controlador e o modelo, porque o modelo reprova a simulação com `severity failure` quando um tempo é violado.

| Teste | O que cobre dos valores |
| :--- | :--- |
| `SdramSystem` em [sdram_system.py](../../../tests/python/unittests/ram/sdram_system.py) | energização, acessos de palavra e de linha e refresh sob o modelo |
| `SdramBist` e `SdramBistRegisteredPins` em [sdram_bist.py](../../../tests/python/unittests/ram/sdram_bist.py) | o controlador sozinho sobre o modelo, com e sem registro dos pinos de dados |
| `SdramDebugPort` em [sdram_debug_port.py](../../../tests/python/unittests/ram/sdram_debug_port.py) | tráfego concorrente do núcleo e do hospedeiro |

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
