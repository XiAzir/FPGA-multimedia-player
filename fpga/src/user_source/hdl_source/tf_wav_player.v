// 50 MHz single-clock WAV sector reader and sample FIFO.
// sample_data is the registered FIFO head. sample_available qualifies it;
// sample_take consumes that head on the rising edge when available is high.
module tf_wav_player #(
    parameter [31:0] START_SECTOR = 32'd0,
    parameter [31:0] EXPECTED_DATA_BYTES = 32'd768000,
    parameter integer FIFO_DEPTH = 2048
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        sd_init_done,
    output reg         sd_read,
    output reg [31:0]  sd_addr,
    input  wire [7:0]  sd_data,
    input  wire        sd_valid,
    input  wire        sd_end,
    input  wire        sample_take,
    output wire [15:0] sample_data,
    output wire        sample_available,
    output reg         primed,
    output reg         error
);

    localparam integer PTR_WIDTH = (FIFO_DEPTH <= 512) ? 9 : 11;
    localparam [12:0] FIFO_DEPTH_COUNT = FIFO_DEPTH;
    localparam [12:0] PRIME_LEVEL = FIFO_DEPTH / 2;

    localparam [2:0] ST_WAIT_INIT = 3'd0;
    localparam [2:0] ST_READY     = 3'd1;
    localparam [2:0] ST_ACTIVE    = 3'd2;
    localparam [2:0] ST_GAP0      = 3'd3;
    localparam [2:0] ST_GAP1      = 3'd4;
    localparam [2:0] ST_GAP2      = 3'd5;
    localparam [2:0] ST_HALTED    = 3'd6;

    reg [2:0] state;
    reg [8:0] sector_byte;
    reg [31:0] data_bytes_seen;
    reg [7:0] low_byte;
    reg low_byte_valid;
    reg header_bad;
    reg header_done;

    // A synchronous read port is inferred for the sample RAM. The head
    // register is prefetched whenever it is invalid, so consumers need no
    // extra read latency: take is accepted only while sample_available=1.
    reg [15:0] fifo_mem [0:FIFO_DEPTH-1];
    reg [PTR_WIDTH-1:0] wr_ptr;
    reg [PTR_WIDTH-1:0] rd_ptr;
    reg [12:0] fifo_count;
    reg [15:0] fifo_head;
    reg fifo_head_valid;

    wire fifo_pop = sample_take && sample_available;
    wire [12:0] fifo_count_after_pop = fifo_count - (fifo_pop ? 13'd1 : 13'd0);
    wire fifo_has_space_for_sector = (FIFO_DEPTH_COUNT - fifo_count) >= 13'd256;
    wire push_request = (state == ST_ACTIVE) && sd_valid &&
                        (header_done || (sector_byte >= 9'd44)) &&
                        (data_bytes_seen < EXPECTED_DATA_BYTES) &&
                        sector_byte[0];
    wire push_accept = push_request &&
                       ((fifo_count < FIFO_DEPTH_COUNT) || fifo_pop);
    wire [12:0] fifo_count_next = fifo_count_after_pop + (push_accept ? 13'd1 : 13'd0);

    assign sample_data = fifo_head;
    assign sample_available = fifo_head_valid && (fifo_count != 13'd0);

    // Validate only the fields required for this fixed, canonical PCM format.
    // Bytes not listed here are deliberately ignored.
    function header_byte_matches;
        input [8:0] offset;
        input [7:0] value;
        input [31:0] expected_bytes;
        begin
            header_byte_matches = 1'b1;
            case (offset)
                9'd0:  header_byte_matches = (value == 8'h52); // R
                9'd1:  header_byte_matches = (value == 8'h49); // I
                9'd2:  header_byte_matches = (value == 8'h46); // F
                9'd3:  header_byte_matches = (value == 8'h46); // F
                9'd8:  header_byte_matches = (value == 8'h57); // W
                9'd9:  header_byte_matches = (value == 8'h41); // A
                9'd10: header_byte_matches = (value == 8'h56); // V
                9'd11: header_byte_matches = (value == 8'h45); // E
                9'd12: header_byte_matches = (value == 8'h66); // f
                9'd13: header_byte_matches = (value == 8'h6d); // m
                9'd14: header_byte_matches = (value == 8'h74); // t
                9'd15: header_byte_matches = (value == 8'h20);
                9'd16: header_byte_matches = (value == 8'h10);
                9'd17: header_byte_matches = (value == 8'h00);
                9'd18: header_byte_matches = (value == 8'h00);
                9'd19: header_byte_matches = (value == 8'h00);
                9'd20: header_byte_matches = (value == 8'h01); // PCM
                9'd21: header_byte_matches = (value == 8'h00);
                9'd22: header_byte_matches = (value == 8'h01); // mono
                9'd23: header_byte_matches = (value == 8'h00);
                9'd24: header_byte_matches = (value == 8'h80); // 48000 Hz
                9'd25: header_byte_matches = (value == 8'hbb);
                9'd26: header_byte_matches = (value == 8'h00);
                9'd27: header_byte_matches = (value == 8'h00);
                9'd32: header_byte_matches = (value == 8'h02); // block align
                9'd33: header_byte_matches = (value == 8'h00);
                9'd34: header_byte_matches = (value == 8'h10); // 16 bits
                9'd35: header_byte_matches = (value == 8'h00);
                9'd36: header_byte_matches = (value == 8'h64); // data
                9'd37: header_byte_matches = (value == 8'h61);
                9'd38: header_byte_matches = (value == 8'h74);
                9'd39: header_byte_matches = (value == 8'h61);
                9'd40: header_byte_matches = (value == expected_bytes[7:0]);
                9'd41: header_byte_matches = (value == expected_bytes[15:8]);
                9'd42: header_byte_matches = (value == expected_bytes[23:16]);
                9'd43: header_byte_matches = (value == expected_bytes[31:24]);
                default: header_byte_matches = 1'b1;
            endcase
        end
    endfunction

    wire prefetch_needed = !fifo_head_valid || fifo_pop;
    wire [PTR_WIDTH-1:0] prefetch_ptr = fifo_pop ?
        (rd_ptr + {{(PTR_WIDTH-1){1'b0}}, 1'b1}) : rd_ptr;
    wire prefetch_bypass = push_accept && (wr_ptr == prefetch_ptr);
    wire [15:0] prefetch_value = {sd_data, low_byte};

    always @(posedge clk) begin
        if (rst) begin
            state            <= ST_WAIT_INIT;
            sd_read          <= 1'b0;
            sd_addr          <= START_SECTOR;
            sector_byte      <= 9'd0;
            data_bytes_seen  <= 32'd0;
            low_byte         <= 8'd0;
            low_byte_valid   <= 1'b0;
            header_bad       <= 1'b0;
            header_done      <= 1'b0;
            wr_ptr           <= {PTR_WIDTH{1'b0}};
            rd_ptr           <= {PTR_WIDTH{1'b0}};
            fifo_count       <= 13'd0;
            fifo_head        <= 16'd0;
            fifo_head_valid  <= 1'b0;
            primed           <= 1'b0;
            error            <= 1'b0;
        end else begin
            // FIFO write and accounting. The sector admission rule reserves
            // room for a complete 256-sample sector before each request.
            if (push_accept) begin
                fifo_mem[wr_ptr] <= {sd_data, low_byte};
                wr_ptr <= wr_ptr + {{(PTR_WIDTH-1){1'b0}}, 1'b1};
            end
            if (push_request && !push_accept)
                error <= 1'b1;
            if (fifo_pop)
                rd_ptr <= rd_ptr + {{(PTR_WIDTH-1){1'b0}}, 1'b1};
            fifo_count <= fifo_count_next;

            // Sync-read prefetch with a write-through bypass for an empty
            // FIFO receiving its first item (or pointer wrap collision).
            if (prefetch_needed && (fifo_count_next != 13'd0)) begin
                if (prefetch_bypass)
                    fifo_head <= prefetch_value;
                else
                    fifo_head <= fifo_mem[prefetch_ptr];
                fifo_head_valid <= 1'b1;
            end else if (fifo_pop && (fifo_count_next == 13'd0)) begin
                fifo_head_valid <= 1'b0;
            end

            if (!primed && (fifo_count_next >= PRIME_LEVEL))
                primed <= 1'b1;
            if (sample_take && primed && !sample_available)
                error <= 1'b1;

            case (state)
                ST_WAIT_INIT: begin
                    sd_read <= 1'b0;
                    if (sd_init_done)
                        state <= ST_READY;
                end
                ST_READY: begin
                    sd_read <= 1'b0;
                    if (sd_init_done && !error && fifo_has_space_for_sector) begin
                        sd_read <= 1'b1;
                        sector_byte <= 9'd0;
                        if (data_bytes_seen == EXPECTED_DATA_BYTES) begin
                            sd_addr <= START_SECTOR;
                            data_bytes_seen <= 32'd0;
                            header_bad <= 1'b0;
                            header_done <= 1'b0;
                            low_byte_valid <= 1'b0;
                        end
                        state <= ST_ACTIVE;
                    end
                end
                ST_ACTIVE: begin
                    sd_read <= 1'b1;
                    if (sd_valid) begin
                        if (data_bytes_seen < EXPECTED_DATA_BYTES) begin
                            if (!header_done && (sector_byte < 9'd44)) begin
                                if (!header_byte_matches(sector_byte, sd_data, EXPECTED_DATA_BYTES))
                                    header_bad <= 1'b1;
                                if (sector_byte == 9'd43) begin
                                    if (header_bad || !header_byte_matches(sector_byte, sd_data, EXPECTED_DATA_BYTES)) begin
                                        error <= 1'b1;
                                        sd_read <= 1'b0;
                                        state <= ST_HALTED;
                                    end else begin
                                        header_done <= 1'b1;
                                    end
                                end
                            end else begin
                                if (!sector_byte[0]) begin
                                    low_byte <= sd_data;
                                    low_byte_valid <= 1'b1;
                                end else if (low_byte_valid) begin
                                    low_byte_valid <= 1'b0;
                                end
                                data_bytes_seen <= data_bytes_seen + 32'd1;
                            end
                        end
                        sector_byte <= sector_byte + 9'd1;
                    end

                    if (sd_end) begin
                        sd_read <= 1'b0;
                        state <= ST_GAP0;
                        if (data_bytes_seen >= EXPECTED_DATA_BYTES) begin
                            sd_addr <= START_SECTOR;
                        end else begin
                            sd_addr <= sd_addr + 32'd1;
                        end
                    end
                end
                ST_GAP0: begin
                    sd_read <= 1'b0;
                    state <= ST_GAP1;
                end
                ST_GAP1: begin
                    sd_read <= 1'b0;
                    state <= ST_GAP2;
                end
                ST_GAP2: begin
                    sd_read <= 1'b0;
                    state <= ST_READY;
                end
                ST_HALTED: begin
                    sd_read <= 1'b0;
                end
                default: begin
                    state <= ST_WAIT_INIT;
                    sd_read <= 1'b0;
                end
            endcase
        end
    end
endmodule
