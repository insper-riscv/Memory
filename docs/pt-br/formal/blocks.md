# Verificação formal dos demais blocos

🌐 [Português](../../pt-br/formal/blocks.md) · [English](../../en/formal/blocks.md)

Além do árbitro da SDRAM e das pontes AXI (`formal.md`), as provas cobrem o controlador da SDRAM, a ponte do núcleo, as duas caches, o roteador de região, o árbitro da flash, a porta de comandos do chip de FLASH, os controladores de FLASH NOR e de SRAM e a máquina de contagem de latência dos modelos de memória. O método é o do `formal.md` (GHDL sintetiza a netlist, o Yosys lê as propriedades em SystemVerilog, o SymbiYosys roda o motor escolhido), cada bloco tem a sua pasta `formal/<bloco>/` com `props.sv` e `run.sh`, e as provas compartilham as vagas de `formal/common.sh`. As memórias pequenas das caches viram registradores (`memory_map` depois do `prep`) antes de qualquer engine, porque o yices trata cada memória inferida como um array SMT e não termina as provas do `icache` e do `dcache` em 600 s; com os registradores o `make formal` leva cerca de 2 min com o yices e 1 min com os outros. Uma prova que um engine não termina em `FORMAL_TIMEOUT` segundos (600 por padrão) vira skip nesse engine e fica para os outros.

## 1. O que se prova

