# Makefile for Verilator simulation

# Default Verilator flags
VERILATOR_FLAGS = -Wall --trace

# C++ testbench
TB = tb.cpp
TOP_SPI = spi_master_controller

obj_dir/V$(TOP_SPI).mk: $(TOP_SPI).sv $(TB)
	verilator $(VERILATOR_FLAGS) --cc $(TOP_SPI).sv --exe $(TB)

build_spi: obj_dir/V$(TOP_SPI).mk
	make -j -C obj_dir -f V$(TOP_SPI).mk V$(TOP_SPI)

run_spi: build_spi
	./obj_dir/V$(TOP_SPI)

# ---------------------------
# Option 2: qspi_sim_top
# ---------------------------
TB_MODEL = tb_model.cpp
TOP_SIM = qspi_sim_top

obj_dir/V$(TOP_SIM).mk: $(TOP_SIM).sv $(TB_MODEL)
	verilator $(VERILATOR_FLAGS) --cc $(TOP_SIM).sv --exe $(TB_MODEL)

build_sim: obj_dir/V$(TOP_SIM).mk
	make -j -C obj_dir -f V$(TOP_SIM).mk V$(TOP_SIM)

run_model: build_sim
	./obj_dir/V$(TOP_SIM)

# ---------------------------
# Clean
# ---------------------------
clean:
	rm -rf obj_dir *.vcd *.o *.d *.exe

.PHONY: run_spi run_model build_spi build_sim clean
