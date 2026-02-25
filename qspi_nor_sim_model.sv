module qspi_nor_sim_model #(
    parameter MEMORY_SIZE = 1024 * 256, // reduce for sim, 256KB
    parameter SECTOR_SIZE = 64,         // 64KB sectors
    parameter MFR_ID      = 8'h20,
    parameter DEVICE_ID   = 16'hBA19
) (
    input  logic sclk,
    input  logic cs_n,
    input  logic dq0_mosi_i,
    output logic dq1_miso_o
);

    logic [7:0] memory [0:MEMORY_SIZE-1];

    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_CMD,
        STATE_ADDR,
        STATE_DUMMY,
        STATE_DATA_IN,
        STATE_DATA_OUT
    } state_t;

    state_t      current_state;
    logic [7:0]  command;
    logic [31:0] address;
    logic [7:0]  shift_in;
    logic [7:0]  shift_out;   // drives MISO, MSB first
    logic [7:0]  byte_counter;
    logic [31:0] address_shift_in;
    logic [7:0]  bit_counter;
    logic [7:0]  device_info [0:19];
    logic [7:0]  dummy_cycles_target;

    logic [7:0]  status_reg_1;
    logic [7:0]  flag_status_reg;
    logic [7:0]  volatile_config;
    logic [15:0] nonvolatile_config;
    logic        write_in_progress;
    logic        write_enable_latch;

    // -------------------------------------------------------------------------
    // Init
    // -------------------------------------------------------------------------
    initial begin
        for (int i = 0; i < MEMORY_SIZE; i++)
            memory[i] = 8'hFF;  // erased state = 0xFF

        device_info[0] = MFR_ID;
        device_info[1] = DEVICE_ID[15:8];
        device_info[2] = DEVICE_ID[7:0];
        device_info[3] = 8'h10;
        device_info[4] = 8'h00;
        device_info[5] = 8'h00;
        for (int i = 6; i < 20; i++)
            device_info[i] = 8'hAA;

        status_reg_1       = 8'h00;
        flag_status_reg    = 8'h00;
        volatile_config    = 8'hF3;
        nonvolatile_config = 16'hFFFF;
        write_in_progress  = 1'b0;
        write_enable_latch = 1'b0;
        current_state      = STATE_IDLE;
        command            = 8'h00;
        address            = 32'h0;
        bit_counter        = 0;
        byte_counter       = 0;
        dummy_cycles_target= 0;
        shift_out          = 8'h00;
        shift_in           = 8'h00;
        dq1_miso_o         = 1'b0;
    end

    // -------------------------------------------------------------------------
    // Main FSM — posedge sclk, async reset on cs_n high
    // -------------------------------------------------------------------------
    always @(posedge sclk or posedge cs_n) begin
        if (cs_n) begin
            // CS deasserted — complete any pending writes
            if (current_state == STATE_DATA_IN) begin
                if (command == 8'h02 || command == 8'h12 ||
                    command == 8'h32 || command == 8'h34) begin
                    write_in_progress <= 1'b0;
                    write_enable_latch <= 1'b0;
                end
            end
            current_state <= STATE_IDLE;
            bit_counter   <= 0;
            byte_counter  <= 0;

        end else begin
            case (current_state)

                // -----------------------------------------------------------------
                STATE_IDLE: begin
                    // Capture first bit immediately, go to CMD
                    shift_in      <= {7'b0, dq0_mosi_i};
                    bit_counter   <= 1;
                    current_state <= STATE_CMD;
                end

                // -----------------------------------------------------------------
                STATE_CMD: begin
                    shift_in <= {shift_in[6:0], dq0_mosi_i};

                    if (bit_counter == 7) begin
                        automatic logic [7:0] cmd;
                        cmd     = {shift_in[6:0], dq0_mosi_i};
                        command <= cmd;
                        bit_counter <= 0;
                        $display("[FLASH] CMD: 0x%02h", cmd);

                        case (cmd)
                            // --- 3-byte address read commands ---
                            8'h03: begin  // Read
                                current_state       <= STATE_ADDR;
                                dummy_cycles_target <= 0;
                            end
                            8'h0B: begin  // Fast Read
                                current_state       <= STATE_ADDR;
                                dummy_cycles_target <= 8;
                            end

                            // --- 3-byte address write commands ---
                            8'h02: begin  // Page Program
                                current_state      <= STATE_ADDR;
                                write_in_progress  <= 1'b1;
                            end

                            // --- Sector erase ---
                            8'hD8: begin  // 64KB Sector Erase (3-byte addr)
                                current_state <= STATE_ADDR;
                            end

                            // --- Register reads (no address) ---
                            8'h9F: begin  // Read JEDEC ID
                                current_state <= STATE_DATA_OUT;
                                byte_counter  <= 0;
                                bit_counter   <= 0;
                                shift_out     <= device_info[0];
                            end
                            8'h05: begin  // Read Status Register 1
                                current_state <= STATE_DATA_OUT;
                                byte_counter  <= 0;
                                bit_counter   <= 0;
                                shift_out     <= status_reg_1;
                            end
                            8'h70: begin  // Read Flag Status
                                current_state <= STATE_DATA_OUT;
                                byte_counter  <= 0;
                                bit_counter   <= 0;
                                shift_out     <= flag_status_reg;
                            end

                            // --- Single-byte commands ---
                            8'h06: begin  // Write Enable
                                write_enable_latch <= 1'b1;
                                current_state      <= STATE_IDLE;
                                $display("[FLASH] Write Enable");
                            end
                            8'h04: begin  // Write Disable
                                write_enable_latch <= 1'b0;
                                current_state      <= STATE_IDLE;
                            end
                            8'h66: current_state <= STATE_IDLE; // Reset Enable
                            8'h99: begin  // Reset Execute
                                write_enable_latch <= 1'b0;
                                write_in_progress  <= 1'b0;
                                current_state      <= STATE_IDLE;
                            end

                            default: begin
                                $display("[FLASH] Unhandled CMD: 0x%02h", cmd);
                                current_state <= STATE_IDLE;
                            end
                        endcase
                    end else begin
                        bit_counter <= bit_counter + 1;
                    end
                end

                // -----------------------------------------------------------------
                STATE_ADDR: begin
                    address_shift_in <= {address_shift_in[30:0], dq0_mosi_i};
                    bit_counter      <= bit_counter + 1;

                    if (bit_counter == 23) begin  // 24-bit address
                        automatic logic [23:0] addr24;
                        addr24  = {address_shift_in[22:0], dq0_mosi_i};
                        address <= {8'b0, addr24};
                        bit_counter <= 0;
                        $display("[FLASH] ADDR: 0x%06h", addr24);

                        case (command)
                            8'h03: begin  // Read — no dummy
                                current_state <= STATE_DATA_OUT;
                                byte_counter  <= 0;
                                shift_out     <= memory[{8'b0, addr24}];
                            end
                            8'h0B: begin  // Fast Read — dummy cycles
                                current_state <= STATE_DUMMY;
                            end
                            8'h02: begin  // Page Program
                                current_state <= STATE_DATA_IN;
                                byte_counter  <= 0;
                            end
                            8'hD8: begin  // 64KB Sector Erase
                                if (write_enable_latch) begin
                                    automatic logic [23:0] base;
                                    base = addr24 & ~(24'(SECTOR_SIZE * 1024 - 1));
                                    for (int i = 0; i < SECTOR_SIZE * 1024; i++) begin
                                        if (base + i < MEMORY_SIZE)
                                            memory[base + i] <= 8'hFF;
                                    end
                                    write_enable_latch <= 1'b0;
                                    $display("[FLASH] Erased sector at 0x%06h", base);
                                end
                                current_state <= STATE_IDLE;
                            end
                            default: current_state <= STATE_IDLE;
                        endcase
                    end
                end

                // -----------------------------------------------------------------
                STATE_DUMMY: begin
                    bit_counter <= bit_counter + 1;
                    if (bit_counter == dummy_cycles_target - 1) begin
                        current_state <= STATE_DATA_OUT;
                        byte_counter  <= 0;
                        bit_counter   <= 0;
                        shift_out     <= memory[address % MEMORY_SIZE];
                    end
                end

                // -----------------------------------------------------------------
                STATE_DATA_OUT: begin
                    // shift_out shifts on posedge; MISO samples on negedge
                    if (bit_counter == 7) begin
                        bit_counter  <= 0;
                        byte_counter <= byte_counter + 1;
                        // preload next byte
                        case (command)
                            8'h9F:
                                shift_out <= (byte_counter < 8'd19)
                                           ? device_info[byte_counter + 1]
                                           : 8'hFF;
                            8'h03, 8'h0B:
                                shift_out <= memory[(address + byte_counter + 1) % MEMORY_SIZE];
                            8'h05: shift_out <= status_reg_1;   // re-read (continuous poll)
                            default: shift_out <= 8'hFF;
                        endcase
                    end else begin
                        shift_out   <= {shift_out[6:0], 1'b0};
                        bit_counter <= bit_counter + 1;
                    end
                end

                // -----------------------------------------------------------------
                STATE_DATA_IN: begin
                    shift_in    <= {shift_in[6:0], dq0_mosi_i};
                    bit_counter <= bit_counter + 1;

                    if (bit_counter == 7) begin
                        bit_counter <= 0;
                        case (command)
                            8'h02: begin
                                if (write_enable_latch) begin
                                    automatic logic [23:0] waddr;
                                    waddr = (address[23:0] & 24'hFFFF00) 
                                          | ((address[7:0] + byte_counter) & 8'hFF); // page wrap
                                    memory[waddr] <= {shift_in[6:0], dq0_mosi_i};
                                    $display("[FLASH] Write [0x%06h] = 0x%02h", 
                                             waddr, {shift_in[6:0], dq0_mosi_i});
                                end
                                byte_counter <= byte_counter + 1;
                            end
                            8'h01: begin  // Write Status Reg
                                if (write_enable_latch)
                                    status_reg_1 <= {shift_in[6:0], dq0_mosi_i};
                                write_enable_latch <= 1'b0;
                                current_state <= STATE_IDLE;
                            end
                            default: current_state <= STATE_IDLE;
                        endcase
                    end
                end

                default: current_state <= STATE_IDLE;

            endcase
        end
    end

    // -------------------------------------------------------------------------
    // MISO output — present bit on negedge so master samples on posedge
    // -------------------------------------------------------------------------
    always_ff @(negedge sclk or posedge cs_n) begin
        if (cs_n)
            dq1_miso_o <= 1'b0;
        else if (current_state == STATE_DATA_OUT)
            dq1_miso_o <= shift_out[7];
        else
            dq1_miso_o <= 1'b0;
    end

endmodule