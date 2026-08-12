# Starter timing constraints for soc_top backend runs.
# Default assumption: external clk is 50 MHz, period = 20 ns.
# Adjust the period and IO budgets to match the backend spec before signoff.

set CLK_PERIOD 20.000
set IO_IN_DELAY  2.000
set IO_OUT_DELAY 2.000

create_clock -name clk -period $CLK_PERIOD [get_ports clk]
set_clock_uncertainty -setup 0.200 [get_clocks clk]
set_clock_uncertainty -hold  0.100 [get_clocks clk]
set_input_transition 0.200 [get_ports clk]

# The reset pin is asynchronous to clk.  It is synchronized inside the design.
set_false_path -from [get_ports reset]

# Board switches/buttons and UART RX are asynchronous user/external inputs.
# They should be synchronized in RTL; constrain them as async at top-level STA.
set_false_path -from [get_ports {touch_btn[*] dip_sw[*] UART_RX}]

# UART TX is a slow external serial output.  Keep a loose IO budget so the pad
# path is still visible without making it a system-clock interface.
set_output_delay -clock [get_clocks clk] $IO_OUT_DELAY [get_ports UART_TX]

# External SRAM interface.  These are placeholders for the board/memory timing
# budget; refine them from the SRAM datasheet and board delay if this is used
# for final signoff.
set_input_delay  -clock [get_clocks clk] $IO_IN_DELAY  [get_ports {base_ram_data[*] ext_ram_data[*]}]
set_output_delay -clock [get_clocks clk] $IO_OUT_DELAY [get_ports {base_ram_data[*] ext_ram_data[*]}]
set_output_delay -clock [get_clocks clk] $IO_OUT_DELAY [get_ports {base_ram_addr[*] base_ram_be_n[*]}]
set_output_delay -clock [get_clocks clk] $IO_OUT_DELAY [get_ports {base_ram_ce_n base_ram_oe_n base_ram_we_n}]
set_output_delay -clock [get_clocks clk] $IO_OUT_DELAY [get_ports {ext_ram_addr[*] ext_ram_be_n[*]}]
set_output_delay -clock [get_clocks clk] $IO_OUT_DELAY [get_ports {ext_ram_ce_n ext_ram_oe_n ext_ram_we_n}]

# Video and board display outputs.
set_output_delay -clock [get_clocks clk] $IO_OUT_DELAY [get_ports {video_red[*] video_green[*] video_blue[*]}]
set_output_delay -clock [get_clocks clk] $IO_OUT_DELAY [get_ports {video_hsync video_vsync video_clk video_de}]
set_output_delay -clock [get_clocks clk] $IO_OUT_DELAY [get_ports {leds[*] dpy0[*] dpy1[*]}]

# If your STA tool does not propagate the clock through the PX3W pad, replace
# the port clock above with a clock on the pad output pin, for example:
# create_clock -name clk -period $CLK_PERIOD [get_pins PAD_CLK_IN/XC]
