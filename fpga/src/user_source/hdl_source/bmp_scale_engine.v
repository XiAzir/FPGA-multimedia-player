// BMP24 nearest-neighbour scaler. Source sectors and the RGB row buffer are
// synchronous memories; the file mapper is only asked for complete sectors.
module bmp_scale_engine #(
    parameter integer FRAME_WIDTH=640,
    parameter integer FRAME_HEIGHT=480,
    parameter integer MAX_SOURCE_WIDTH=1024,
    parameter integer MAX_SOURCE_HEIGHT=768,
    parameter integer PIXEL_INTERVAL=10,
    parameter integer HEADER_VALIDATED=0
)(
    input wire clk, input wire rst, input wire start,
    input wire [15:0] source_width, input wire [15:0] source_height,
    input wire source_top_down,
    input wire [31:0] pixel_offset, input wire [31:0] file_size,
    input wire pixel_ready,
    output reg card_read, output reg [31:0] card_addr,
    input wire [7:0] card_data, input wire card_valid, input wire card_end,
    input wire file_error,
    output reg pixel_valid, output reg [23:0] pixel_rgb,
    output reg done, output reg error,
    output reg [7:0] failure_code
);
localparam [4:0] S_IDLE=0, S_DIV=1, S_DIV_FIN=2, S_SETUP=3,
 S_Y_BEGIN=4, S_Y_NORM=5, S_ROW_CHECK=6, S_BYTE=7, S_SECTOR=8,
 S_SECTOR_GAP=9, S_MEM_WAIT=10, S_BYTE_GOT=11, S_ROW_DONE=12,
 S_X_BEGIN=13, S_X_MAP=14, S_ROW_READ=15, S_ROW_READ_WAIT=16,
 S_EMIT=17, S_ADV_X=18, S_ADV_Y=19, S_TERMINAL=20, S_X_NORM=21;
localparam integer SOURCE_WIDTH_CAP = MAX_SOURCE_WIDTH < 1024 ? MAX_SOURCE_WIDTH : 1024;
localparam integer SOURCE_HEIGHT_CAP = MAX_SOURCE_HEIGHT < 768 ? MAX_SOURCE_HEIGHT : 768;
localparam integer MAX_NUMERATOR =
    (SOURCE_HEIGHT_CAP*FRAME_WIDTH > SOURCE_WIDTH_CAP*FRAME_HEIGHT) ?
     SOURCE_HEIGHT_CAP*FRAME_WIDTH : SOURCE_WIDTH_CAP*FRAME_HEIGHT;
localparam integer MAX_DENOMINATOR =
    (SOURCE_WIDTH_CAP > SOURCE_HEIGHT_CAP) ? SOURCE_WIDTH_CAP : SOURCE_HEIGHT_CAP;
