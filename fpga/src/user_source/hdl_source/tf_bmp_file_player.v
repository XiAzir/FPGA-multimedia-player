// Directory-driven, logical-sector BMP loader. The frame buffer owns flipping.
// Scope: bottom-up target RGB888 frame; source may be padded/top-down BMP24.
module tf_bmp_file_player #(
    parameter integer CLK_FREQ_HZ=50000000,
    parameter integer FRAME_WIDTH=640,
    parameter integer FRAME_HEIGHT=480,
    parameter integer WAIT_LIMIT=50000000
)(
    input clk, rst,
    input key_next_req_toggle, key_auto_req_toggle,
    output wire key_next_ack_toggle, key_auto_ack_toggle,
    input catalog_ready, input [2:0] bmp_count,
    input [127:0] bmp_clusters, bmp_sizes,
    output reg [31:0] file_cluster, file_size,
    output wire card_read, output wire [31:0] card_addr,
    input [7:0] card_data, input card_valid, card_end, file_error,
    input write_finish_toggle,
    input display_finish_toggle,
    output reg [1:0] write_buf_idx, disp_buf_idx,
    output reg write_req, input write_req_ack, input write_ready,
    output reg write_en, output reg [23:0] write_data,
    output reg display_valid, output reg error,
    output [3:0] state_code,
    output [1:0] current_image_index,
    output auto_mode,
    output wire [23:0] failure_detail
);
localparam [3:0] WAIT_CATALOG=0, IDLE=1, HEADER=2, CHECK=3,
                  WRITE_WAIT=4, PAYLOAD=5, GAP=6, COMMIT=7, HALT=8,
                  WAIT_DISPLAY=9;