| Bloco | Prova | Propriedades |
| :--- | :--- | :--- |
| `flash_arbiter` | indução, limitada (40 ciclos) e cover | Nunca os dois mestres recebem a resposta juntos; só o dono recebe a resposta e dirige o canal da flash; o dado da flash chega inteiro aos dois mestres; todo pedido é atendido em até 6 ciclos, e 5 não bastam, qualquer que seja o outro mestre (sem inanição) |
| `flash_cmd_port` | limitada (40 ciclos) e cover | Só escreve ocupado, com o latch armado e em setor sem proteção; o apagar escreve só uns e a gravação escreve o E bit a bit do conteúdo com a palavra do buffer; comando sem latch é ignorado por inteiro; setor protegido ou fora da janela recusa, derruba o latch e sobe a recusa; proteger e desproteger mexem só no bit do setor; a operação ocupa o chip por no máximo 14 ciclos (apagar) ou 8 (gravar); no ciclo em que o chip desocupa sai o pulso, com a região exata das palavras escritas, em ordem e alinhada ao setor ou à página |
| `latency_counter` | indução e cover | O fim da contagem sobe só na borda $N$ depois da carga (a contagem 0 vale 1), a espera cobre as bordas anteriores, uma carga na borda do fim reinicia a contagem, sem carga o bloco volta a ficar livre e um reset a zera; o registrador de contagem guarda as bordas que faltam |
| `nor_flash_ctrl` | limitada e cover, por cenário (leitura, apagar, gravar um byte, comandos) em duas configurações de ciclos | Nunca `WE#` e `OE#` juntos, `CE#` baixo quando um deles está, o dado só dirigido na escrita; cada fase do ciclo de escrita, a espera de $t_{busy}$ e o pulso de `RESET#` duram o número de ciclos dos generics; a sequência de ciclos do chip (desbloqueio, comando, setor ou byte e dado do buffer, em ordem, sem byte `0xFF`) e a espera de `RY` alto antes de seguir; escrita só com o latch armado e em setor sem proteção; o pulso de invalidação traz a região exata e baixa o latch; na leitura, o endereço avança de um a cada $n_{next}$ ciclos depois de $n_{first}$, o byte lido é o do pino no último ciclo e o contrato do `flash_chip` vale; recusa, comando ignorado e proteção como no `flash_cmd_port` |
| `max10_flash` | limitada (40 ciclos) e cover | A megafunção nunca recebe uma gravação sem a escrita habilitada, nem um apagar sem ela ou fora dos setores 1 e 2, nem uma palavra de controle que não seja liberar, proteger ou apagar um setor (nunca uma página); um pedido por vez; a escrita habilitada sobe só depois de uma escrita de liberação e cai só com reset ou com a proteção |
| `epcs_ctrl` | limitada (120 e 150 ciclos) e cover, por cenário (apagar, gravar) | Nos pinos SPI, só as sete instruções saem (nenhum apagar do chip todo, nenhuma escrita do registrador de estado); PP e SE só depois de um WREN terminado e sem outro PP ou SE no meio; o endereço de PP e SE na região de usuário e dentro do chip; o do SE de início de setor; o SE de quatro bytes e o PP de um a 256 bytes de dado sem sair da página; o clock baixo com o chip desmarcado |
| `sram_ctrl` | limitada e cover, por cenário (leitura, escrita) em duas configurações de ciclos | Nunca `WE#` e `OE#` juntos, `CE#` baixo quando um deles está, o dado só dirigido na escrita; a leitura habilita os dois bytes e a escrita só os do habilita de bytes, nunca nenhum; cada fase dura o número de ciclos dos generics; as meias palavras saem em ordem crescente dentro do pedido, a vigiada com o habilita e o dado certos, uma só vez; o dado que o núcleo recebe é o do pino no último ciclo da meia palavra e só muda no avanço; acesso fora da janela não toca no chip |
| `mem_region_router` | indução e cover | Fora da flash o acesso inteiro vai ao resto da memória; na flash só leituras dentro da janela chegam à flash; escrita na flash e leitura além da janela terminam no roteador, devolvem zero e respondem no ciclo seguinte; no máximo um destino por acesso |
| `sdram_cpu_bridge` | limitada (30 ciclos) e cover | Um pedido novo só sai com a ponte livre, o núcleo pedindo e a inicialização sincronizada, e todo pedido vira uma inversão do toggle; a carga útil vista pelo controlador é a do núcleo e se mantém; o pronto só vem depois da resposta, dura até o avanço e há uma resposta por pedido; a resposta só é vista dois ciclos depois do ack (o cruzamento passa pelo `synchronizer`); o dado de leitura é o capturado quando a resposta foi vista |
| `sdram_ctrl` | limitada (150 ciclos) e cover | Espera de inicialização, PRECHARGE de todos os bancos, oito REFRESH e LOAD MODE com o registrador de modo, nesta ordem e antes do primeiro acesso; tRP, tRFC, tMRD, tRCD e tRC entre os comandos; refresh dentro do período mais o tempo de um acesso em curso; todo pedido respondido, só com o toggle certo |
| `icache` | limitada (28 ciclos) e cover, nas larguras 26 e 27 da janela da tag (`FORMAL_WINDOWS`) | Um acerto no endereço vigiado devolve o dado que a memória de baixo deu; o pedido à memória de baixo é de uma linha alinhada; depois de uma invalidação, nenhum acerto antes de um preenchimento novo; depois de uma invalidação por região que cobre a linha vigiada e troca o dado dela, o acerto devolve o dado novo (inclusive o de um preenchimento que estava em andamento), e uma região fora do índice da linha não derruba o acerto que a cache já tinha |
| `dcache` (write-through) | limitada (24 ciclos) e cover, nas larguras 26 e 27 da janela da tag (`FORMAL_WINDOWS`) | Todo store aceito chega à memória de baixo uma vez, com os bytes certos, antes de ser reconhecido; um load da palavra vigiada devolve a última escrita, venha do acerto ou do preenchimento; os pedidos à memória de baixo são bem formados; um flush com invalidação deixa as linhas inválidas; depois de uma invalidação por região que cobre a linha vigiada e troca o dado dela, um load devolve o dado novo, inclusive quando o preenchimento estava em andamento |

## 2. Suposições sobre o ambiente