localparam integer MAX_QUOTIENT = (FRAME_WIDTH > FRAME_HEIGHT) ? FRAME_WIDTH : FRAME_HEIGHT;
localparam integer DIVIDEND_W = $clog2(MAX_NUMERATOR+1);
localparam integer DENOM_W = $clog2(MAX_DENOMINATOR+1);
localparam integer QUOTIENT_W = $clog2(MAX_QUOTIENT+1);
localparam integer X_W = FRAME_WIDTH > 1 ? $clog2(FRAME_WIDTH) : 1;
localparam integer Y_W = FRAME_HEIGHT > 1 ? $clog2(FRAME_HEIGHT) : 1;
localparam integer X_EDGE_W = $clog2(FRAME_WIDTH+1);
localparam integer Y_EDGE_W = $clog2(FRAME_HEIGHT+1);
localparam integer X_PHASE_W = $clog2(FRAME_WIDTH+SOURCE_WIDTH_CAP);
localparam integer Y_PHASE_W = $clog2(FRAME_HEIGHT+SOURCE_HEIGHT_CAP);
localparam integer INTERVAL_W = PIXEL_INTERVAL > 1 ? $clog2(PIXEL_INTERVAL) : 1;
reg [4:0] state;
wire [10:0] src_w;
wire [9:0] src_h;
wire [11:0] stride;
// The validated production caller holds all parsed header fields from start
// through scaler completion. Reuse those stable inputs instead of snapshot FFs.
generate if (HEADER_VALIDATED != 0) begin : g_live_header
    assign src_w = source_width[10:0];
    assign src_h = source_height[9:0];
    assign stride = ((({5'd0,source_width}*16'd3)+16'd3)>>2)<<2;
end else begin : g_latched_header
    reg [10:0] src_w_q;
    reg [9:0] src_h_q;
    reg [11:0] stride_q;
    assign src_w = src_w_q;
    assign src_h = src_h_q;
    assign stride = stride_q;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            src_w_q<=0; src_h_q<=0; stride_q<=0;
        end else if (state==S_IDLE && start) begin
            src_w_q<=source_width[10:0];
            src_h_q<=source_height[9:0];
            stride_q<=((({5'd0,source_width}*16'd3)+16'd3)>>2)<<2;
        end
    end
end endgenerate
reg [X_EDGE_W-1:0] dw, offx;
reg [Y_EDGE_W-1:0] dh, offy;
reg [DIVIDEND_W-1:0] numerator;
reg [DENOM_W-1:0] denominator, remainder;
reg [QUOTIENT_W-1:0] quotient;
reg [5:0] div_bit;
reg div_for_width;
reg [9:0] sector_count;
reg [8:0] sector_raddr;
reg [7:0] sector_q;
reg [22:0] sector_tag;
reg sector_tag_valid;
reg [1:0] gap_count;
reg [7:0] blue_value, green_value;
reg [1:0] component;
reg [9:0] physical_row, src_bottom;
reg [9:0] src_col;
reg [9:0] row_tag;
reg row_tag_valid;
reg [23:0] row_q;
reg [X_W-1:0] out_x;
reg [Y_W-1:0] out_y;
reg [X_PHASE_W-1:0] x_phase;
reg [Y_PHASE_W-1:0] y_phase;
reg [9:0] x_src;
reg [INTERVAL_W-1:0] interval_count;
reg [31:0] row_base;
reg line_black;
wire [21:0] image_bytes = {10'd0,stride} * {12'd0,src_h};
wire [32:0] image_end = {1'b0,pixel_offset} + {11'd0,image_bytes};
wire [21:0] row_offset = {12'd0,physical_row} * {10'd0,stride};
wire [32:0] row_address_wide = {1'b0,pixel_offset} + {11'd0,row_offset};
wire [32:0] col_offset = {21'd0,src_col} + ({21'd0,src_col} << 1) + component;
wire [32:0] byte_address_wide = {1'b0,row_base} + col_offset;
wire div_numerator_bit = numerator[DIVIDEND_W-1];
wire [DENOM_W:0] div_shifted_rem = ({1'b0,remainder} << 1) |
    {{DENOM_W{1'b0}},div_numerator_bit};
wire div_subtract = div_shifted_rem >= {1'b0,denominator};
wire [DENOM_W:0] div_next_rem = div_subtract ?
    div_shifted_rem - {1'b0,denominator} : div_shifted_rem;
wire [QUOTIENT_W-1:0] div_next_quot = (quotient << 1) |
    {{(QUOTIENT_W-1){1'b0}},div_subtract};
wire [X_EDGE_W-1:0] output_right = offx + dw;
wire [Y_EDGE_W-1:0] output_bottom = offy + dh;
(* ram_style = "bram" *) reg [7:0] sector_mem [0:511];
(* ram_style = "bram" *) reg [23:0] row_mem [0:MAX_SOURCE_WIDTH-1];
wire sector_read_enable=(state==S_MEM_WAIT);
wire row_read_enable=(state==S_ROW_READ);

always @(posedge clk) begin
    if (!rst && state==S_SECTOR && card_valid && sector_count<512)
        sector_mem[sector_count[8:0]]<=card_data;
end

always @(posedge clk) begin
    if (!rst && state==S_BYTE_GOT && component==2)
        row_mem[src_col[9:0]]<={sector_q,green_value,blue_value};
end

always @(posedge clk) begin
    if (sector_read_enable) sector_q<=sector_mem[sector_raddr];
    if (row_read_enable) row_q<=row_mem[x_src[9:0]];
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state<=S_IDLE; card_read<=0; card_addr<=0; pixel_valid<=0;
        pixel_rgb<=0; done<=0; error<=0;
        dw<=0; dh<=0; offx<=0; offy<=0; numerator<=0; denominator<=1;
        quotient<=0; remainder<=0; div_bit<=0; div_for_width<=0;
        sector_count<=0; sector_raddr<=0; sector_tag<=0;
        sector_tag_valid<=0; gap_count<=0; 
        blue_value<=0; green_value<=0; component<=0;
        physical_row<=0; src_bottom<=0; src_col<=0; row_tag<=0;
        row_tag_valid<=0; out_x<=0; out_y<=0; x_phase<=0;
        y_phase<=0; x_src<=0; interval_count<=0; row_base<=0;
        line_black<=0; failure_code<=0;
    end else begin
        if (interval_count!=0) interval_count<=interval_count-1'b1;
        if (file_error && state!=S_IDLE && state!=S_TERMINAL) begin
            error<=1; card_read<=0; pixel_valid<=0; state<=S_TERMINAL;
            if(!error) failure_code<=8'h01;
        end else case (state)
        S_IDLE: if (start) begin
            done<=0; error<=0; card_read<=0; card_addr<=0; failure_code<=0;
            sector_tag_valid<=0; row_tag_valid<=0;
            if (!HEADER_VALIDATED && (source_width==0 || source_height==0 ||
                source_width>MAX_SOURCE_WIDTH || source_width>1024 ||
                source_height>MAX_SOURCE_HEIGHT || source_height>768)) begin
                error<=1; state<=S_TERMINAL; failure_code<=8'h02;
            end else state<=S_SETUP;
        end
        S_SETUP: begin
            if (!HEADER_VALIDATED && image_end> {1'b0,file_size}) begin
                error<=1; state<=S_TERMINAL; failure_code<=8'h03;
            end else if ((src_w*FRAME_HEIGHT)>=(src_h*FRAME_WIDTH)) begin
                dw<=FRAME_WIDTH; numerator<=src_h*FRAME_WIDTH;
                denominator<=src_w; quotient<=0; remainder<=0;
                div_bit<=DIVIDEND_W-1; div_for_width<=0; state<=S_DIV;
            end else begin
                dh<=FRAME_HEIGHT; numerator<=src_w*FRAME_HEIGHT;
                denominator<=src_h; quotient<=0; remainder<=0;
                div_bit<=DIVIDEND_W-1; div_for_width<=1; state<=S_DIV;
            end
        end
        S_DIV: begin
            remainder<=div_next_rem[DENOM_W-1:0]; quotient<=div_next_quot;
            numerator<=numerator<<1;
            if (div_bit==0) state<=S_DIV_FIN;
            else div_bit<=div_bit-1'b1;
        end
        S_DIV_FIN: begin
            if (div_for_width) begin
                dw<=quotient==0 ? 1 : quotient;
                offx<=(FRAME_WIDTH-(quotient==0 ? 1 : quotient))>>1;
                offy<=0;
                out_y<=0; out_x<=0; src_bottom<=0;
                y_phase<=src_h-1'b1; state<=S_Y_BEGIN;
            end else begin
                dh<=quotient==0 ? 1 : quotient;
                offx<=0; offy<=(FRAME_HEIGHT-(quotient==0 ? 1 : quotient)+1)>>1;
                out_y<=0; out_x<=0; src_bottom<=0;
                y_phase<=src_h-1'b1; state<=S_Y_BEGIN;
            end
        end
        S_X_BEGIN: begin
            out_x<=0; x_phase<=0; x_src<=0; state<=S_X_MAP;
        end
        S_Y_BEGIN: begin
            if (out_y>=FRAME_HEIGHT) begin done<=1; state<=S_IDLE; end
            else if (out_y<offy || out_y>=output_bottom) begin
                line_black<=1;
                out_x<=0; state<=S_X_BEGIN;
            end else begin
                line_black<=0;
                physical_row<=src_bottom;
                if (source_top_down) physical_row<=src_h-1'b1-src_bottom;
                state<=S_Y_NORM;
            end
        end
        S_Y_NORM: begin
            if (y_phase>=dh) begin
                y_phase<=y_phase-dh; src_bottom<=src_bottom+1'b1;
                physical_row<=source_top_down ? src_h-1'b1-(src_bottom+1'b1) : src_bottom+1'b1;
            end else state<=S_ROW_CHECK;
        end
        S_ROW_CHECK: begin
            if (row_tag_valid && row_tag==physical_row) state<=S_X_BEGIN;
            else begin
                row_base<=row_address_wide[31:0];
                if (!HEADER_VALIDATED && row_address_wide[32]) begin error<=1; state<=S_TERMINAL; failure_code<=8'h04; end
                else begin src_col<=0; component<=0; state<=S_BYTE; end
            end
        end
        S_BYTE: begin
            if (!HEADER_VALIDATED && (byte_address_wide[32] || byte_address_wide[31:0]>=file_size)) begin
                error<=1; state<=S_TERMINAL; failure_code<=8'h05;
            end else if (sector_tag_valid && sector_tag==byte_address_wide[31:9]) begin
                sector_raddr<=byte_address_wide[8:0]; state<=S_MEM_WAIT;
            end else if (!card_read) begin
                card_addr<=byte_address_wide[31:9]; card_read<=1;
                sector_count<=0; state<=S_SECTOR;
            end
        end
        S_SECTOR: begin
            if (card_valid) begin
                if (sector_count<512) begin
                    sector_count<=sector_count+1'b1;
                end else begin error<=1; card_read<=0; state<=S_TERMINAL; failure_code<=8'h06; end
            end
            if (card_end) begin
                card_read<=0;
                if (sector_count==512) begin
                    sector_tag<=card_addr[22:0]; sector_tag_valid<=1;
                    gap_count<=3; state<=S_SECTOR_GAP;
                end else begin error<=1; state<=S_TERMINAL; failure_code<=8'h07; end
            end
        end
        S_SECTOR_GAP: begin
            if (gap_count!=0) gap_count<=gap_count-1'b1;
            else state<=S_BYTE;
        end
        S_MEM_WAIT: state<=S_BYTE_GOT;
        S_BYTE_GOT: begin
            if (component==0) begin blue_value<=sector_q; component<=1; state<=S_BYTE; end
            else if (component==1) begin green_value<=sector_q; component<=2; state<=S_BYTE; end
            else begin
                component<=0;
                if (src_col+1>=src_w) state<=S_ROW_DONE;
                else begin src_col<=src_col+1'b1; state<=S_BYTE; end
            end
        end
        S_ROW_DONE: begin
            row_tag<=physical_row; row_tag_valid<=1;
            out_x<=0; x_phase<=0; x_src<=0; state<=S_X_BEGIN;
        end
        S_X_MAP: begin
            if (out_x>=FRAME_WIDTH) state<=S_ADV_Y;
            else if (line_black || out_x<offx || out_x>=output_right) begin
                pixel_rgb<=0; state<=S_EMIT;
            end else begin
                state<=S_ROW_READ;
            end
        end
        S_ROW_READ: state<=S_ROW_READ_WAIT;
        S_ROW_READ_WAIT: begin pixel_rgb<=row_q; state<=S_EMIT; end
        S_EMIT: begin
            if (!pixel_valid) begin
                if (interval_count==0) pixel_valid<=1;
            end else if (pixel_ready) begin
                pixel_valid<=0; interval_count<=PIXEL_INTERVAL-1;
                state<=S_ADV_X;
            end
        end
        S_ADV_X: begin
            if (out_x+1>=FRAME_WIDTH) state<=S_ADV_Y;
            else begin
                if (out_x+1>=offx && out_x+1<output_right) begin
                    if (out_x+1==offx) begin x_phase<=0; x_src<=0; end
                    else begin x_phase<=x_phase+src_w; state<=S_X_NORM; end
                end
                out_x<=out_x+1'b1;
                if (!(out_x+1>=offx && out_x+1<output_right && out_x+1!=offx))
                    state<=S_X_MAP;
            end
        end
        S_X_NORM: begin
            if (x_phase>=dw) begin x_phase<=x_phase-dw; x_src<=x_src+1'b1; end
            else state<=S_X_MAP;
        end
        S_ADV_Y: begin
            if (out_y+1>=FRAME_HEIGHT) begin done<=1; state<=S_IDLE; end
            else begin
                if (!line_black && out_y+1>=offy && out_y+1<output_bottom)
                    y_phase<=y_phase+src_h;
                out_y<=out_y+1'b1; state<=S_Y_BEGIN;
            end
        end
        S_TERMINAL: begin card_read<=0; end
        default: begin error<=1; card_read<=0; state<=S_TERMINAL; failure_code<=8'h08; end
        endcase
    end
end
endmodule
