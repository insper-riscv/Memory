# Tempos da SDRAM

## 1. O chip e a fonte

A DE0-CV tem uma SDRAM SDR de 512 Mbit (32M x 16). Os tempos vêm da tabela de características AC e da tabela de frequência de operação e latência do datasheet ISSI IS42/45S16320D (Rev. B1, 14/02/2025), coluna `-7`, latência CAS 3. O código impresso no chip de cada placa deve ser conferido contra o grau `-7`.

## 2. Datasheet contra o controlador

| Parâmetro | Datasheet `-7`, CL3 | Constante em `sdram_pkg` | Ciclos a 7 ns |
| :--- | :--- | :--- | ---: |
| Período do clock (tCK3) | 7 ns no mínimo | `T_CK_PS` = 7000 | 1 |
| ACTIVE até READ ou WRITE (tRCD) | 15 ns, 3 ciclos | `T_RCD_PS` = 15000 | 3 |
| PRECHARGE até ACTIVE (tRP) | 15 ns, 3 ciclos | `T_RP_PS` = 15000 | 3 |
| ACTIVE até PRECHARGE (tRAS) | 37 ns no mínimo, 6 ciclos | `T_RAS_PS` = 42000 | 6 |
| ACTIVE até ACTIVE no mesmo banco, e REF até REF (tRC) | 60 ns, 9 ciclos | `T_RC_PS` = 60000 e `T_RFC_PS` = 63000 | 9 |
| Último dado de escrita até PRECHARGE (tDPL) | 14 ns, 2 ciclos | `T_WR_PS` = 14000 | 2 |
| LOAD MODE REGISTER até qualquer comando (tMRD) | 14 ns, 2 ciclos | `T_MRD_CK` = 2 | 2 |
| Refresh | 8192 ciclos em 64 ms | `T_REFI_PS` = 7812500 | 1116 |
| Espera de energização antes do primeiro comando | 100 us | `T_INIT_PS` = 200 us | |
| Comandos AUTO REFRESH na energização | pelo menos 2 | `INIT_REFRESHES` = 8 | |
| Latência CAS | 3 a 143 MHz | `CAS_LATENCY` = 3 | |

Toda constante é igual ao valor do datasheet ou mais conservadora. As contagens de ciclos que o controlador deriva das constantes são iguais às da tabela de frequência e latência do datasheet para o grau `-7` em CL3 (tRCD 3, tRAS 6, tRP 3, tRC 9, tDPL 2, tMRD 2).

## 3. O que a tabela não cobre

1. O setup e o hold das entradas nos pinos (tAS, tAH, tDS, tDH, tCMS, tCMH, todos com 1,5 ns de setup e 0,8 ns de hold) e o tempo de acesso da saída (tAC3 = 5,4 ns) dependem dos atrasos nos pinos e da fase do clock até o chip. O deslocamento de fase da PLL da plataforma e a análise de tempo do Quartus os cobrem, e não este pacote.
2. O controlador mantém uma linha aberta de cada vez, então o espaçamento entre bancos (tRRD = 14 ns) não se aplica.
3. Os parâmetros de self-refresh e de power-down (tXSR, tDDE) não são usados.