| Bloco | Suposição |
| :--- | :--- |
| Todos | Um clock de reset no início e nenhum depois; o núcleo mantém o pedido e o endereço até a resposta e consome a resposta no ciclo em que ela chega |
| `flash_arbiter` | A flash responde só a um pedido ativo, em até 2 ciclos |
| `flash_cmd_port` | Chip de 64 bytes, setores de 16 bytes, páginas de 8 bytes e esperas de 1 ciclo; uma palavra vigiada qualquer do armazenamento guarda o valor que a escrita lhe dá e a leitura registrada o devolve, e o buffer de página devolve um valor qualquer na posição dela; as demais palavras são livres |
| `latency_counter` | `max_count` igual a 6; o pulso de carga, o valor e o reset são livres, com o valor até 6 e um clock de reset no início |
| `nor_flash_ctrl` | Chip de 8 KB com dois setores de 4 KB e páginas de 8 bytes; configuração A com um ciclo em cada fase e B com 3, 2, 2, 3, 5, 2 e 3; o dado do chip, o `RY`, o comando e o pedido de leitura são livres, e o buffer de página devolve uma palavra qualquer na posição vigiada e `0xFFFFFFFF` na outra; cada cenário liga só as entradas que usa e, na gravação, limita o buffer a um byte a gravar |
| `max10_flash` | O barramento de registradores, a espera, a validade do dado lido, o dado lido e a leitura do CSR da megafunção são livres; endereço de dados de 4 bits |
| `epcs_ctrl` | Chip de 128 KB (dois setores de 64 KB), região de usuário a partir de 64 KB e clock SPI na metade do clock do sistema; o MISO é livre, o barramento só escreve `ADDRESS`, `LENGTH` e `COMMAND` e nunca manda ler (o buffer fica fixo) |
| `sram_ctrl` | Chip de 64 bytes; configuração A com um ciclo em cada fase e B com três; endereço, dado, habilita de bytes e dado do chip são livres, e o avanço só vem com o pronto |
| `sdram_cpu_bridge` | O controlador inverte o ack só para um pedido pendente, em até 3 ciclos, e segura o dado da resposta até o pedido seguinte |
| `sdram_ctrl` | O mestre inverte o toggle só depois da resposta e segura a carga até lá; a espera de 200 µs e o período de refresh encurtam para 6 e 24 ciclos, e os tempos do chip são os de `sdram_pkg` a 7 ns e, numa segunda rodada com a netlist de `tck_ps` = 10000, a 10 ns (tRCD e tRP em 2 ciclos, tRC em 6 e tRFC em 7) |
| `icache`, `dcache` | Dois clocks do `icache` ligam ao mesmo sinal; a cache tem duas linhas de 128 bits (`size_bits = 256`); um endereço vigiado qualquer faz o papel da memória de baixo, que devolve a sua palavra sempre que devolve a linha dele; os endereços do núcleo ficam na janela de 64 MiB do endereço vigiado; a memória de baixo responde em até 3 ciclos (2 no `dcache`) |
| `icache` | O núcleo mantém o endereço até a cache responder; no modo de região, a palavra vigiada da memória de baixo só muda no pulso de uma região que cobre a linha dela |
| `dcache` | Modo write-through, sem bypass, e o endereço vigiado fora da região da flash; no modo de região o núcleo só lê e a palavra vigiada da memória de baixo só muda no pulso de uma região que cobre a linha dela |

## 3. Mutantes

Cada defeito proposital do VHDL precisa fazer uma prova falhar. O `run.sh` de cada bloco aplica a edição com `sed` numa cópia do arquivo e exige o veredito `fail`.

