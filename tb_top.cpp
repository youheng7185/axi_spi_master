#include "Vspi_flash_top.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <iostream>
#include <cstdint>
#include <string>

// ============================================================================
// Globals
// ============================================================================
vluint64_t sim_time = 0;
int test_pass = 0;
int test_fail = 0;

// ============================================================================
// Helpers
// ============================================================================
void tick(int32_t tick_val, Vspi_flash_top *dut, VerilatedVcdC* tfp) {
    for (int i = 0; i < tick_val; i++) {
        dut->clk = 0;
        dut->eval();
        tfp->dump(sim_time++);
        dut->clk = 1;
        dut->eval();
        tfp->dump(sim_time++);
    }
}

// Sample eot/status on falling edge before rising edge latches state→IDLE
void wait_status(Vspi_flash_top* dut, VerilatedVcdC* tfp, int timeout = 50000) {
    while (timeout--) {
        dut->clk = 0;
        dut->eval();
        tfp->dump(sim_time++);

        if (dut->status_o) {
            dut->clk = 1;
            dut->eval();
            tfp->dump(sim_time++);
            return;
        }

        dut->clk = 1;
        dut->eval();
        tfp->dump(sim_time++);
    }
    std::cout << "  [TIMEOUT] status never went high!\n";
    test_fail++;
}

void clear_status(Vspi_flash_top* dut, VerilatedVcdC* tfp) {
    dut->clr_status_i = 1;
    tick(1, dut, tfp);
    dut->clr_status_i = 0;
    tick(2, dut, tfp);
}

// Pulse start for exactly 1 cycle
void start_transfer(Vspi_flash_top* dut, VerilatedVcdC* tfp) {
    dut->start_i = 1;
    tick(1, dut, tfp);
    dut->start_i = 0;
}

void check(const std::string& test_name, uint32_t got, uint32_t expected) {
    if (got == expected) {
        std::cout << "  [PASS] " << test_name
                  << " got=0x" << std::hex << got << "\n";
        test_pass++;
    } else {
        std::cout << "  [FAIL] " << test_name
                  << " expected=0x" << std::hex << expected
                  << " got=0x" << got << "\n";
        test_fail++;
    }
}

void check_bool(const std::string& test_name, bool got, bool expected) {
    if (got == expected) {
        std::cout << "  [PASS] " << test_name << "\n";
        test_pass++;
    } else {
        std::cout << "  [FAIL] " << test_name
                  << " expected=" << expected << " got=" << got << "\n";
        test_fail++;
    }
}

// Push a 32-bit word into the TX FIFO, wait for ready
void push_tx(Vspi_flash_top* dut, VerilatedVcdC* tfp, uint32_t data) {
    int timeout = 1000;
    dut->data_tx_i       = data;
    dut->data_tx_valid_i = 1;
    while (!dut->data_tx_ready_o && timeout--) {
        tick(1, dut, tfp);
    }
    tick(1, dut, tfp);
    dut->data_tx_valid_i = 0;
}

// Drain one 32-bit word from RX FIFO
uint32_t pop_rx(Vspi_flash_top* dut, VerilatedVcdC* tfp) {
    int timeout = 2000;  // increase timeout
    dut->data_rx_ready_i = 1;
    while (!dut->data_rx_valid_o && timeout--) {
        tick(1, dut, tfp);
    }
    if (timeout <= 0) {
        std::cout << "  [pop_rx TIMEOUT] RX FIFO never had data!\n";
        dut->data_rx_ready_i = 0;
        return 0xDEAD0000;  // sentinel so you know it failed here
    }
    uint32_t data = dut->data_rx_o;
    tick(1, dut, tfp);
    dut->data_rx_ready_i = 0;
    return data;
}

// ============================================================================
// Default safe state for all inputs
// ============================================================================
void default_inputs(Vspi_flash_top* dut) {
    dut->command_i       = 0;
    dut->data_mode_i     = 0;
    dut->rd_wr_i         = 0;
    dut->dummy_cycle_i   = 0;
    dut->data_count_i    = 0;
    dut->has_addr_i      = 0;
    dut->prescaler_i     = 4;   // reasonable SPI speed
    dut->clr_status_i    = 0;
    dut->start_i         = 0;
    dut->addr_i          = 0;
    dut->data_tx_i       = 0;
    dut->data_tx_valid_i = 0;
    dut->data_rx_ready_i = 0;
    dut->flush_tx_i      = 0;
    dut->flush_rx_i      = 0;
}

