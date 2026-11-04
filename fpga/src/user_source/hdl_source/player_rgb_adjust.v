module player_rgb_adjust (
    input wire [23:0] rgb_in,
    input wire [3:0] brightness_index,
    input wire [2:0] contrast_index,
    output wire [23:0] rgb_out
);
    wire [2:0] contrast = contrast_index <= 4 ? contrast_index : 3'd2;
    wire [3:0] brightness = brightness_index <= 8 ? brightness_index : 4'd4;
    // floor((pixel-128)*(contrast+2)/4)+128+16*(brightness-4)
    // = floor(pixel*(contrast+2)/4)+16*brightness-32*contrast.
    wire signed [8:0] bias = $signed({1'b0,brightness,4'b0}) -
                             $signed({1'b0,contrast,5'b0});
    function [7:0] adjust;
        input [7:0] pixel;
        input [2:0] selector;
        input signed [8:0] offset;
        reg [9:0] triple;
        reg [10:0] quintuple;
        reg [8:0] gain;
        reg signed [9:0] value;
        begin
            triple = {2'b0,pixel} + ({2'b0,pixel} << 1);
            quintuple = {3'b0,pixel} + ({3'b0,pixel} << 2);
            case(selector)
                0: gain = {2'b0,pixel[7:1]};
                1: gain = {1'b0,triple[9:2]};
                2: gain = {1'b0,pixel};
                3: gain = quintuple[10:2];
                4: gain = triple[9:1];
                default: gain = {1'b0,pixel};
            endcase
            value = $signed({1'b0,gain}) + $signed({offset[8],offset});
            adjust = value[9] ? 8'd0 : value[8] ? 8'd255 : value[7:0];
        end
    endfunction
    assign rgb_out = {adjust(rgb_in[23:16],contrast,bias),
                      adjust(rgb_in[15:8],contrast,bias),
                      adjust(rgb_in[7:0],contrast,bias)};
endmodule