| Bloco | Mutantes |
| :--- | :--- |
| `flash_arbiter` | `a_always_first`, `ready_to_both`, `b_release_wrong`, `owner_b_gets_a`, `data_swapped`, `rden_without_owner` |
| `flash_cmd_port` | `program_overwrites`, `erase_writes_zero`, `ignores_the_latch`, `protection_ignored`, `window_ignored`, `latch_stays`, `refusal_keeps_latch`, `short_by_one`, `stride_of_eight`, `unprotect_all`, `region_one_short`, `page_unaligned` |
| `latency_counter` | `zero_hangs`, `one_too_long`, `restart_ignored`, `last_never_ends`, `reset_ignored`, `wait_from_zero`, `last_at_two` |
| `nor_flash_ctrl` | `unlock_wrong`, `program_cmd_wrong`, `erase_cmd_wrong`, `sector_cmd_wrong`, `sector_unaligned`, `ff_not_skipped`, `window_ignored`, `protection_ignored`, `latch_ignored`, `ry_not_awaited`, `hardware_protect`, `read_stride_two`, `line_unaligned`, `region_one_short`, `data_bus_in_read`, `oe_with_we`, `we_width_wp_only`, `we_high_wc_only`, `busy_not_waited`, `page_uses_random`, `first_uses_page`, `reset_pulse_short` |
| `max10_flash` | `write_without_enable`, `erase_without_enable`, `erase_allowed_ignored`, `sector_below_allowed`, `sector_above_allowed`, `page_erase_requested`, `refusal_enables`, `disable_keeps_enable`, `enable_unprotects_none` |
| `epcs_ctrl` | `se_without_wren_frame`, `se_without_latch`, `se_below_user_region`, `se_unaligned`, `se_past_the_chip`, `pp_without_latch`, `pp_below_user_region`, `pp_crosses_the_page`, `pp_past_the_chip`, `pp_empty`, `bulk_erase_instruction`, `status_write_instruction`, `address_order_swapped` |
| `sram_ctrl` | `lanes_swapped`, `empty_half_written`, `stride_two`, `data_early`, `window_ignored`, `data_bus_in_read`, `oe_with_we`, `we_pulse_dropped`, `we_high_wc_dropped`, `read_wait_rc_only` |
| `mem_region_router` | `end_inclusive`, `write_not_local`, `slave_sees_flash`, `local_not_zero`, `local_hangs`, `flash_gets_local`, `window_by_base`, `advance_to_both` |
| `sdram_cpu_bridge` | `wrong_rdata`, `rdata_x_zero`, `init_ignored`, `ack_unsynced`, `no_advance_wait`, `write_as_read`, `address_shifted`, `request_lost`, `write_updates_rdata` |
| `sdram_ctrl` | `no_precharge`, `few_refreshes`, `init_wait_short`, `mode_wrong`, `init_done_early`, `trcd_short`, `trp_short`, `trfc_short`, `trc_short`, `refresh_never` |
| `icache` | `dropped_fill_valid`, `invalidate_keeps`, `tag_always_matches`, `ready_without_addr`, `fill_word_swapped`, `hit_without_sel`, `partial_line`, `region_ignored`, `fill_not_dropped`, `region_too_wide`, `region_one_short`, `big_region_partial` |
| `dcache` | `hit_store_not_cached`, `write_back_on_hit`, `byteena_lost`, `fill_word_swapped`, `hit_ignores_tag`, `store_acked_early`, `store_data_lost`, `inv_inverted`, `region_ignored`, `fill_stays_valid`, `fill_not_marked`, `region_one_short` |

## 4. O que as provas não cobrem

1. O tRAS não tem comando próprio: o controlador usa a precarga automática, e o tempo entre dois ACTIVE é pelo menos o tRC, que soma tRAS e tRP.
2. O `dcache` em modo write-back, o bypass, a região da flash e o flush sem invalidação: o modo da plataforma é o write-through.
3. A primeira palavra de uma linha lida logo depois de uma invalidação: o bit de validade lido tem um ciclo de atraso, e a prova vale a partir do segundo ciclo depois da invalidação.
4. O preenchimento de uma linha enquanto o núcleo pede outro endereço do mesmo índice: o núcleo precisa manter o endereço até a resposta, porque as palavras novas da linha que chega são vistas com a etiqueta e o bit de validade da linha velha enquanto ela é escrita.

---

Copyright 2026 Insper. Licenciado sob a [Apache License, Version 2.0](../../../LICENSE).
