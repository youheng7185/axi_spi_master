module spi_flash_wrapper (
    input  logic        clk,
    input  logic        rstn,

    input  logic [7:0]  command_i,
    input  logic [1:0]  data_mode_i,    // 00=no data, 01=std SPI, 10=dual, 11=quad
    input  logic        rd_wr_i,         // 1=read, 0=write
    input  logic [4:0]  dummy_cycle_i,
    input  logic [7:0]  data_count_i,   // bytes-1: 0=1byte, 1=2bytes, ...
    input  logic        has_addr_i,
    input  logic [5:0]  prescaler_i,
    input  logic        clr_status_i,
    input  logic        start_i,         // pulse 1 cycle to start

    input  logic [23:0] addr_i,          // 24-bit flash address

    // TX port
    input  logic [31:0] data_tx_i,
    input  logic        data_tx_valid_i,
    output logic        data_tx_ready_o,

    // RX port
    output logic [31:0] data_rx_o,
    output logic        data_rx_valid_o,
    input  logic        data_rx_ready_i,

    output logic        status_o,        // latches high on eot, cleared by clr_status_i
    output logic        busy_o,          // high while CS asserted

    output logic        rx_fifo_full_o,
    output logic        rx_fifo_empty_o,
    output logic        tx_fifo_full_o,
    output logic        tx_fifo_empty_o,

    output logic [3:0]  err_msg_o,       // reserved

    input  logic        flush_tx_i,
    input  logic        flush_rx_i,

    // SPI pins
    output logic        spi_clk,
    output logic        spi_csn,
    output logic        spi_sdo0,
    output logic        spi_sdo1,
    output logic        spi_sdo2,
    output logic        spi_sdo3,
    input  logic        spi_sdi0,
    input  logic        spi_sdi1,
    input  logic        spi_sdi2,
    input  logic        spi_sdi3
);

    // -------------------------------------------------------------------------
    // Internal signals
    // -------------------------------------------------------------------------
    logic        eot;
    logic [1:0]  spi_mode;

    logic        spi_rd, spi_wr, spi_qrd, spi_qwr;

    logic [31:0] ctrl_data_tx;
    logic        ctrl_data_tx_valid;
    logic        ctrl_data_tx_ready;
    logic [31:0] ctrl_data_rx;
    logic        ctrl_data_rx_valid;
    logic        ctrl_data_rx_ready;

    logic [3:0]  elements_tx;
    logic [3:0]  elements_rx;

    logic        raw_sdo0, raw_sdo1, raw_sdo2, raw_sdo3;

    // -------------------------------------------------------------------------
    // Derived signals
    // -------------------------------------------------------------------------

    // data_len in bits: (data_count_i + 1) * 8
    // data_count_i is 8-bit, +1 max = 256, *8 = 2048 fits in 16 bits fine
    logic [15:0] spi_data_len;
    assign spi_data_len = (data_mode_i == 2'b00)
                        ? 16'd0
                        : {6'd0, data_count_i + 1'b1, 3'd0};

    logic [5:0] spi_addr_len;
    assign spi_addr_len = has_addr_i ? 6'd24 : 6'd0;

    // Start trigger — only pass start_i to the correct mode signal
    assign spi_rd  = (rd_wr_i  && data_mode_i == 2'b01) ? start_i : 1'b0;
    assign spi_wr  = (!rd_wr_i && data_mode_i == 2'b01) ? start_i : 1'b0;
    assign spi_qrd = (rd_wr_i  && data_mode_i == 2'b11) ? start_i : 1'b0;
    assign spi_qwr = (!rd_wr_i && data_mode_i == 2'b11) ? start_i : 1'b0;

    // -------------------------------------------------------------------------
    // Status / busy
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn)
            status_o <= 1'b0;
        else if (clr_status_i)
            status_o <= 1'b0;
        else if (eot)
            status_o <= 1'b1;
    end

    assign busy_o = ~spi_csn;  // CS low = transfer in progress

    // -------------------------------------------------------------------------
    // FIFO status
    // -------------------------------------------------------------------------
    assign tx_fifo_full_o  = (elements_tx == 4'd8);
    assign tx_fifo_empty_o = (elements_tx == 4'd0);
    assign rx_fifo_full_o  = (elements_rx == 4'd8);
    assign rx_fifo_empty_o = (elements_rx == 4'd0);

    // -------------------------------------------------------------------------
    // SDO masking — tie unused lines low in standard SPI mode
    // -------------------------------------------------------------------------
    assign spi_sdo0 = raw_sdo0;
    assign spi_sdo1 = (spi_mode != 2'b00) ? raw_sdo1 : 1'b0;
    assign spi_sdo2 = (spi_mode != 2'b00) ? raw_sdo2 : 1'b0;
    assign spi_sdo3 = (spi_mode != 2'b00) ? raw_sdo3 : 1'b0;

    // err_msg not implemented yet
    assign err_msg_o = 4'b0000;

    // -------------------------------------------------------------------------
    // TX FIFO  (user → controller)
    // -------------------------------------------------------------------------
    spi_master_fifo #(
        .DATA_WIDTH  (32),
        .BUFFER_DEPTH(8)
    ) u_txfifo (
        .clk_i  (clk),
        .rst_ni (rstn),
        .clr_i  (flush_tx_i),

        .elements_o(elements_tx),

        .data_o (ctrl_data_tx),
        .valid_o(ctrl_data_tx_valid),
        .ready_i(ctrl_data_tx_ready),

        .valid_i(data_tx_valid_i),
        .data_i (data_tx_i),
        .ready_o(data_tx_ready_o)
    );

    // -------------------------------------------------------------------------
    // RX FIFO  (controller → user)
    // -------------------------------------------------------------------------
    spi_master_fifo #(
        .DATA_WIDTH  (32),
        .BUFFER_DEPTH(8)
    ) u_rxfifo (
        .clk_i  (clk),
        .rst_ni (rstn),
        .clr_i  (flush_rx_i),

        .elements_o(elements_rx),

        .data_o (data_rx_o),
        .valid_o(data_rx_valid_o),
        .ready_i(data_rx_ready_i),

        .valid_i(ctrl_data_rx_valid),
        .data_i (ctrl_data_rx),
        .ready_o(ctrl_data_rx_ready)
    );

    // -------------------------------------------------------------------------
    // SPI Master Controller
    // -------------------------------------------------------------------------
    spi_master_controller u_ctrl (
        .clk  (clk),
        .rstn (rstn),
        .eot  (eot),

        .spi_clk_div      ({2'b00, prescaler_i}),
        .spi_clk_div_valid(start_i),  // only update divider when starting

        .spi_status(),

        // CMD: 8 bits, left-aligned in 32-bit field
        .spi_cmd    ({command_i, 24'b0}),
        .spi_cmd_len(6'd8),

        // ADDR: 24 bits, left-aligned in 32-bit field
        .spi_addr    ({addr_i, 8'b0}),
        .spi_addr_len(spi_addr_len),

        .spi_data_len(spi_data_len),

        .spi_dummy_rd({11'b0, dummy_cycle_i}),
        .spi_dummy_wr(16'b0),

        .spi_csreg(4'b0001),

        .spi_rd (spi_rd),
        .spi_wr (spi_wr),
        .spi_qrd(spi_qrd),
        .spi_qwr(spi_qwr),

        .spi_ctrl_data_tx      (ctrl_data_tx),
        .spi_ctrl_data_tx_valid(ctrl_data_tx_valid),
        .spi_ctrl_data_tx_ready(ctrl_data_tx_ready),

        .spi_ctrl_data_rx      (ctrl_data_rx),
        .spi_ctrl_data_rx_valid(ctrl_data_rx_valid),
        .spi_ctrl_data_rx_ready(ctrl_data_rx_ready),

        .spi_clk (spi_clk),
        .spi_csn0(spi_csn),
        .spi_csn1(),
        .spi_csn2(),
        .spi_csn3(),

        .spi_mode(spi_mode),

        .spi_sdo0(raw_sdo0),
        .spi_sdo1(raw_sdo1),
        .spi_sdo2(raw_sdo2),
        .spi_sdo3(raw_sdo3),

        .spi_sdi0(spi_sdi0),
        .spi_sdi1(spi_sdi1),
        .spi_sdi2(spi_sdi2),
        .spi_sdi3(spi_sdi3)
    );

endmodule