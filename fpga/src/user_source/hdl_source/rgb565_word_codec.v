`timescale 1ns/1ps

module rgb565_pack32 (
    input         clk,
    input         rst,
    input         clear,
    input         pixel_en,
    input  [23:0] pixel_rgb,
    output reg    word_en,
    output reg [31:0] word_data
);
    reg first_pixel_valid;
    reg [15:0] first_pixel;
    wire [15:0] pixel_565 = {
        pixel_rgb[23:19], pixel_rgb[15:10], pixel_rgb[7:3]
    };

    always @(posedge clk) begin
        if (rst || clear) begin
            first_pixel_valid <= 1'b0;
            first_pixel <= 16'd0;
            word_en <= 1'b0;
            word_data <= 32'd0;
        end else begin
            word_en <= 1'b0;
            if (pixel_en) begin
                if (!first_pixel_valid) begin
                    first_pixel <= pixel_565;
                    first_pixel_valid <= 1'b1;
                end else begin
                    word_en <= 1'b1;
                    word_data <= {pixel_565, first_pixel};
                    first_pixel_valid <= 1'b0;
                end
            end
        end
    end
endmodule

module rgb565_unpack32 (
    input clk,
    input rst,
    input clear,
    input pixel_en,
    output reg [23:0] pixel_rgb,
    input word_empty,
    output word_pop,
    input [31:0] word_data,
    output reg underflow
);
    reg [31:0] reservoir_low;
    reg [2:0] half_count;
    reg pop_pending;
    reg [63:0] merged;
    reg [2:0] merged_count;
    reg have_pixel;
    reg [15:0] selected_pixel;
    reg [31:0] reservoir_high;
    wire [63:0] reservoir = {reservoir_high, reservoir_low};

    // The normal FIFO output retains the upper halfword until its next read.
    always @* begin
        case (half_count)
            3: reservoir_high = {16'd0, word_data[31:16]};
            4: reservoir_high = word_data;
            default: reservoir_high = 32'd0;
        endcase
    end

    always @* begin
        merged = reservoir;
        merged_count = half_count;
        if (pop_pending) begin
            case (half_count)
                0: merged = {32'd0, word_data};
                1: merged = {16'd0, word_data, reservoir[15:0]};
                2: merged = {word_data, reservoir[31:0]};
                default: merged = reservoir;
            endcase
            merged_count = half_count + 3'd2;
        end
        have_pixel = (merged_count != 0);
        selected_pixel = merged[15:0];
        if (pixel_en && have_pixel) begin
            merged = merged >> 16;
            merged_count = merged_count - 3'd1;
        end
    end

    assign word_pop = !(rst || clear || word_empty || (merged_count > 3'd2));

    always @(posedge clk) begin
        if (rst || clear) begin
            reservoir_low <= 32'd0;
            half_count <= 3'd0;
            pop_pending <= 1'b0;
            pixel_rgb <= 24'd0;
            underflow <= 1'b0;
        end else begin
            reservoir_low <= merged[31:0];
            half_count <= merged_count;
            pop_pending <= word_pop;
            if (pixel_en) begin
                if (have_pixel) begin
                    pixel_rgb <= {
                        selected_pixel[15:11], selected_pixel[15:13],
                        selected_pixel[10:5], selected_pixel[10:9],
                        selected_pixel[4:0], selected_pixel[4:2]
                    };
                end else begin
                    pixel_rgb <= 24'd0;
                    underflow <= 1'b1;
                end
            end else begin
                pixel_rgb <= 24'd0;
            end
        end
    end
endmodule
