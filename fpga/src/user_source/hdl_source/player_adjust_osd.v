// Parameter overlay. No pixel latency; coordinates use the same DE/VS convention as the base OSD.
module player_adjust_osd(input clk,rst,vs,de,input [23:0] rgb_in,
 input [1:0] mode,input [3:0] brightness_index,input [2:0] contrast_index,
 output [23:0] rgb_out);
 reg [9:0] x_pos; reg [8:0] y_pos; reg de_prev,vs_prev,arm_first_line;
 reg [1:0] frame_mode;
 reg [3:0] frame_brightness;
 reg [2:0] frame_contrast;
 reg [7:0] popup_frames;
 always @(posedge clk or posedge rst) begin
  if(rst) begin x_pos<=0;y_pos<=0;de_prev<=0;vs_prev<=0;arm_first_line<=1;frame_mode<=0;
   frame_brightness<=4;frame_contrast<=2;popup_frames<=0; end
  else begin
   de_prev<=de;vs_prev<=vs;
   if(vs != vs_prev) begin x_pos<=0;y_pos<=0;arm_first_line<=1; end
   else if(de) begin x_pos<=x_pos+1'b1;if(!de_prev && arm_first_line) begin y_pos<=0;arm_first_line<=0;end end
   else begin x_pos<=0;if(de_prev && y_pos!=511) y_pos<=y_pos+1'b1;end
   if(vs && !vs_prev) begin
    frame_mode<=mode;
    frame_brightness<=brightness_index;frame_contrast<=contrast_index;
    if(mode==0) popup_frames<=0;
    else if(mode!=frame_mode || brightness_index!=frame_brightness || contrast_index!=frame_contrast)
     popup_frames<=180;
    else if(popup_frames!=0) popup_frames<=popup_frames-1'b1;
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
                "B": case (row)
                    0:glyph_row=5'b11110;
                    1:glyph_row=5'b10001;
                    2:glyph_row=5'b10001;
                    3:glyph_row=5'b11110;
                    4:glyph_row=5'b10001;
                    5:glyph_row=5'b10001;
                    6:glyph_row=5'b11110;
                    default:glyph_row=5'b00000;
                endcase
                "C": case (row)
                    0:glyph_row=5'b01110;
                    1:glyph_row=5'b10001;
                    2:glyph_row=5'b10000;
                    3:glyph_row=5'b10000;
                    4:glyph_row=5'b10000;
                    5:glyph_row=5'b10001;
                    6:glyph_row=5'b01110;
                    default:glyph_row=5'b00000;
                endcase
                "O": case (row)
                    0:glyph_row=5'b01110;
                    1:glyph_row=5'b10001;
                    2:glyph_row=5'b10001;
                    3:glyph_row=5'b10001;
                    4:glyph_row=5'b10001;
                    5:glyph_row=5'b10001;
                    6:glyph_row=5'b01110;
                    default:glyph_row=5'b00000;
                endcase
                "+": case (row)
                    0:glyph_row=5'b00000;
                    1:glyph_row=5'b00100;
                    2:glyph_row=5'b00100;
                    3:glyph_row=5'b11111;
                    4:glyph_row=5'b00100;
                    5:glyph_row=5'b00100;
                    6:glyph_row=5'b00000;
                    default:glyph_row=5'b00000;
                endcase
                "-": case (row)
                    0:glyph_row=5'b00000;
                    1:glyph_row=5'b00000;
                    2:glyph_row=5'b00000;
                    3:glyph_row=5'b11111;
                    4:glyph_row=5'b00000;
                    5:glyph_row=5'b00000;
                    6:glyph_row=5'b00000;
                    default:glyph_row=5'b00000;
                endcase
                ".": case (row)
                    0:glyph_row=5'b00000;
                    1:glyph_row=5'b00000;
                    2:glyph_row=5'b00000;
                    3:glyph_row=5'b00000;
                    4:glyph_row=5'b00000;
                    5:glyph_row=5'b00100;
                    6:glyph_row=5'b00100;
                    default:glyph_row=5'b00000;
                endcase
                default: glyph_row = 5'b00000;
            endcase
        end
    endfunction
 wire [9:0] tx=x_pos-10'd244; wire [8:0] ty=y_pos-9'd12;
 reg [7:0] ch; reg [3:0] bt,bo; reg [7:0] sign_char,ci,ct,co;
 reg [4:0] bits_row; reg glyph_on;
 always @* begin
  bt=0;bo=0;sign_char="+";
  case(brightness_index)
   0:begin bt=6;bo=4;sign_char="-";end
   1:begin bt=4;bo=8;sign_char="-";end
   2:begin bt=3;bo=2;sign_char="-";end
   3:begin bt=1;bo=6;sign_char="-";end
   5:begin bt=1;bo=6;end
   6:begin bt=3;bo=2;end
   7:begin bt=4;bo=8;end
   8:begin bt=6;bo=4;end
   default:begin bt=0;bo=0;end
  endcase
  ci="1";ct="0";co="0";
  case(contrast_index)
   0:begin ci="0";ct="5";end
   1:begin ci="0";ct="7";co="5";end
   3:begin ct="2";co="5";end
   4:begin ct="5";end
   default:begin ci="1";ct="0";co="0";end
  endcase
  ch=" ";
  case(tx[6:3])
   0:ch=frame_mode==1 ? "B" : frame_mode==2 ? "C" : "P";
   1:ch=frame_mode==1 ? "R" : frame_mode==2 ? "O" : "L";
   2:ch=frame_mode==1 ? "I" : frame_mode==2 ? "N" : "A";
   3:ch=frame_mode==0 ? "Y" : " ";
   5:ch="B";6:ch=sign_char;7:ch={4'h3,bt};8:ch={4'h3,bo};
   10:ch="C";11:ch=ci;12:ch=".";13:ch=ct;14:ch=co;
   default:ch=" ";
  endcase
  bits_row=glyph_row(ch,ty[2:0]);glyph_on=0;
  if(tx<120 && ty<7 && tx[2:0]<5 && ty[2:0]<7) glyph_on=bits_row[4-tx[2:0]];
 end
 wire box=(frame_mode!=0 && popup_frames!=0 && x_pos>=240 && x_pos<368 && y_pos>=8 && y_pos<24);
 wire selected=(frame_mode!=0 && tx<32);
 wire [23:0] dim_rgb={1'b0,rgb_in[23:17],1'b0,rgb_in[15:9],1'b0,rgb_in[7:1]};
 assign rgb_out=(!de || !box)?rgb_in : glyph_on ? (selected ? 24'hffff00 : 24'hffffff) : dim_rgb;
endmodule
