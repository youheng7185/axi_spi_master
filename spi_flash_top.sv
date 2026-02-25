module spi_flash_top #(
    parameter MEMORY_SIZE = 1024 * 256,
    parameter SECTOR_SIZE = 64,
    parameter MFR_ID      = 8'h20,
    parameter DEVICE_ID   = 16'hBA19
) (
    input  logic        clk,
    input  logic        rstn,

    // User interface — same as spi_flash_wrapper
    input  logic [7:0]  command_i,
    input  logic [1:0]  data_mode_i,
    input  logic        rd_wr_i,
    input  logic [4:0]  dummy_cycle_i,
    input  logic [7:0]  data_count_i,
    input  logic        has_addr_i,
    input  logic [5:0]  prescaler_i,
    input  logic        clr_status_i,
    input  logic        start_i,
    input  logic [23:0] addr_i,

    input  logic [31:0] data_tx_i,
    input  logic        data_tx_valid_i,
    output logic        data_tx_ready_o,

    output logic [31:0] data_rx_o,
    output logic        data_rx_valid_o,
    input  logic        data_rx_ready_i,

    output logic        status_o,
    output logic        busy_o,
    output logic        rx_fifo_full_o,
    output logic        rx_fifo_empty_o,
    output logic        tx_fifo_full_o,
    output logic        tx_fifo_empty_o,
    output logic [3:0]  err_msg_o,
    input  logic        flush_tx_i,
    input  logic        flush_rx_i
);

    // -------------------------------------------------------------------------
    // Internal SPI bus — wires between wrapper and flash model
    // -------------------------------------------------------------------------
    logic spi_clk;
    logic spi_csn;
    logic spi_sdo0, spi_sdo1, spi_sdo2, spi_sdo3;
    logic spi_sdi0, spi_sdi1, spi_sdi2, spi_sdi3;

    // -------------------------------------------------------------------------
    // SPI Flash Wrapper (master)
    // -------------------------------------------------------------------------
    spi_flash_wrapper u_wrapper (
        .clk            (clk),
        .rstn           (rstn),

        .command_i      (command_i),
        .data_mode_i    (data_mode_i),
        .rd_wr_i        (rd_wr_i),
        .dummy_cycle_i  (dummy_cycle_i),
        .data_count_i   (data_count_i),
        .has_addr_i     (has_addr_i),
        .prescaler_i    (prescaler_i),
        .clr_status_i   (clr_status_i),
        .start_i        (start_i),
        .addr_i         (addr_i),

        .data_tx_i      (data_tx_i),
        .data_tx_valid_i(data_tx_valid_i),
        .data_tx_ready_o(data_tx_ready_o),

        .data_rx_o      (data_rx_o),
        .data_rx_valid_o(data_rx_valid_o),
        .data_rx_ready_i(data_rx_ready_i),

        .status_o       (status_o),
        .busy_o         (busy_o),
        .rx_fifo_full_o (rx_fifo_full_o),
        .rx_fifo_empty_o(rx_fifo_empty_o),
        .tx_fifo_full_o (tx_fifo_full_o),
        .tx_fifo_empty_o(tx_fifo_empty_o),
        .err_msg_o      (err_msg_o),
        .flush_tx_i     (flush_tx_i),
        .flush_rx_i     (flush_rx_i),

        // SPI bus
        .spi_clk        (spi_clk),
        .spi_csn        (spi_csn),
        .spi_sdo0       (spi_sdo0),
        .spi_sdo1       (spi_sdo1),
        .spi_sdo2       (spi_sdo2),
        .spi_sdo3       (spi_sdo3),
        .spi_sdi0       (spi_sdi0),
        .spi_sdi1       (spi_sdi1),
        .spi_sdi2       (spi_sdi2),
        .spi_sdi3       (spi_sdi3)
    );

    // -------------------------------------------------------------------------
    // NOR Flash simulation model (slave)
    // only sdo0→dq0 (MOSI) and dq1→sdi0 (MISO) used in standard SPI mode
    // sdo1/2/3 wired in for quad mode future use
    // -------------------------------------------------------------------------
    qspi_nor_sim_model #(
        .MEMORY_SIZE(MEMORY_SIZE),
        .SECTOR_SIZE(SECTOR_SIZE),
        .MFR_ID     (MFR_ID),
        .DEVICE_ID  (DEVICE_ID)
    ) u_flash (
        .sclk       (spi_clk),
        .cs_n       (spi_csn),

        // MOSI: master out → flash in (dq0)
        .dq0_mosi_i (spi_sdo0),

        // MISO: flash out → master in (dq1)
        .dq1_miso_o (spi_sdi0)

        // quad lines — not connected until quad mode is added
        // .dq1_io     (spi_sdo1 / spi_sdi1)  // future
        // .dq2_io     (spi_sdo2 / spi_sdi2)  // future
        // .dq3_io     (spi_sdo3 / spi_sdi3)  // future
    );

    // unused SDI lines tied off
    assign spi_sdi1 = 1'b0;
    assign spi_sdi2 = 1'b0;
    assign spi_sdi3 = 1'b0;

endmodule