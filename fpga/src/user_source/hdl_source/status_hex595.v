`timescale 1ns/1ps

// Eight-digit active-low seven-segment display using the AC201's cascaded
// 74HC595s. SCAN_HZ is the requested per-digit slot rate; the blank and data
// transfers add about 32 us per slot at the default 50 MHz / 1 MHz settings.
module status_hex595 #(
    parameter integer CLK_HZ  = 50000000,
    parameter integer SCAN_HZ = 1000
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] hex_value,
    output reg         seg7_dio,
    output reg         seg7_sclk,
    output reg         seg7_rclk
);

localparam integer HALF_DIV_RAW = (CLK_HZ + 1999999) / 2000000;
localparam integer HALF_DIV = (HALF_DIV_RAW < 1) ? 1 : HALF_DIV_RAW;
localparam integer SLOT_RAW = (SCAN_HZ > 0) ? (CLK_HZ / SCAN_HZ) : 1;
localparam integer SLOT_CYCLES = (SLOT_RAW < 1) ? 1 : SLOT_RAW;

localparam [2:0] ST_WAIT_SLOT  = 3'd0,
                 ST_SHIFT_SET  = 3'd1,
                 ST_SHIFT_RISE = 3'd2,
                 ST_SHIFT_FALL = 3'd3,
                 ST_LATCH_HIGH = 3'd4,
                 ST_LATCH_LOW  = 3'd5;

reg [2:0] state;
reg [31:0] slot_count;
reg [31:0] half_count;
reg [31:0] frame_value;
reg [15:0] shift_word;
reg [4:0] bit_count;
reg [2:0] digit_index;
reg tx_is_blank;

function [6:0] decode_hex;
    input [3:0] value;
    begin
        case (value)
            4'h0: decode_hex = 7'b1000000;
            4'h1: decode_hex = 7'b1111001;
            4'h2: decode_hex = 7'b0100100;
            4'h3: decode_hex = 7'b0110000;
            4'h4: decode_hex = 7'b0011001;
            4'h5: decode_hex = 7'b0010010;
            4'h6: decode_hex = 7'b0000010;
            4'h7: decode_hex = 7'b1111000;
            4'h8: decode_hex = 7'b0000000;
            4'h9: decode_hex = 7'b0010000;
            4'hA: decode_hex = 7'b0001000;
            4'hB: decode_hex = 7'b0000011;
            4'hC: decode_hex = 7'b1000110;
            4'hD: decode_hex = 7'b0100001;
            4'hE: decode_hex = 7'b0000110;
            4'hF: decode_hex = 7'b0001110;
            default: decode_hex = 7'b1111111;
        endcase
    end
endfunction

function [3:0] digit_nibble;
    input [31:0] value;
    input [2:0] index;
    begin
        case (index)
            3'd0: digit_nibble = value[3:0];
            3'd1: digit_nibble = value[7:4];
            3'd2: digit_nibble = value[11:8];
            3'd3: digit_nibble = value[15:12];
            3'd4: digit_nibble = value[19:16];
            3'd5: digit_nibble = value[23:20];
            3'd6: digit_nibble = value[27:24];
            3'd7: digit_nibble = value[31:28];
            default: digit_nibble = 4'h0;
        endcase
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state       <= ST_WAIT_SLOT;
        slot_count  <= SLOT_CYCLES - 1;
        half_count  <= 32'd0;
        frame_value <= 32'd0;
        shift_word  <= 16'hFF00;
        bit_count   <= 5'd15;
        digit_index <= 3'd0;
        tx_is_blank <= 1'b1;
        seg7_dio    <= 1'b1;
        seg7_sclk   <= 1'b0;
        seg7_rclk   <= 1'b0;
    end else begin
        case (state)
            ST_WAIT_SLOT: begin
                seg7_sclk <= 1'b0;
                seg7_rclk <= 1'b0;
                if (slot_count >= SLOT_CYCLES - 1) begin
                    slot_count  <= 32'd0;
                    shift_word  <= 16'hFF00; // segments off, no digit selected
                    bit_count   <= 5'd15;
                    tx_is_blank <= 1'b1;
                    if (digit_index == 3'd0)
                        frame_value <= hex_value;
                    state <= ST_SHIFT_SET;
                end else begin
                    slot_count <= slot_count + 1'b1;
                end
            end

            ST_SHIFT_SET: begin
                seg7_sclk  <= 1'b0;
                seg7_dio   <= shift_word[15];
                half_count <= 32'd0;
                state      <= ST_SHIFT_RISE;
            end

            ST_SHIFT_RISE: begin
                if (half_count >= HALF_DIV - 1) begin
                    seg7_sclk  <= 1'b1;
                    half_count <= 32'd0;
                    state      <= ST_SHIFT_FALL;
                end else begin
                    half_count <= half_count + 1'b1;
                end
            end

            ST_SHIFT_FALL: begin
                if (half_count >= HALF_DIV - 1) begin
                    seg7_sclk  <= 1'b0;
                    half_count <= 32'd0;
                    shift_word <= {shift_word[14:0], 1'b0};
                    if (bit_count == 0) begin
                        state <= ST_LATCH_HIGH;
                    end else begin
                        bit_count <= bit_count - 1'b1;
                        state <= ST_SHIFT_SET;
                    end
                end else begin
                    half_count <= half_count + 1'b1;
                end
            end

            ST_LATCH_HIGH: begin
                seg7_rclk <= 1'b1;
                state <= ST_LATCH_LOW;
            end

            ST_LATCH_LOW: begin
                seg7_rclk <= 1'b0;
                if (tx_is_blank) begin
                    shift_word <= {1'b1,
                                   decode_hex(digit_nibble(frame_value, digit_index)),
                                   (8'b00000001 << digit_index)};
                    bit_count <= 5'd15;
                    tx_is_blank <= 1'b0;
                    state <= ST_SHIFT_SET;
                end else begin
                    digit_index <= digit_index + 1'b1;
                    slot_count <= 32'd0;
                    state <= ST_WAIT_SLOT;
                end
            end

            default: begin
                state <= ST_WAIT_SLOT;
                slot_count <= SLOT_CYCLES - 1;
                half_count <= 32'd0;
                shift_word <= 16'hFF00;
                bit_count <= 5'd15;
                tx_is_blank <= 1'b1;
                seg7_dio <= 1'b1;
                seg7_sclk <= 1'b0;
                seg7_rclk <= 1'b0;
            end
        endcase
    end
end

endmodule