// ============================================================================
// main
// ============================================================================
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vspi_flash_top *dut = new Vspi_flash_top;

    VerilatedVcdC* tfp = new VerilatedVcdC;
    Verilated::traceEverOn(true);
    dut->trace(tfp, 99);
    tfp->open("waveform.vcd");

    // -------------------------------------------------------------------------
    // Reset
    // -------------------------------------------------------------------------
    default_inputs(dut);
    dut->rstn = 0;
    tick(10, dut, tfp);
    dut->rstn = 1;
    dut->data_rx_ready_i = 0;
    tick(10, dut, tfp);

    std::cout << "\n=== SPI Flash Top Testbench ===\n\n";

    // =========================================================================
    // TEST 1: Write Enable (0x06) — no addr, no data
    // =========================================================================
    std::cout << "[TEST 1] Write Enable (0x06)\n";
    {
        default_inputs(dut);
        dut->command_i   = 0x06;
        dut->data_mode_i = 0;  // no data phase
        dut->has_addr_i  = 0;
        dut->rd_wr_i     = 0;      // write direction (wr path)

        start_transfer(dut, tfp);
        wait_status(dut, tfp);
        check_bool("status_o high after WE", dut->status_o, true);
        clear_status(dut, tfp);
        tick(20, dut, tfp);
    }

    // =========================================================================
    // TEST 2: Write Disable (0x04) — no addr, no data
    // =========================================================================
    std::cout << "\n[TEST 2] Write Disable (0x04)\n";
    {
        default_inputs(dut);
        dut->command_i   = 0x04;
        dut->data_mode_i = 0b00;
        dut->has_addr_i  = 0;
        dut->rd_wr_i     = 0;

        start_transfer(dut, tfp);
        wait_status(dut, tfp);
        check_bool("status_o high after WD", dut->status_o, true);
        clear_status(dut, tfp);
        tick(20, dut, tfp);
    }

    // =========================================================================
    // TEST 3: Read JEDEC ID (0x9F) — no addr, read 3 bytes
    // =========================================================================
    std::cout << "\n[TEST 3] Read JEDEC ID (0x9F)\n";
    {
        default_inputs(dut);
        dut->command_i   = 0x9F;
        dut->data_mode_i = 0b01;   // std SPI data phase
        dut->rd_wr_i     = 1;      // read
        dut->has_addr_i  = 0;
        dut->data_count_i= 2;      // 3 bytes (0=1byte, 2=3bytes), but data_len
                                   // is in 32-bit words so request 4 bytes (1 word)
        dut->data_count_i= 3;      // 4 bytes = 1 full 32-bit word from RX FIFO
        dut->dummy_cycle_i = 0;

        start_transfer(dut, tfp);
        wait_status(dut, tfp);
        tick(10, dut, tfp);
        uint32_t id = pop_rx(dut, tfp);
        // MFR_ID=0x20, DEVICE_ID=0xBA19, device_info[3]=0x10
        // bytes come out MSB first packed into 32-bit word
        std::cout << "  JEDEC ID word = 0x" << std::hex << id << "\n";
        check_bool("JEDEC MFR byte = 0x20", ((id >> 24) & 0xFF) == 0x20, true);

        clear_status(dut, tfp);
        tick(20, dut, tfp);
    }

    // =========================================================================
    // TEST 4: Read Status Register (0x05) — no addr, read 1 byte
    // =========================================================================
    std::cout << "\n[TEST 4] Read Status Register 1 (0x05)\n";
    {
        default_inputs(dut);
        dut->command_i    = 0x05;
        dut->data_mode_i  = 0b01;
        dut->rd_wr_i      = 1;
        dut->has_addr_i   = 0;
        dut->data_count_i = 3;     // 4 bytes = 1 RX FIFO word
        dut->dummy_cycle_i= 0;

        start_transfer(dut, tfp);
        wait_status(dut, tfp);
        tick(10, dut, tfp);
        uint32_t sr = pop_rx(dut, tfp);
        std::cout << "  Status Reg word = 0x" << std::hex << sr << "\n";
        // Flash model initialises status_reg_1 = 0x00
        check("Status byte[31:24]", (sr >> 24) & 0xFF, 0x00);

        clear_status(dut, tfp);
        tick(20, dut, tfp);
    }

    // =========================================================================
    // TEST 5: Read Flag Status Register (0x70) — no addr, read 1 byte
    // =========================================================================
    std::cout << "\n[TEST 5] Read Flag Status Register (0x70)\n";
    {
        default_inputs(dut);
        dut->command_i    = 0x70;
        dut->data_mode_i  = 0b01;
        dut->rd_wr_i      = 1;
        dut->has_addr_i   = 0;
        dut->data_count_i = 3;
        dut->dummy_cycle_i= 0;

        start_transfer(dut, tfp);
        wait_status(dut, tfp);
        tick(10, dut, tfp);
        uint32_t fsr = pop_rx(dut, tfp);
        std::cout << "  Flag Status Reg word = 0x" << std::hex << fsr << "\n";
        check("Flag Status byte[31:24]", (fsr >> 24) & 0xFF, 0x00);

        clear_status(dut, tfp);
        tick(20, dut, tfp);
    }

    // =========================================================================
    // TEST 6: Write Enable then Page Program (0x02) at address 0x000000
    // =========================================================================
    std::cout << "\n[TEST 6] Page Program (0x02) — write 4 bytes to 0x000000\n";
    {
        // Step 1: Write Enable first
        default_inputs(dut);
        dut->command_i   = 0x06;
        dut->data_mode_i = 0b00;
        dut->has_addr_i  = 0;
        dut->rd_wr_i     = 0;
        start_transfer(dut, tfp);
        wait_status(dut, tfp);
        clear_status(dut, tfp);
        tick(10, dut, tfp);

        // Step 2: Page Program
        default_inputs(dut);
        dut->command_i    = 0x02;
        dut->data_mode_i  = 0b01;  // std SPI
        dut->rd_wr_i      = 0;     // write
        dut->has_addr_i   = 1;
        dut->addr_i       = 0x000000;
        dut->data_count_i = 3;     // 4 bytes
        dut->dummy_cycle_i= 0;

        // Pre-load TX FIFO with 0xDEADBEEF
        push_tx(dut, tfp, 0xDEADBEEF);

        start_transfer(dut, tfp);
        wait_status(dut, tfp);
        check_bool("Page program completed", dut->status_o, true);

        clear_status(dut, tfp);
        tick(20, dut, tfp);
    }

    // =========================================================================
    // TEST 7: Read back what was written — Fast Read (0x0B) with 8 dummy cycles
    // =========================================================================
    std::cout << "\n[TEST 7] Fast Read (0x0B) — read 4 bytes from 0x000000\n";
    {
        default_inputs(dut);
        dut->command_i    = 0x0B;
        dut->data_mode_i  = 0b01;
        dut->rd_wr_i      = 1;
        dut->has_addr_i   = 1;
        dut->addr_i       = 0x000000;
        dut->data_count_i = 3;     // 4 bytes
        dut->dummy_cycle_i= 8;

        start_transfer(dut, tfp);
        wait_status(dut, tfp);
        tick(10, dut, tfp);
        uint32_t rd = pop_rx(dut, tfp);
        std::cout << "  Read back = 0x" << std::hex << rd << "\n";
        check("Fast Read data matches written", rd, 0xDEADBEEF);

        clear_status(dut, tfp);
        tick(20, dut, tfp);
    }

    // =========================================================================
    // TEST 8: Normal Read (0x03) — no dummy cycles, different address
    // =========================================================================
    std::cout << "\n[TEST 8] Normal Read (0x03) — read 4 bytes from 0x000004\n";
    {
        // First write something at 0x000004
        default_inputs(dut);
        dut->command_i   = 0x06;
        dut->data_mode_i = 0b00;
        dut->has_addr_i  = 0;
        dut->rd_wr_i     = 0;
        start_transfer(dut, tfp);
        wait_status(dut, tfp);
        clear_status(dut, tfp);
        tick(10, dut, tfp);

        default_inputs(dut);
        dut->command_i    = 0x02;
        dut->data_mode_i  = 0b01;
        dut->rd_wr_i      = 0;
        dut->has_addr_i   = 1;
        dut->addr_i       = 0x000004;
        dut->data_count_i = 3;
        push_tx(dut, tfp, 0xCAFEBABE);
        start_transfer(dut, tfp);
        wait_status(dut, tfp);
        clear_status(dut, tfp);
        tick(10, dut, tfp);

        // Now read it back with normal read
        default_inputs(dut);
        dut->command_i    = 0x03;
        dut->data_mode_i  = 0b01;
        dut->rd_wr_i      = 1;
        dut->has_addr_i   = 1;
        dut->addr_i       = 0x000004;
        dut->data_count_i = 3;
        dut->dummy_cycle_i= 0;

        start_transfer(dut, tfp);
        wait_status(dut, tfp);
        tick(10, dut, tfp);
        uint32_t rd = pop_rx(dut, tfp);
        std::cout << "  Read back = 0x" << std::hex << rd << "\n";
        check("Normal Read data matches written", rd, 0xCAFEBABE);

        clear_status(dut, tfp);
        tick(20, dut, tfp);
    }

    // =========================================================================
    // TEST 9: Sector Erase (0xD8) then verify erased (0xFF)
    // =========================================================================
    std::cout << "\n[TEST 9] Sector Erase (0xD8) at 0x000000, then verify\n";
    {
        // Write Enable
        default_inputs(dut);
        dut->command_i   = 0x06;
        dut->data_mode_i = 0b00;
        dut->has_addr_i  = 0;
        dut->rd_wr_i     = 0;
        start_transfer(dut, tfp);
        wait_status(dut, tfp);
        clear_status(dut, tfp);
        tick(10, dut, tfp);

        // Sector Erase
        default_inputs(dut);
        dut->command_i   = 0xD8;
        dut->data_mode_i = 0b00;  // no data phase, just cmd+addr
        dut->has_addr_i  = 1;
        dut->addr_i      = 0x000000;
        dut->rd_wr_i     = 0;

        start_transfer(dut, tfp);
        wait_status(dut, tfp);
        check_bool("Erase completed", dut->status_o, true);
        clear_status(dut, tfp);
        tick(20, dut, tfp);

        // Read back — should be 0xFFFFFFFF
        default_inputs(dut);
        dut->command_i    = 0x03;
        dut->data_mode_i  = 0b01;
        dut->rd_wr_i      = 1;
        dut->has_addr_i   = 1;
        dut->addr_i       = 0x000000;
        dut->data_count_i = 3;
        dut->dummy_cycle_i= 0;

        start_transfer(dut, tfp);
        wait_status(dut, tfp);
        tick(10, dut, tfp);
        uint32_t rd = pop_rx(dut, tfp);
        std::cout << "  Post-erase read = 0x" << std::hex << rd << "\n";
        check("Erased region reads 0xFFFFFFFF", rd, 0xFFFFFFFF);

        clear_status(dut, tfp);
        tick(20, dut, tfp);
    }

    // =========================================================================
    // TEST 10: Software Reset (0x66 then 0x99)
    // =========================================================================
    std::cout << "\n[TEST 10] Software Reset (0x66 + 0x99)\n";
    {
        // Reset Enable
        default_inputs(dut);
        dut->command_i   = 0x66;
        dut->data_mode_i = 0b00;
        dut->has_addr_i  = 0;
        dut->rd_wr_i     = 0;
        start_transfer(dut, tfp);
        wait_status(dut, tfp);
        clear_status(dut, tfp);
        tick(10, dut, tfp);

        // Reset Execute
        default_inputs(dut);
        dut->command_i   = 0x99;
        dut->data_mode_i = 0b00;
        dut->has_addr_i  = 0;
        dut->rd_wr_i     = 0;
        start_transfer(dut, tfp);
        wait_status(dut, tfp);
        check_bool("Reset completed", dut->status_o, true);
        clear_status(dut, tfp);
        tick(20, dut, tfp);
    }

    // =========================================================================
    // TEST 11: TX FIFO flush
    // =========================================================================
    std::cout << "\n[TEST 11] TX FIFO flush\n";
    {
        default_inputs(dut);
        // Push some data
        push_tx(dut, tfp, 0x11223344);
        push_tx(dut, tfp, 0x55667788);
        check_bool("TX FIFO not empty before flush", !dut->tx_fifo_empty_o, true);

        // Flush
        dut->flush_tx_i = 1;
        tick(2, dut, tfp);
        dut->flush_tx_i = 0;
        tick(2, dut, tfp);
        check_bool("TX FIFO empty after flush", dut->tx_fifo_empty_o, true);
        tick(10, dut, tfp);
    }

    // =========================================================================
    // TEST 12: Back-to-back writes — write 8 bytes to consecutive addresses
    // =========================================================================
    std::cout << "\n[TEST 12] Back-to-back writes (0x000010 and 0x000014)\n";
    {
        for (int i = 0; i < 2; i++) {
            uint32_t waddr  = 0x000010 + (i * 4);
            uint32_t wdata  = (i == 0) ? 0xAABBCCDD : 0x11223344;

            // Write Enable
            default_inputs(dut);
            dut->command_i   = 0x06;
            dut->data_mode_i = 0b00;
            dut->has_addr_i  = 0;
            dut->rd_wr_i     = 0;
            start_transfer(dut, tfp);
            wait_status(dut, tfp);
            clear_status(dut, tfp);
            tick(5, dut, tfp);

            // Write
            default_inputs(dut);
            dut->command_i    = 0x02;
            dut->data_mode_i  = 0b01;
            dut->rd_wr_i      = 0;
            dut->has_addr_i   = 1;
            dut->addr_i       = waddr;
            dut->data_count_i = 3;
            push_tx(dut, tfp, wdata);
            start_transfer(dut, tfp);
            wait_status(dut, tfp);
            clear_status(dut, tfp);
            tick(5, dut, tfp);
        }

        // Read both back
        uint32_t expected[2] = {0xAABBCCDD, 0x11223344};
        for (int i = 0; i < 2; i++) {
            uint32_t raddr = 0x000010 + (i * 4);
            default_inputs(dut);
            dut->command_i    = 0x03;
            dut->data_mode_i  = 0b01;
            dut->rd_wr_i      = 1;
            dut->has_addr_i   = 1;
            dut->addr_i       = raddr;
            dut->data_count_i = 3;
            dut->dummy_cycle_i= 0;
            start_transfer(dut, tfp);
            wait_status(dut, tfp);
            tick(10, dut, tfp);
            uint32_t rd = pop_rx(dut, tfp);
            check("Back-to-back read word " + std::to_string(i), rd, expected[i]);
            clear_status(dut, tfp);
            tick(5, dut, tfp);
        }
    }

    // =========================================================================
    // TEST 13: Busy signal — check it goes high during transfer
    // =========================================================================
    std::cout << "\n[TEST 13] Busy signal during transfer\n";
    {
        default_inputs(dut);
        dut->command_i   = 0x06;
        dut->data_mode_i = 0b00;
        dut->has_addr_i  = 0;
        dut->rd_wr_i     = 0;

        start_transfer(dut, tfp);
        tick(2, dut, tfp);  // a couple cycles in — should be busy
        check_bool("busy_o high during transfer", dut->busy_o, true);

        wait_status(dut, tfp);
        tick(2, dut, tfp);
        check_bool("busy_o low after transfer", dut->busy_o, false);
        clear_status(dut, tfp);
        tick(10, dut, tfp);
    }

    // =========================================================================
    // TEST 14: clr_status_i clears status_o
    // =========================================================================
    std::cout << "\n[TEST 14] clr_status_i clears status_o\n";
    {
        default_inputs(dut);
        dut->command_i   = 0x06;
        dut->data_mode_i = 0b00;
        dut->has_addr_i  = 0;
        dut->rd_wr_i     = 0;
        start_transfer(dut, tfp);
        wait_status(dut, tfp);
        check_bool("status_o high before clear", dut->status_o, true);

        dut->clr_status_i = 1;
        tick(1, dut, tfp);
        dut->clr_status_i = 0;
        tick(2, dut, tfp);
        check_bool("status_o low after clear", dut->status_o, false);
        tick(10, dut, tfp);
    }

    // =========================================================================
    // Summary
    // =========================================================================
    std::cout << "\n=== Results: "
              << test_pass << " passed, "
              << test_fail << " failed ===\n";

    tick(20, dut, tfp);
    dut->final();
    tfp->close();
    delete dut;
    return (test_fail > 0) ? 1 : 0;
}