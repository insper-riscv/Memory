# Gera o IP max10_flash_core (a megafunção de flash on-chip do MAX 10 da DE10-Lite) com o Platform Designer:
#   qsys-script --script=max10_flash_core.tcl && qsys-generate max10_flash_core.qsys --synthesis=VHDL --part=10M50DAF484C7G
# O sistema gerado exporta as duas interfaces Avalon-MM da megafunção (dados e CSR), o clock e o reset, que
# o max10_flash_ip liga ao controlador max10_flash. Os cinco setores têm acesso de leitura e escrita nos dois da
# flash de usuário e só leitura nos demais (a proteção real é a do max10_flash, que só apaga os setores liberados).
package require -exact qsys 25.1

create_system max10_flash_core
set_project_property DEVICE_FAMILY "MAX 10"
set_project_property DEVICE 10M50DAF484C7G

add_instance clk clock_source
set_instance_parameter_value clk clockFrequency 50000000
set_instance_parameter_value clk clockFrequencyKnown true

add_instance flash altera_onchip_flash
set_instance_parameter_value flash CONFIGURATION_MODE "Single Uncompressed Image"
set_instance_parameter_value flash CONFIGURATION_SCHEME "Internal Configuration"
set_instance_parameter_value flash DATA_INTERFACE "Parallel"
set_instance_parameter_value flash READ_BURST_MODE "Incrementing"
set_instance_parameter_value flash CLOCK_FREQUENCY 50.0

add_connection clk.clk flash.clk
add_connection clk.clk_reset flash.nreset

add_interface clk clock sink
set_interface_property clk EXPORT_OF clk.clk_in
add_interface reset reset sink
set_interface_property reset EXPORT_OF clk.clk_in_reset
add_interface data avalon slave
set_interface_property data EXPORT_OF flash.data
add_interface csr avalon slave
set_interface_property csr EXPORT_OF flash.csr

save_system max10_flash_core.qsys
