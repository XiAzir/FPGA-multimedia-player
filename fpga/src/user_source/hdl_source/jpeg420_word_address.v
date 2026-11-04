// Packed words in JPEG420 MCU order: TL, TR, BL, BR 8x8 blocks.
// RGB888 emits six words per block row; RGB565 emits four words per block row.
// Each accepted memory word advances this address; stalls preserve position.
module jpeg420_word_address #(
    parameter RGB565 = 0
) (
    input wire clk, rst,
    input wire start,
    input wire [20:0] frame_base,
    input wire word_take,
    output wire [20:0] word_address
);
    generate if (RGB565) begin : compact565
        reg [20:0] base_q;
        reg [1:0] column;
        reg [2:0] row;
        reg [1:0] part;
        reg [5:0] mx;
        reg [4:0] my;
        wire [8:0] pixel_row = {my,part[1],row};
        wire [11:0] high_offset = {pixel_row,2'b0} + {3'b0,pixel_row} + {9'b0,mx[5:3]};
        assign word_address = base_q + {3'b0,high_offset,mx[2:0],part[0],column};
        always @(posedge clk or posedge rst) begin
            if (rst) begin base_q<=0;column<=0;row<=0;part<=0;mx<=0;my<=0;end
            else if(start) begin base_q<=frame_base;column<=0;row<=0;part<=0;mx<=0;my<=0;end
            else if(word_take) begin
                column<=column+1'b1;
                if(column==3) begin
                    row<=row+1'b1;
                    if(row==7) begin
                        part<=part+1'b1;
                        if(part==3) begin
                            if(mx==39) begin mx<=0;my<=my+1'b1;end
                            else mx<=mx+1'b1;
                        end
                    end
                end
            end
        end
    end else begin : legacy888
        reg [20:0] linear_address;
        assign word_address = linear_address;
    reg [2:0] word_column;
    reg [2:0] block_row;
    reg [1:0] block_part;
    reg [5:0] mcu_column;
    localparam ROW_WORDS = RGB565 ? 4 : 6;
    localparam STRIDE = RGB565 ? 320 : 480;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            linear_address <= 0;
            word_column <= 0;
            block_row <= 0;
            block_part <= 0;
            mcu_column <= 0;
        end else if (start) begin
            linear_address <= frame_base;
            word_column <= 0;
            block_row <= 0;
            block_part <= 0;
            mcu_column <= 0;
        end else if (word_take) begin
            if (word_column != ROW_WORDS-1) begin
                word_column <= word_column + 1'b1;
                linear_address <= linear_address + 1'b1;
            end else begin
                word_column <= 0;
                if (block_row != 7) begin
                    block_row <= block_row + 1'b1;
                    linear_address <= linear_address + STRIDE-(ROW_WORDS-1);
                end else begin
                    block_row <= 0;
                    block_part <= block_part + 1'b1;
                    case (block_part)
                        0,2: linear_address <= linear_address - (7*STRIDE-1);
                        1: linear_address <= linear_address + STRIDE-(2*ROW_WORDS-1);
                        3: begin
                            if (mcu_column == 39) begin
                                mcu_column <= 0;
                                linear_address <= linear_address + 1'b1;
                            end else begin
                                mcu_column <= mcu_column + 1'b1;
                                linear_address <= linear_address - (15*STRIDE-1);
                            end
                        end
                    endcase
                end
            end
        end
    end
    end endgenerate
endmodule
