module player_dynamic_text #(
    parameter integer CLK_FREQ_HZ = 25000000
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        vs,
    input  wire        de,
    input  wire        probe_mode,
    input  wire [23:0] rgb_in,
    output wire [23:0] rgb_out
);
    localparam integer TICK_WIDTH = (CLK_FREQ_HZ > 1) ? $clog2(CLK_FREQ_HZ) : 1;

    reg [TICK_WIDTH-1:0] second_tick;
    reg [3:0] minute_tens;
    reg [3:0] minute_ones;
    reg [3:0] second_tens;
    reg [3:0] second_ones;
    reg [3:0] display_minute_tens;
    reg [3:0] display_minute_ones;
    reg [3:0] display_second_tens;
    reg [3:0] display_second_ones;

    reg [9:0] x_pos;
    reg [8:0] y_pos;
    reg de_prev;
    reg vs_prev;
    reg arm_first_line;
    reg [9:0] scroll_phase;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            second_tick        <= {TICK_WIDTH{1'b0}};
            minute_tens        <= 4'd0;
            minute_ones        <= 4'd0;
            second_tens        <= 4'd0;
            second_ones        <= 4'd0;
            display_minute_tens  <= 4'd0;
            display_minute_ones  <= 4'd0;
            display_second_tens <= 4'd0;
            display_second_ones <= 4'd0;
            x_pos              <= 10'd0;
            y_pos              <= 9'd0;
            de_prev            <= 1'b0;
            vs_prev            <= 1'b0;
            arm_first_line     <= 1'b1;
            scroll_phase       <= 10'd0;
        end else begin
            if (second_tick == CLK_FREQ_HZ - 1) begin
                second_tick <= {TICK_WIDTH{1'b0}};
                if (second_ones == 4'd9) begin
                    second_ones <= 4'd0;
                    if (second_tens == 4'd5) begin
                        second_tens <= 4'd0;
                        if (minute_ones == 4'd9) begin
                            minute_ones <= 4'd0;
                            if (minute_tens == 4'd9)
                                minute_tens <= 4'd0;
                            else
                                minute_tens <= minute_tens + 4'd1;
                        end else begin
                            minute_ones <= minute_ones + 4'd1;
                        end
                    end else begin
                        second_tens <= second_tens + 4'd1;
                    end
                end else begin
                    second_ones <= second_ones + 4'd1;
                end
            end else begin
                second_tick <= second_tick + {{(TICK_WIDTH-1){1'b0}}, 1'b1};
            end

            de_prev <= de;
            vs_prev <= vs;
            if (vs != vs_prev) begin
                x_pos <= 10'd0;
                y_pos <= 9'd0;
                arm_first_line <= 1'b1;
                display_minute_tens  <= minute_tens;
                display_minute_ones  <= minute_ones;
                display_second_tens <= second_tens;
                display_second_ones <= second_ones;
                if (vs && scroll_phase == 10'd823)
                    scroll_phase <= 10'd0;
                else if (vs)
                    scroll_phase <= scroll_phase + 10'd1;
            end else if (de) begin
                x_pos <= x_pos + 10'd1;
                if (!de_prev && arm_first_line) begin
                    y_pos <= 9'd0;
                    arm_first_line <= 1'b0;
                end
            end else begin
                x_pos <= 10'd0;
                if (de_prev && y_pos != 9'd511)
                    y_pos <= y_pos + 9'd1;
            end
        end
    end

    function [4:0] glyph_row;
        input [7:0] character;
        input [2:0] row;
        begin
            glyph_row = 5'b00000;
            case (character)
                "A": case (row)
                    0:glyph_row=5'b01110; 1:glyph_row=5'b10001; 2:glyph_row=5'b10001;
                    3:glyph_row=5'b11111; 4:glyph_row=5'b10001; 5:glyph_row=5'b10001;
                    6:glyph_row=5'b10001; default:glyph_row=5'b00000;
                endcase
                "D": case (row)
                    0:glyph_row=5'b11110; 1:glyph_row=5'b10001; 2:glyph_row=5'b10001;
                    3:glyph_row=5'b10001; 4:glyph_row=5'b10001; 5:glyph_row=5'b10001;
                    6:glyph_row=5'b11110; default:glyph_row=5'b00000;
                endcase
                "E": case (row)
                    0:glyph_row=5'b11111; 1:glyph_row=5'b10000; 2:glyph_row=5'b10000;
                    3:glyph_row=5'b11110; 4:glyph_row=5'b10000; 5:glyph_row=5'b10000;
                    6:glyph_row=5'b11111; default:glyph_row=5'b00000;
                endcase
                "F": case (row)
                    0:glyph_row=5'b11111; 1:glyph_row=5'b10000; 2:glyph_row=5'b10000;
                    3:glyph_row=5'b11110; 4:glyph_row=5'b10000; 5:glyph_row=5'b10000;
                    6:glyph_row=5'b10000; default:glyph_row=5'b00000;
                endcase
                "G": case (row)
                    0:glyph_row=5'b01111; 1:glyph_row=5'b10000; 2:glyph_row=5'b10000;
                    3:glyph_row=5'b10111; 4:glyph_row=5'b10001; 5:glyph_row=5'b10001;
                    6:glyph_row=5'b01111; default:glyph_row=5'b00000;
                endcase
                "I": case (row)
                    0:glyph_row=5'b11111; 1:glyph_row=5'b00100; 2:glyph_row=5'b00100;
                    3:glyph_row=5'b00100; 4:glyph_row=5'b00100; 5:glyph_row=5'b00100;
                    6:glyph_row=5'b11111; default:glyph_row=5'b00000;
                endcase
                "L": case (row)
                    0:glyph_row=5'b10000; 1:glyph_row=5'b10000; 2:glyph_row=5'b10000;
                    3:glyph_row=5'b10000; 4:glyph_row=5'b10000; 5:glyph_row=5'b10000;
                    6:glyph_row=5'b11111; default:glyph_row=5'b00000;
                endcase
                "M": case (row)
                    0:glyph_row=5'b10001; 1:glyph_row=5'b11011; 2:glyph_row=5'b10101;
                    3:glyph_row=5'b10101; 4:glyph_row=5'b10001; 5:glyph_row=5'b10001;
                    6:glyph_row=5'b10001; default:glyph_row=5'b00000;
                endcase
                "N": case (row)
                    0:glyph_row=5'b10001; 1:glyph_row=5'b11001; 2:glyph_row=5'b10101;
                    3:glyph_row=5'b10011; 4:glyph_row=5'b10001; 5:glyph_row=5'b10001;
                    6:glyph_row=5'b10001; default:glyph_row=5'b00000;
                endcase
                "P": case (row)
                    0:glyph_row=5'b11110; 1:glyph_row=5'b10001; 2:glyph_row=5'b10001;
                    3:glyph_row=5'b11110; 4:glyph_row=5'b10000; 5:glyph_row=5'b10000;
                    6:glyph_row=5'b10000; default:glyph_row=5'b00000;
                endcase
                "R": case (row)
                    0:glyph_row=5'b11110; 1:glyph_row=5'b10001; 2:glyph_row=5'b10001;
                    3:glyph_row=5'b11110; 4:glyph_row=5'b10100; 5:glyph_row=5'b10010;
                    6:glyph_row=5'b10001; default:glyph_row=5'b00000;
                endcase
                "U": case (row)
                    0:glyph_row=5'b10001; 1:glyph_row=5'b10001; 2:glyph_row=5'b10001;
                    3:glyph_row=5'b10001; 4:glyph_row=5'b10001; 5:glyph_row=5'b10001;
                    6:glyph_row=5'b01110; default:glyph_row=5'b00000;
                endcase
                "Y": case (row)
                    0:glyph_row=5'b10001; 1:glyph_row=5'b10001; 2:glyph_row=5'b01010;
                    3:glyph_row=5'b00100; 4:glyph_row=5'b00100; 5:glyph_row=5'b00100;
                    6:glyph_row=5'b00100; default:glyph_row=5'b00000;
                endcase
                "0": case (row)
                    0:glyph_row=5'b01110; 1:glyph_row=5'b10001; 2:glyph_row=5'b10011;
                    3:glyph_row=5'b10101; 4:glyph_row=5'b11001; 5:glyph_row=5'b10001;
                    6:glyph_row=5'b01110; default:glyph_row=5'b00000;
                endcase
                "1": case (row)
                    0:glyph_row=5'b00100; 1:glyph_row=5'b01100; 2:glyph_row=5'b00100;
                    3:glyph_row=5'b00100; 4:glyph_row=5'b00100; 5:glyph_row=5'b00100;
                    6:glyph_row=5'b01110; default:glyph_row=5'b00000;
                endcase
                "2": case (row)
                    0:glyph_row=5'b01110; 1:glyph_row=5'b10001; 2:glyph_row=5'b00001;
                    3:glyph_row=5'b00010; 4:glyph_row=5'b00100; 5:glyph_row=5'b01000;
                    6:glyph_row=5'b11111; default:glyph_row=5'b00000;
                endcase
                "3": case (row)
                    0:glyph_row=5'b11110; 1:glyph_row=5'b00001; 2:glyph_row=5'b00001;
                    3:glyph_row=5'b01110; 4:glyph_row=5'b00001; 5:glyph_row=5'b00001;
                    6:glyph_row=5'b11110; default:glyph_row=5'b00000;
                endcase
                "4": case (row)
                    0:glyph_row=5'b10010; 1:glyph_row=5'b10010; 2:glyph_row=5'b10010;
                    3:glyph_row=5'b11111; 4:glyph_row=5'b00010; 5:glyph_row=5'b00010;
                    6:glyph_row=5'b00010; default:glyph_row=5'b00000;
                endcase
                "5": case (row)
                    0:glyph_row=5'b11111; 1:glyph_row=5'b10000; 2:glyph_row=5'b10000;
                    3:glyph_row=5'b11110; 4:glyph_row=5'b00001; 5:glyph_row=5'b00001;
                    6:glyph_row=5'b11110; default:glyph_row=5'b00000;
                endcase
                "6": case (row)
                    0:glyph_row=5'b01111; 1:glyph_row=5'b10000; 2:glyph_row=5'b10000;
                    3:glyph_row=5'b11110; 4:glyph_row=5'b10001; 5:glyph_row=5'b10001;
                    6:glyph_row=5'b01110; default:glyph_row=5'b00000;
                endcase
                "7": case (row)
                    0:glyph_row=5'b11111; 1:glyph_row=5'b00001; 2:glyph_row=5'b00010;
                    3:glyph_row=5'b00100; 4:glyph_row=5'b01000; 5:glyph_row=5'b01000;
                    6:glyph_row=5'b01000; default:glyph_row=5'b00000;
                endcase
                "8": case (row)
                    0:glyph_row=5'b01110; 1:glyph_row=5'b10001; 2:glyph_row=5'b10001;
                    3:glyph_row=5'b01110; 4:glyph_row=5'b10001; 5:glyph_row=5'b10001;
                    6:glyph_row=5'b01110; default:glyph_row=5'b00000;
                endcase
                "9": case (row)
                    0:glyph_row=5'b01110; 1:glyph_row=5'b10001; 2:glyph_row=5'b10001;
                    3:glyph_row=5'b01111; 4:glyph_row=5'b00001; 5:glyph_row=5'b00001;
                    6:glyph_row=5'b11110; default:glyph_row=5'b00000;
                endcase
                ":": case (row)
                    2:glyph_row=5'b00100; 3:glyph_row=5'b00100; 5:glyph_row=5'b00100;
                    6:glyph_row=5'b00100; default:glyph_row=5'b00000;
                endcase
                default: glyph_row = 5'b00000;
            endcase
        end
    endfunction

    function [15:0] cn_glyph_row;
        input [3:0] character_index;
        input [3:0] row_index;
        begin
            // SimSun 16px ��ģ��16��16 ��ɫ��bit15 ��Ӧ�����С�
            cn_glyph_row = 16'h0000;
            case (character_index)
                4'd0: case (row_index)
                    4'd0: cn_glyph_row = 16'h0100;
                    4'd1: cn_glyph_row = 16'h211E;
                    4'd2: cn_glyph_row = 16'h1112;
                    4'd3: cn_glyph_row = 16'h17D2;
                    4'd4: cn_glyph_row = 16'h8112;
                    4'd5: cn_glyph_row = 16'h411E;
                    4'd6: cn_glyph_row = 16'h4112;
                    4'd7: cn_glyph_row = 16'h17D2;
                    4'd8: cn_glyph_row = 16'h1452;
                    4'd9: cn_glyph_row = 16'h245E;
                    4'd10: cn_glyph_row = 16'hE452;
                    4'd11: cn_glyph_row = 16'h27D2;
                    4'd12: cn_glyph_row = 16'h2452;
                    4'd13: cn_glyph_row = 16'h2022;
                    4'd14: cn_glyph_row = 16'h202A;
                    4'd15: cn_glyph_row = 16'h0044;
                    default: cn_glyph_row = 16'h0000;
                endcase
                4'd1: case (row_index)
                    4'd0: cn_glyph_row = 16'h0440;
                    4'd1: cn_glyph_row = 16'h0440;
                    4'd2: cn_glyph_row = 16'h0440;
                    4'd3: cn_glyph_row = 16'h0444;
                    4'd4: cn_glyph_row = 16'h0448;
                    4'd5: cn_glyph_row = 16'h7C50;
                    4'd6: cn_glyph_row = 16'h0460;
                    4'd7: cn_glyph_row = 16'h0440;
                    4'd8: cn_glyph_row = 16'h0440;
                    4'd9: cn_glyph_row = 16'h0440;
                    4'd10: cn_glyph_row = 16'h0440;
                    4'd11: cn_glyph_row = 16'h0442;
                    4'd12: cn_glyph_row = 16'h1C42;
                    4'd13: cn_glyph_row = 16'hE442;
                    4'd14: cn_glyph_row = 16'h443E;
                    4'd15: cn_glyph_row = 16'h0400;
                    default: cn_glyph_row = 16'h0000;
                endcase
                4'd2: case (row_index)
                    4'd0: cn_glyph_row = 16'h0100;
                    4'd1: cn_glyph_row = 16'h1110;
                    4'd2: cn_glyph_row = 16'h1108;
                    4'd3: cn_glyph_row = 16'h2124;
                    4'd4: cn_glyph_row = 16'h40C0;
                    4'd5: cn_glyph_row = 16'h0300;
                    4'd6: cn_glyph_row = 16'h0C00;
                    4'd7: cn_glyph_row = 16'h3FF8;
                    4'd8: cn_glyph_row = 16'hD008;
                    4'd9: cn_glyph_row = 16'h1FF8;
                    4'd10: cn_glyph_row = 16'h1008;
                    4'd11: cn_glyph_row = 16'h1FF8;
                    4'd12: cn_glyph_row = 16'h1008;
                    4'd13: cn_glyph_row = 16'h1008;
                    4'd14: cn_glyph_row = 16'h1FF8;
                    4'd15: cn_glyph_row = 16'h1008;
                    default: cn_glyph_row = 16'h0000;
                endcase
                4'd3: case (row_index)
                    4'd0: cn_glyph_row = 16'h2050;
                    4'd1: cn_glyph_row = 16'h2048;
                    4'd2: cn_glyph_row = 16'h2FFE;
                    4'd3: cn_glyph_row = 16'h2040;
                    4'd4: cn_glyph_row = 16'h27FC;
                    4'd5: cn_glyph_row = 16'hFC44;
                    4'd6: cn_glyph_row = 16'h27FC;
                    4'd7: cn_glyph_row = 16'h2444;
                    4'd8: cn_glyph_row = 16'h27FC;
                    4'd9: cn_glyph_row = 16'h2444;
                    4'd10: cn_glyph_row = 16'h2008;
                    4'd11: cn_glyph_row = 16'h2FFE;
                    4'd12: cn_glyph_row = 16'h2208;
                    4'd13: cn_glyph_row = 16'h2108;
                    4'd14: cn_glyph_row = 16'h2128;
                    4'd15: cn_glyph_row = 16'h2010;
                    default: cn_glyph_row = 16'h0000;
                endcase
                4'd4: case (row_index)
                    4'd0: cn_glyph_row = 16'h1080;
                    4'd1: cn_glyph_row = 16'h1080;
                    4'd2: cn_glyph_row = 16'h5080;
                    4'd3: cn_glyph_row = 16'h50FC;
                    4'd4: cn_glyph_row = 16'h7D54;
                    4'd5: cn_glyph_row = 16'h5254;
                    4'd6: cn_glyph_row = 16'h9054;
                    4'd7: cn_glyph_row = 16'h1094;
                    4'd8: cn_glyph_row = 16'h1C94;
                    4'd9: cn_glyph_row = 16'hF124;
                    4'd10: cn_glyph_row = 16'h5224;
                    4'd11: cn_glyph_row = 16'h1044;
                    4'd12: cn_glyph_row = 16'h1044;
                    4'd13: cn_glyph_row = 16'h1084;
                    4'd14: cn_glyph_row = 16'h1128;
                    4'd15: cn_glyph_row = 16'h1010;
                    default: cn_glyph_row = 16'h0000;
                endcase
                4'd5: case (row_index)
                    4'd0: cn_glyph_row = 16'h2040;
                    4'd1: cn_glyph_row = 16'h2020;
                    4'd2: cn_glyph_row = 16'h23FE;
                    4'd3: cn_glyph_row = 16'h3A02;
                    4'd4: cn_glyph_row = 16'h4C04;
                    4'd5: cn_glyph_row = 16'h51F8;
                    4'd6: cn_glyph_row = 16'h8108;
                    4'd7: cn_glyph_row = 16'h2108;
                    4'd8: cn_glyph_row = 16'h21F8;
                    4'd9: cn_glyph_row = 16'h2100;
                    4'd10: cn_glyph_row = 16'h2100;
                    4'd11: cn_glyph_row = 16'h21FC;
                    4'd12: cn_glyph_row = 16'h2904;
                    4'd13: cn_glyph_row = 16'h3104;
                    4'd14: cn_glyph_row = 16'h21FC;
                    4'd15: cn_glyph_row = 16'h0104;
                    default: cn_glyph_row = 16'h0000;
                endcase
                4'd6: case (row_index)
                    4'd0: cn_glyph_row = 16'h0080;
                    4'd1: cn_glyph_row = 16'h0080;
                    4'd2: cn_glyph_row = 16'hFC80;
                    4'd3: cn_glyph_row = 16'h04FC;
                    4'd4: cn_glyph_row = 16'h0504;
                    4'd5: cn_glyph_row = 16'h4908;
                    4'd6: cn_glyph_row = 16'h2A40;
                    4'd7: cn_glyph_row = 16'h1440;
                    4'd8: cn_glyph_row = 16'h1040;
                    4'd9: cn_glyph_row = 16'h28A0;
                    4'd10: cn_glyph_row = 16'h24A0;
                    4'd11: cn_glyph_row = 16'h4510;
                    4'd12: cn_glyph_row = 16'h8110;
                    4'd13: cn_glyph_row = 16'h0208;
                    4'd14: cn_glyph_row = 16'h0404;
                    4'd15: cn_glyph_row = 16'h0802;
                    default: cn_glyph_row = 16'h0000;
                endcase
                4'd7: case (row_index)
                    4'd0: cn_glyph_row = 16'h0000;
                    4'd1: cn_glyph_row = 16'h2080;
                    4'd2: cn_glyph_row = 16'h133C;
                    4'd3: cn_glyph_row = 16'h1224;
                    4'd4: cn_glyph_row = 16'h0224;
                    4'd5: cn_glyph_row = 16'h0224;
                    4'd6: cn_glyph_row = 16'hF224;
                    4'd7: cn_glyph_row = 16'h1224;
                    4'd8: cn_glyph_row = 16'h1224;
                    4'd9: cn_glyph_row = 16'h12B4;
                    4'd10: cn_glyph_row = 16'h1328;
                    4'd11: cn_glyph_row = 16'h1220;
                    4'd12: cn_glyph_row = 16'h1020;
                    4'd13: cn_glyph_row = 16'h2820;
                    4'd14: cn_glyph_row = 16'h47FE;
                    4'd15: cn_glyph_row = 16'h0000;
                    default: cn_glyph_row = 16'h0000;
                endcase
                4'd8: case (row_index)
                    4'd0: cn_glyph_row = 16'h0900;
                    4'd1: cn_glyph_row = 16'h0900;
                    4'd2: cn_glyph_row = 16'h11FC;
                    4'd3: cn_glyph_row = 16'h3204;
                    4'd4: cn_glyph_row = 16'h5448;
                    4'd5: cn_glyph_row = 16'h9950;
                    4'd6: cn_glyph_row = 16'h1148;
                    4'd7: cn_glyph_row = 16'h1244;
                    4'd8: cn_glyph_row = 16'h1444;
                    4'd9: cn_glyph_row = 16'h1140;
                    4'd10: cn_glyph_row = 16'h1080;
                    4'd11: cn_glyph_row = 16'h0200;
                    4'd12: cn_glyph_row = 16'h5104;
                    4'd13: cn_glyph_row = 16'h5112;
                    4'd14: cn_glyph_row = 16'h9012;
                    4'd15: cn_glyph_row = 16'h0FF0;
                    default: cn_glyph_row = 16'h0000;
                endcase
                4'd9: case (row_index)
                    4'd0: cn_glyph_row = 16'h1040;
                    4'd1: cn_glyph_row = 16'h1040;
                    4'd2: cn_glyph_row = 16'h2040;
                    4'd3: cn_glyph_row = 16'h7E7C;
                    4'd4: cn_glyph_row = 16'h4284;
                    4'd5: cn_glyph_row = 16'h4284;
                    4'd6: cn_glyph_row = 16'h4304;
                    4'd7: cn_glyph_row = 16'h4244;
                    4'd8: cn_glyph_row = 16'h7E24;
                    4'd9: cn_glyph_row = 16'h4224;
                    4'd10: cn_glyph_row = 16'h4204;
                    4'd11: cn_glyph_row = 16'h4204;
                    4'd12: cn_glyph_row = 16'h4204;
                    4'd13: cn_glyph_row = 16'h7E04;
                    4'd14: cn_glyph_row = 16'h4228;
                    4'd15: cn_glyph_row = 16'h0010;
                    default: cn_glyph_row = 16'h0000;
                endcase
                4'd10: case (row_index)
                    4'd0: cn_glyph_row = 16'h0004;
                    4'd1: cn_glyph_row = 16'hFF84;
                    4'd2: cn_glyph_row = 16'h0804;
                    4'd3: cn_glyph_row = 16'h1024;
                    4'd4: cn_glyph_row = 16'h2224;
                    4'd5: cn_glyph_row = 16'h4124;
                    4'd6: cn_glyph_row = 16'hFFA4;
                    4'd7: cn_glyph_row = 16'h08A4;
                    4'd8: cn_glyph_row = 16'h0824;
                    4'd9: cn_glyph_row = 16'h0824;
                    4'd10: cn_glyph_row = 16'h7F24;
                    4'd11: cn_glyph_row = 16'h0824;
                    4'd12: cn_glyph_row = 16'h0804;
                    4'd13: cn_glyph_row = 16'h0F84;
                    4'd14: cn_glyph_row = 16'hF814;
                    4'd15: cn_glyph_row = 16'h4008;
                    default: cn_glyph_row = 16'h0000;
                endcase
                4'd11: case (row_index)
                    4'd0: cn_glyph_row = 16'h0100;
                    4'd1: cn_glyph_row = 16'h0100;
                    4'd2: cn_glyph_row = 16'h0100;
                    4'd3: cn_glyph_row = 16'h7FFC;
                    4'd4: cn_glyph_row = 16'h0100;
                    4'd5: cn_glyph_row = 16'h1110;
                    4'd6: cn_glyph_row = 16'h0910;
                    4'd7: cn_glyph_row = 16'h0920;
                    4'd8: cn_glyph_row = 16'hFFFE;
                    4'd9: cn_glyph_row = 16'h0380;
                    4'd10: cn_glyph_row = 16'h0540;
                    4'd11: cn_glyph_row = 16'h0920;
                    4'd12: cn_glyph_row = 16'h3118;
                    4'd13: cn_glyph_row = 16'hC106;
                    4'd14: cn_glyph_row = 16'h0100;
                    4'd15: cn_glyph_row = 16'h0100;
                    default: cn_glyph_row = 16'h0000;
                endcase
                default: cn_glyph_row = 16'h0000;
            endcase
        end
    endfunction


    reg [7:0] glyph_character;
    reg [2:0] time_glyph_row_index;
    reg [2:0] time_glyph_column;
    reg [4:0] time_glyph_bits;
    reg [2:0] scroll_glyph_row_index;
    reg [2:0] scroll_glyph_column;
    reg [4:0] scroll_glyph_bits;
    reg top_glyph_on;
    reg bottom_glyph_on;
    reg [3:0] time_character_index;
    reg [7:0] time_character;
    wire [9:0] time_text_x = x_pos - 10'd552;
    wire [8:0] time_text_y = y_pos - 9'd12;
    wire [10:0] scroll_sum = {1'b0, x_pos} + {1'b0, scroll_phase};
    wire scroll_text_visible = (scroll_sum >= 11'd632) &&
                               (scroll_sum < 11'd824);
    wire [8:0] scroll_text_x = scroll_sum - 11'd632;
    wire [8:0] scroll_text_y = y_pos - 9'd440;

    always @* begin
        time_character_index = time_text_x[6:3];
        time_character = 8'h20;
        time_glyph_row_index = 3'd0;
        time_glyph_column = 3'd0;
        time_glyph_bits = 5'd0;
        case (time_character_index)
            0: time_character = "R";
            1: time_character = probe_mode ? "E" : "U";
            2: time_character = probe_mode ? "F" : "N";
            3: time_character = 8'h20;
            4: time_character = {4'h3, display_minute_tens};
            5: time_character = {4'h3, display_minute_ones};
            6: time_character = ":";
            7: time_character = {4'h3, display_second_tens};
            8: time_character = {4'h3, display_second_ones};
            default: time_character = 8'h20;
        endcase

        top_glyph_on = 1'b0;
        if (time_text_x < 10'd72 && time_text_y < 9'd7) begin
            time_glyph_row_index = time_text_y[2:0];
            time_glyph_column = time_text_x[2:0];
            time_glyph_bits = glyph_row(time_character, time_glyph_row_index);
            if (time_glyph_column < 3'd5 && time_glyph_row_index < 3'd7)
                top_glyph_on = time_glyph_bits[4 - time_glyph_column];
        end
    end

    reg [3:0] cn_character_index;
    reg [3:0] cn_row_index;
    reg [3:0] cn_column_index;
    reg [15:0] cn_glyph_bits;
    always @* begin
        cn_character_index = scroll_text_x[7:4];
        cn_row_index = scroll_text_y[3:0];
        cn_column_index = scroll_text_x[3:0];
        cn_glyph_bits = cn_glyph_row(cn_character_index, cn_row_index);
        bottom_glyph_on = 1'b0;
        if (scroll_text_visible && scroll_text_x < 9'd192 && scroll_text_y < 9'd16)
            bottom_glyph_on = cn_glyph_bits[4'd15 - cn_column_index];
    end
    wire in_time_box = (x_pos >= 10'd544) && (x_pos < 10'd632) &&
                       (y_pos >= 9'd8) && (y_pos < 9'd24);
    wire in_scroll_box = (x_pos >= 10'd8) && (x_pos < 10'd632) &&
                         (y_pos >= 9'd440) && (y_pos < 9'd456);
    wire in_time_text = (x_pos >= 10'd552) && (x_pos < 10'd624) &&
                        (y_pos >= 9'd12) && (y_pos < 9'd19);
    wire in_scroll_text = (y_pos >= 9'd440) && (y_pos < 9'd456);
    wire [23:0] dim_rgb = {1'b0,rgb_in[23:17],1'b0,rgb_in[15:9],1'b0,rgb_in[7:1]};

    assign rgb_out = (!de) ? rgb_in :
                     (in_time_box ? ((in_time_text && top_glyph_on) ? 24'hffffff : dim_rgb) :
                      (in_scroll_box ? ((in_scroll_text && bottom_glyph_on) ? 24'hffffff : dim_rgb) :
                       rgb_in));
endmodule
