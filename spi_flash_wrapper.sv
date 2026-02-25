module spi_flash_wrapper (
    input logic clk,
    input logic rstn,

    input logic [7:0] command_i,
    input logic [1:0] data_mode_i, // 00 - no send data, 01 - send data with spi, 10 - dual spi, 11 - quad spi
    input logic rd_wr_i, // 1 for read, 0 for write
    input logic [4:0] dummy_cycle_i,
    input logic [7:0] data_count_i, // data count in byte, 0 for a byte, 1 for two byte
    input logic has_addr_i, // 1 if has addr, 0 if no addr
    input logic [5:0] prescaler_i,
    input logic clr_status_i,

    input logic [31:0] addr_i,
    input logic [31:0] data_register_i,
    output logic [31:0] data_register_o,

    output logic status_o, // 1 if done, 0 if not done, reset from clr_status_i
    output logic busy_i, // just put 1 when having transaction

    output logic rx_fifo_full_o,
    output logic rx_fifo_empty_o,

    output logic tx_fifo_full_o,
    output logic tx_fifo_empty_o,

    output logic [3:0] err_msg_o, // later write

    input logic flush_tx_i,
    input logic flush_rx_i,

    // extern pins
    output logic                          spi_clk,
    output logic                          spi_csn,
    output logic                          spi_sdo0,
    output logic                          spi_sdo1,
    output logic                          spi_sdo2,
    output logic                          spi_sdo3,
    input  logic                          spi_sdi0,
    input  logic                          spi_sdi1,
    input  logic                          spi_sdi2,
    input  logic                          spi_sdi3
);


    logic done_flag;
    logic eot;

    always_comb begin
        if (!rstn) begin
            done_flag = 0;
            status_o = 0;
        end else begin
            if (clr_status_i) begin
                done_flag = 1'b0;
            end else if (eot) begin
                done_flag = 1'b1;
            end begin
                done_flag = done_flag;
            end
        end
    end

    logic [5:0] spi_addr_len = has_addr_i ? 6'd24 : 6'd0;
    logic [15:0] spi_data_len = (data_mode_i == 2'b0) ? 16'd0 : ((data_count_i + 1) << 4); // convert to bit

    logic [1:0] spi_mode;
    logic internal_do0, internal_do1, internal_do2, internal_do3;

    // `define SPI_STD     2'b00
    // `define SPI_QUAD_TX 2'b01
    // `define SPI_QUAD_RX 2'b10

    assign spi_sdo0 = internal_di0;
    assign spi_sdo1 = (spi_mode == 2'b01) ? 1'b0 : internal_di1;
    assign spi_sdo2 = (spi_mode == 2'b01) ? 1'b0 : internal_di2;
    assign spi_sdo3 = (spi_mode == 2'b01) ? 1'b0 : internal_di3;

    spi_master_controller spi_master_inst (
        .clk(clk),
        .rstn(rstn),
        .eot(eot),

        .spi_clk_div({2'b0, prescaler_i}),
        .spi_clk_div_valid(1'b1),

        .spi_status(),

        .spi_addr(addr_i),
        .spi_addr_len(spi_addr_len),

        .spi_cmd({command_i, 24'b0}),
        .spi_cmd_len(6'd8),

        .spi_data_len(spi_data_len),
        .spi_dummy_rd({11'b0, dummy_cycle_i}),
        .spi_dummy_wr(16'b0), // write for flash dont need dummy cycle

        .spi_csreg(4'b0001), // i only have a single device
        .spi_rd(rd_wr_i),
        .spi_wr(~rd_wr_i),

        .spi_qrd(1'b0), // fixme, add quad read later
        .spi_qwr(1'b1),

        .spi_clk(spi_clk),
        .spi_csn0(spi_csn),
        .spi_csn1(),
        .spi_csn2(),
        .spi_csn3(),
 

        .spi_mode(spi_mode),

        .spi_sdo0(internal_do0),
        .spi_sdo1(internal_do1),
        .spi_sdo2(internal_do2),
        .spi_sdo3(internal_do3),

        .spi_sdi0(spi_sdi0),
        .spi_sdi1(spi_sdi1),
        .spi_sdi2(spi_sdi2),
        .spi_sdi3(spi_sdi3)

    );

    logic                   [31:0] spi_ctrl_data_tx,
    logic                          spi_ctrl_data_tx_valid,
    logic                          spi_ctrl_data_tx_ready,
    logic                   [31:0] spi_ctrl_data_rx,
    logic                          spi_ctrl_data_rx_valid,
    logic                          spi_ctrl_data_rx_ready,

    // tx fifo
    spi_master_fifo (
        .clk_i(clk),
        .rst_ni(rstn),

        .clr_i(flush_tx_i),
        .elements_o(data_count_i),
        .data_o()
    );

    // rx fifo
    spi_master_fifo (
        .clk_i(clk),
        .rst_ni(rstn),

        .clr_i(flush_rx_i),
        .elements_o(data_count_i),
        .data_o()
    );

endmodule