reg [3:0] state;
reg [2:0] gap_count;
reg [31:0] watchdog, auto_count;
reg [9:0] sector_bytes;
reg [1:0] image_index, load_index, pending_buffer;
reg auto_enabled, next_pending, write_done, header_read, scale_start, scale_active;
reg [31:0] header_addr;
reg [2:0] finish_sync, display_finish_sync;
reg [31:0] declared_size, dib_size, pixel_offset;
reg magic_ok, planes_ok, bit_count_ok, compression_ok;
reg [10:0] width_low;
reg width_high_nonzero;
reg [9:0] height_low;
reg height_sign, height_high_one, height_high_zero;
wire next_press, auto_press;
wire finish_pulse=finish_sync[2]^finish_sync[1];
wire display_finish_pulse=display_finish_sync[2]^display_finish_sync[1];
wire [1:0] next_image=({1'b0,image_index}+3'd1 >= bmp_count) ? 2'd0 : image_index+2'd1;
wire auto_tick=(auto_count == CLK_FREQ_HZ-1);
wire [9:0] abs_height=height_sign ? (~height_low+10'd1) : height_low;
wire width_invalid=width_high_nonzero || width_low>11'd1024;
wire height_invalid=height_high_zero && height_sign ? 1'b1 :
    (height_high_one && !height_sign) || (abs_height==0) ||
    (height_sign && height_low==0) || (abs_height>10'd768);
wire [9:0] stride_words = {1'b0,width_low[10:2]} + {width_low[10:2],1'b0} + {8'd0,width_low[1:0]};
wire [11:0] source_stride={stride_words,2'b00};
wire [21:0] source_image_bytes={10'd0,source_stride}*{12'd0,abs_height[9:0]};
wire [32:0] pixel_end={1'b0,pixel_offset}+{11'd0,source_image_bytes};
wire scale_card_read, scale_pixel_valid, scale_done, scale_error;
wire [7:0] scale_failure_code;
wire [31:0] scale_card_addr;
wire [23:0] scale_pixel_rgb;
wire header_ok=magic_ok && (dib_size>=40) &&
    ({1'b0,pixel_offset} >= 33'd14+{1'b0,dib_size}) &&
    planes_ok && bit_count_ok && compression_ok &&
    (width_low!=0 || width_high_nonzero) && !width_invalid && !height_invalid &&
    pixel_end <= {1'b0,file_size} &&
    {1'b0,declared_size}>=pixel_end && (declared_size<=file_size);
// Passive sticky detail: {reason[7:0], failed-header-check mask[15:0]}.
// Bits 0..10 respectively: BM, DIB, offset, planes, bits, compression,
// width, height, file extent, declared extent, declared file size.
reg [23:0] failure_shadow;
wire [15:0] header_failure_mask={5'd0,
    (declared_size>file_size),({1'b0,declared_size}<pixel_end),
    (pixel_end>{1'b0,file_size}),height_invalid,
    ((width_low==0 && !width_high_nonzero) || width_invalid),!compression_ok,!bit_count_ok,
    !planes_ok,({1'b0,pixel_offset}<33'd14+{1'b0,dib_size}),
    (dib_size<40),!magic_ok};
assign failure_detail=error ? failure_shadow : 24'd0;
// CHECK follows the complete 512-byte header sector, so the parsed
// fields and validation wires are stable when failure detail is captured.
always @(posedge clk or posedge rst) begin
    if(rst) failure_shadow<=0;
    else if(!error) begin
        case(state)
            HEADER: if(card_end) failure_shadow<={8'h01,6'd0,sector_bytes};
            CHECK: failure_shadow<={8'h02,header_failure_mask};
            PAYLOAD: if(scale_active && scale_error)
                failure_shadow<={8'h03,8'd0,scale_failure_code};
            WAIT_CATALOG,IDLE,WRITE_WAIT,GAP,COMMIT,HALT,WAIT_DISPLAY: begin end
            default: failure_shadow<={8'h06,12'd0,state};
        endcase
        if((file_error && state!=WAIT_CATALOG) ||
           (state!=WAIT_DISPLAY && watchdog>=WAIT_LIMIT))
            failure_shadow<=file_error ? {8'h04,12'd0,state} : {8'h05,12'd0,state};
    end
end
assign card_read=(state==PAYLOAD) ? scale_card_read : header_read;
assign card_addr=(state==PAYLOAD) ? scale_card_addr : header_addr;
assign state_code=state;
// These observations expose committed state; they never control the loader.
assign current_image_index=image_index;
assign auto_mode=auto_enabled;
key_event_mailbox_sink u_key_event_mailbox (
    .clk(clk),.rst(rst),
    .next_req_toggle(key_next_req_toggle),.next_ack_toggle(key_next_ack_toggle),.next_press(next_press),
    .auto_req_toggle(key_auto_req_toggle),.auto_ack_toggle(key_auto_ack_toggle),.auto_press(auto_press)
);
bmp_scale_engine #(.HEADER_VALIDATED(1),.FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT),
    .MAX_SOURCE_WIDTH(1024),.MAX_SOURCE_HEIGHT(768),.PIXEL_INTERVAL(10)) u_scale(
    .clk(clk),.rst(rst),.start(scale_start),.source_width({5'd0,width_low}),
    .source_height({6'd0,abs_height}),.source_top_down(height_sign),
    .pixel_offset(pixel_offset),.file_size(file_size),.pixel_ready(write_ready),
    .card_read(scale_card_read),.card_addr(scale_card_addr),.card_data(card_data),
    .card_valid(card_valid),.card_end(card_end),.file_error(file_error),
    .pixel_valid(scale_pixel_valid),.pixel_rgb(scale_pixel_rgb),
    .done(scale_done),.error(scale_error),.failure_code(scale_failure_code));

always @(posedge clk or posedge rst) begin
    if(rst) begin
        state<=WAIT_CATALOG; gap_count<=0; watchdog<=0; auto_count<=0;
        sector_bytes<=0;
        image_index<=0; load_index<=0; pending_buffer<=0;
        auto_enabled<=0; next_pending<=0; write_done<=0; finish_sync<=0;
        display_finish_sync<=0;
        magic_ok<=1; planes_ok<=1; bit_count_ok<=1; compression_ok<=1;
        declared_size<=0; dib_size<=0;
        pixel_offset<=0; width_low<=0; width_high_nonzero<=0;
        height_low<=0; height_sign<=0; height_high_one<=0; height_high_zero<=0;
        file_cluster<=0; file_size<=0; header_read<=0; header_addr<=0;
        scale_start<=0; scale_active<=0;
        write_buf_idx<=0; disp_buf_idx<=0; write_req<=0; write_en<=0;
        write_data<=0; display_valid<=0; error<=0;
    end else begin
        finish_sync<={finish_sync[1:0],write_finish_toggle};
        display_finish_sync<={display_finish_sync[1:0],display_finish_toggle};
        scale_start<=0;
        write_en<=0;
        if(next_press && catalog_ready && bmp_count!=0) next_pending<=1;
        if(auto_press && catalog_ready && bmp_count>1) begin
            auto_enabled<=~auto_enabled; auto_count<=0;
        end else if(state==IDLE && display_valid && auto_enabled) begin
            if(auto_tick) auto_count<=0; else auto_count<=auto_count+1'b1;
        end else auto_count<=0;
        if(finish_pulse && state!=IDLE && state!=WAIT_CATALOG && state!=WAIT_DISPLAY) write_done<=1;
        if(state==HEADER || state==WRITE_WAIT || state==COMMIT) begin
            if(card_valid || card_end || (state==WRITE_WAIT && write_req_ack)) watchdog<=0;
            else watchdog<=watchdog+1'b1;
        end else watchdog<=0;
        case(state)
            WAIT_CATALOG: if(catalog_ready) state<=IDLE;
            IDLE: begin
                header_read<=0; write_req<=0;
                if(catalog_ready && bmp_count!=0 && (!display_valid || next_pending ||
                    (auto_enabled && auto_tick && bmp_count>1))) begin
                    load_index<=display_valid ? next_image : 2'd0;
                    file_cluster<=display_valid ? (bmp_clusters >> (next_image*32)) : bmp_clusters[31:0];
                    file_size<=display_valid ? (bmp_sizes >> (next_image*32)) : bmp_sizes[31:0];
                    pending_buffer<=display_valid ? {1'b0,~disp_buf_idx[0]} : 2'd0;
                    write_buf_idx<=display_valid ? {1'b0,~disp_buf_idx[0]} : 2'd0;
                    next_pending<=0; auto_count<=0; write_done<=0;
                    scale_active<=0;
                    magic_ok<=1; planes_ok<=1; bit_count_ok<=1; compression_ok<=1;
                    declared_size<=0;
                    dib_size<=0; pixel_offset<=0; width_low<=0; width_high_nonzero<=0;
                    height_low<=0; height_sign<=0; height_high_one<=0; height_high_zero<=0;
                    header_addr<=0; sector_bytes<=0; state<=HEADER;
                end
            end
            HEADER: begin
                header_read<=1;
                if(card_valid) begin
                    case(sector_bytes)
                        0: magic_ok<=magic_ok && (card_data==8'h42); 1: magic_ok<=magic_ok && (card_data==8'h4d);
                        2: declared_size[7:0]<=card_data; 3: declared_size[15:8]<=card_data;
                        4: declared_size[23:16]<=card_data; 5: declared_size[31:24]<=card_data;
                        10: pixel_offset[7:0]<=card_data; 11: pixel_offset[15:8]<=card_data;
                        12: pixel_offset[23:16]<=card_data; 13: pixel_offset[31:24]<=card_data;
                        14: dib_size[7:0]<=card_data; 15: dib_size[15:8]<=card_data;
                        16: dib_size[23:16]<=card_data; 17: dib_size[31:24]<=card_data;
                        18: width_low[7:0]<=card_data; 19: begin
                            width_low[10:8]<=card_data[2:0];
                            width_high_nonzero<=|card_data[7:3];
                        end
                        20: width_high_nonzero<=width_high_nonzero || (|card_data);
                        21: width_high_nonzero<=width_high_nonzero || (|card_data);
                        22: height_low[7:0]<=card_data; 23: begin
                            height_low[9:8]<=card_data[1:0];
                            height_high_one<=|card_data[7:2];
                            height_high_zero<=~&card_data[7:2];
                        end
                        24: begin
                            height_high_one<=height_high_one || (|card_data);
                            height_high_zero<=height_high_zero || (~&card_data);
                        end
                        25: begin
                            height_sign<=card_data[7];
                            height_high_one<=height_high_one || (|card_data[6:0]);
                            height_high_zero<=height_high_zero || (~&card_data[6:0]);
                        end
                        26: planes_ok<=planes_ok && (card_data==8'd1); 27: planes_ok<=planes_ok && (card_data==8'd0);
                        28: bit_count_ok<=bit_count_ok && (card_data==8'd24); 29: bit_count_ok<=bit_count_ok && (card_data==8'd0);
                        30: compression_ok<=compression_ok && (card_data==8'd0); 31: compression_ok<=compression_ok && (card_data==8'd0);
                        32: compression_ok<=compression_ok && (card_data==8'd0); 33: compression_ok<=compression_ok && (card_data==8'd0);
                    endcase
                    // Keep 513 as an overlength sentinel instead of allowing
                    // the counter to wrap and accidentally accept long sectors.
                    if(sector_bytes<10'd513) sector_bytes<=sector_bytes+1'b1;
                end
                if(card_end) begin
                    header_read<=0;
                    if(sector_bytes!=512) begin error<=1; state<=HALT; end
                    else state<=CHECK;
                end
            end
            CHECK: begin
                if(!header_ok || FRAME_WIDTH<1 || FRAME_HEIGHT<1) begin error<=1; state<=HALT; end
                else begin write_req<=1; state<=WRITE_WAIT; end
            end
            WRITE_WAIT: if(write_req_ack) begin
                write_req<=0; header_addr<=0; sector_bytes<=0;
                gap_count<=3; state<=GAP;
            end
            GAP: begin
                header_read<=0;
                if(gap_count!=0) gap_count<=gap_count-1'b1;
                else begin scale_start<=1; state<=PAYLOAD; end
            end
            PAYLOAD: begin
                if(!scale_active) scale_active<=1;
                else begin
                    if(scale_pixel_valid && write_ready) begin
                        write_en<=1; write_data<=scale_pixel_rgb;
                    end
                    if(scale_error) begin error<=1; state<=HALT; end
                    else if(scale_done) state<=COMMIT;
                end
            end
            COMMIT: if(write_done || finish_pulse) begin
                disp_buf_idx<=pending_buffer; image_index<=load_index;
                display_valid<=1; state<=WAIT_DISPLAY;
            end
            WAIT_DISPLAY: if(display_finish_pulse) state<=IDLE;
            HALT: begin header_read<=0; write_req<=0; end
            default: begin error<=1; state<=HALT; end
        endcase
        if((file_error && state!=WAIT_CATALOG) ||
           (state!=WAIT_DISPLAY && watchdog>=WAIT_LIMIT)) begin
            error<=1; state<=HALT; header_read<=0; write_req<=0; write_en<=0;
        end
    end
end
endmodule

module key_event_mailbox_sink (
    input wire clk,
    input wire rst,
    input wire next_req_toggle,
    output reg next_ack_toggle,
    output reg next_press,
    input wire auto_req_toggle,
    output reg auto_ack_toggle,
    output reg auto_press
);
(* async_reg = "true" *) reg [1:0] next_req_sync;
(* async_reg = "true" *) reg [1:0] auto_req_sync;
always @(posedge clk or posedge rst) begin
    if(rst) begin
        next_req_sync<=2'b00; auto_req_sync<=2'b00;
        next_ack_toggle<=1'b0; auto_ack_toggle<=1'b0;
        next_press<=1'b0; auto_press<=1'b0;
    end else begin
        next_req_sync<={next_req_sync[0],next_req_toggle};
        auto_req_sync<={auto_req_sync[0],auto_req_toggle};
        next_press<=1'b0; auto_press<=1'b0;
        if(next_req_sync[1]!=next_ack_toggle) begin
            next_ack_toggle<=next_req_sync[1];
            next_press<=1'b1;
        end
        if(auto_req_sync[1]!=auto_ack_toggle) begin
            auto_ack_toggle<=auto_req_sync[1];
            auto_press<=1'b1;
        end
    end
end
endmodule
