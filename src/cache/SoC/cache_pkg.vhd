-- =============================================================================
-- Funções comuns às caches e à ponte de busca
--
-- Reúne o que as caches de instruções e de dados, a ponte de busca e o
-- roteador de região repetiam: o teste de pertinência de um endereço a uma
-- região de memória, dada por base e fim em KiB, e o número de bits do índice
-- de linha de uma cache a partir do seu tamanho em bits. Nenhuma das duas
-- funções guarda estado, e as duas valem em elaboração e em síntese.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.config_pkg.all;
use work.utils_pkg.all;

package cache_pkg is

    -- Devolve '1' quando o endereço de byte está em [base_kib, end_kib) KiB, ou seja, base_kib * 1024
    -- <= addr < end_kib * 1024; com base igual ao fim a região é vazia e o resultado é sempre '0'.

    pure function in_window (
        addr : addr_t;
        base_kib : natural;
        end_kib : natural
    ) return std_logic;

    -- Bits do índice da linha: o tamanho em bits dividido pelos 128 bits de uma linha, em logaritmo
    -- exato (falha se o tamanho não for uma potência de dois ou se não couberem duas linhas de 128
    -- bits).

    pure function index_bits_of (bits : positive) return natural;

end package cache_pkg;

package body cache_pkg is

    pure function in_window (
        addr : addr_t;
        base_kib : natural;
        end_kib : natural
    ) return std_logic is
    begin

        if unsigned(addr) >= shift_left(to_unsigned(base_kib, ADDR_BITS), 10) and
           unsigned(addr) < shift_left(to_unsigned(end_kib, ADDR_BITS), 10) then
            return '1';
        end if;

        return '0';

    end function in_window;

    pure function index_bits_of (bits : positive) return natural is
    begin

        assert bits >= 256
            report "size_bits must hold at least two lines of 128 bits"
            severity failure;
        return log2_exact(bits) - 7;

    end function index_bits_of;

end package body cache_pkg;
