module mjp_file_reader (
    input wire clk,
    input wire rst,
    input wire start,
    input wire next_frame,

    output reg card_read,
    output reg [31:0] card_addr,
    input wire [7:0] card_data,
    input wire card_valid,
    input wire card_end,
    input wire file_error,

    output reg file_ready,
    output reg [8:0] last_index,
    output reg frame_ready,
    output reg [8:0] frame_index,
    output reg [31:0] frame_length,

    output reg jpeg_valid,
    output reg [31:0] jpeg_data,
    output reg [3:0] jpeg_strb,
    output reg jpeg_last,
    input wire jpeg_accept,

    output reg frame_sent,
    output reg [8:0] sequence_index,
    output wire busy,
    output reg error
);
    localparam [3:0] ST_WAIT_START = 4'd0;
    localparam [3:0] ST_FILL_GLOBAL = 4'd1;
    localparam [3:0] ST_FILE_READY = 4'd2;
    localparam [3:0] ST_FILL_FRAME = 4'd3;
    localparam [3:0] ST_STREAM = 4'd4;
    localparam [3:0] ST_FILL_JPEG = 4'd5;
    localparam [3:0] ST_ERROR = 4'd6;

    reg [3:0] state;
    reg [9:0] sector_write_count;
    reg [8:0] sector_read_index;
    reg [31:0] sector_cursor;
    reg [31:0] total_frames;
    reg [31:0] header_frame_index;
    reg [31:0] header_jpeg_length;
    reg [31:0] payload_remaining;
    reg [31:0] frame_byte_count;
    reg [31:0] word_accum;
    reg [1:0] word_fill;
    reg sector_loaded;
    reg sector_read_pending;
    reg tail_pending;
    reg [7:0] sector_q;

    (* ram_style = "bram" *) reg [7:0] sector_mem [0:511];

    wire sector_ram_read = (state == ST_STREAM) && sector_loaded &&
        (payload_remaining != 0) && !jpeg_valid && !sector_read_pending;

    assign busy = (state != ST_WAIT_START) && (state != ST_FILE_READY) &&
                  (state != ST_ERROR);

    task issue_sector;
        input [31:0] lba;
        input [3:0] next_state;
        begin
            card_addr <= lba;
            card_read <= 1'b1;
            sector_write_count <= 10'd0;
            state <= next_state;
        end
    endtask

    always @(posedge clk) begin
        if (state == ST_FILL_GLOBAL || state == ST_FILL_FRAME || state == ST_FILL_JPEG) begin
            if (card_valid)
                sector_mem[sector_write_count[8:0]] <= card_data;
        end else if (sector_ram_read) begin
            sector_q <= sector_mem[sector_read_index];
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= ST_WAIT_START;
            card_read <= 1'b0;
            card_addr <= 32'd0;
            sector_write_count <= 10'd0;
            sector_read_index <= 9'd0;
            sector_cursor <= 32'd0;
            total_frames <= 32'd0;
            header_frame_index <= 32'd0;
            header_jpeg_length <= 32'd0;
            payload_remaining <= 32'd0;
            frame_byte_count <= 32'd0;
            word_accum <= 32'd0;
            word_fill <= 2'd0;
            sector_loaded <= 1'b0;
            sector_read_pending <= 1'b0;
            tail_pending <= 1'b0;
            file_ready <= 1'b0;
            last_index <= 9'd0;
            frame_ready <= 1'b0;
            frame_index <= 9'd0;
            frame_length <= 32'd0;
            jpeg_valid <= 1'b0;
            jpeg_data <= 32'd0;
            jpeg_strb <= 4'd0;
            jpeg_last <= 1'b0;
            frame_sent <= 1'b0;
            sequence_index <= 9'd0;
            error <= 1'b0;
        end else begin
            card_read <= 1'b0;
            frame_ready <= 1'b0;
            frame_sent <= 1'b0;

            if (file_error) begin
                error <= 1'b1;
                state <= ST_ERROR;
                card_read <= 1'b0;
            end else begin
                case (state)
                    ST_WAIT_START: begin
                        if (start)
                            issue_sector(32'd0, ST_FILL_GLOBAL);
                    end

                    ST_FILL_GLOBAL: begin
                        if (card_valid) begin
                            if (sector_write_count >= 10'd16 && sector_write_count <= 10'd19)
                                total_frames[(sector_write_count-10'd16)*8 +: 8] <= card_data;
                            sector_write_count <= sector_write_count + 10'd1;
                        end
                        if (card_end) begin
                            file_ready <= 1'b1;
                            last_index <= total_frames[8:0] - 9'd1;
                            sector_cursor <= 32'd1;
                            state <= ST_FILE_READY;
                        end
                    end

                    ST_FILE_READY: begin
                        if (next_frame) begin
                            issue_sector(sector_cursor, ST_FILL_FRAME);
                            sector_cursor <= sector_cursor + 32'd1;
                        end
                    end

                    ST_FILL_FRAME: begin
                        if (card_valid) begin
                            if (sector_write_count >= 10'd8 && sector_write_count <= 10'd11)
                                header_frame_index[(sector_write_count-10'd8)*8 +: 8] <= card_data;
                            if (sector_write_count >= 10'd12 && sector_write_count <= 10'd15)
                                header_jpeg_length[(sector_write_count-10'd12)*8 +: 8] <= card_data;
                            sector_write_count <= sector_write_count + 10'd1;
                        end
                        if (card_end) begin
                            frame_index <= header_frame_index[8:0];
                            frame_length <= header_jpeg_length;
                            payload_remaining <= header_jpeg_length;
                            frame_byte_count <= 32'd0;
                            sector_read_index <= 9'd0;
                            sector_loaded <= 1'b0;
                            sector_read_pending <= 1'b0;
                            word_accum <= 32'd0;
                            word_fill <= 2'd0;
                            tail_pending <= (header_jpeg_length == 0);
                            frame_ready <= 1'b1;
                            state <= ST_STREAM;
                        end
                    end

                    ST_STREAM: begin
                        if (jpeg_valid) begin
                            if (jpeg_accept) begin
                                jpeg_valid <= 1'b0;
                                jpeg_last <= 1'b0;
                                if (jpeg_last) begin
                                    frame_sent <= 1'b1;
                                    sequence_index <= frame_index;
                                    state <= ST_FILE_READY;
                                    if (frame_index == last_index)
                                        sector_cursor <= 32'd1;
                                end
                            end
                        end else if (tail_pending) begin
                            jpeg_valid <= 1'b1;
                            jpeg_data <= 32'd0;
                            jpeg_strb <= 4'b0000;
                            jpeg_last <= 1'b1;
                            tail_pending <= 1'b0;
                        end else if (payload_remaining != 0 && !sector_loaded) begin
                            issue_sector(sector_cursor, ST_FILL_JPEG);
                            sector_cursor <= sector_cursor + 32'd1;
                        end else if (sector_read_pending) begin
                            sector_read_pending <= 1'b0;
                            sector_read_index <= sector_read_index + 9'd1;
                            payload_remaining <= payload_remaining - 32'd1;
                            frame_byte_count <= frame_byte_count + 32'd1;
                            word_accum[word_fill*8 +: 8] <= sector_q;
                            if (word_fill == 2'd3) begin
                                jpeg_data <= {sector_q, word_accum[23:0]};
                                jpeg_strb <= 4'b1111;
                                jpeg_valid <= 1'b1;
                                word_fill <= 2'd0;
                            end else if (payload_remaining == 32'd1) begin
                                case (word_fill)
                                    2'd0: begin jpeg_data <= {24'd0, sector_q}; jpeg_strb <= 4'b0001; end
                                    2'd1: begin jpeg_data <= {16'd0, sector_q, word_accum[7:0]}; jpeg_strb <= 4'b0011; end
                                    default: begin jpeg_data <= {8'd0, sector_q, word_accum[15:0]}; jpeg_strb <= 4'b0111; end
                                endcase
                                jpeg_valid <= 1'b1;
                                word_fill <= 2'd0;
                            end else begin
                                word_fill <= word_fill + 2'd1;
                            end

                            if (payload_remaining == 32'd1)
                                tail_pending <= 1'b1;
                            if (sector_read_index == 9'd511)
                                sector_loaded <= 1'b0;
                        end else if (sector_ram_read) begin
                            sector_read_pending <= 1'b1;
                        end
                    end

                    ST_FILL_JPEG: begin
                        if (card_valid)
                            sector_write_count <= sector_write_count + 10'd1;
                        if (card_end) begin
                            sector_loaded <= 1'b1;
                            sector_read_index <= 9'd0;
                            sector_read_pending <= 1'b0;
                            state <= ST_STREAM;
                        end
                    end

                    ST_ERROR: begin
                        error <= 1'b1;
                    end

                    default: begin
                        state <= ST_WAIT_START;
                    end
                endcase
            end
        end
    end
endmodule
