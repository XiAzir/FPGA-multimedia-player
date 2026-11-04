//-----------------------------------------------------------------
//                      Baseline JPEG Decoder
//                             V0.1
//                       Ultra-Embedded.com
//                        Copyright 2020
//
//                   admin@ultra-embedded.com
//-----------------------------------------------------------------
//                      License: Apache 2.0
// This IP can be freely used in commercial projects, however you may
// want access to unreleased materials such as verification environments,
// or test vectors, as well as changes to the IP for integration purposes.
// If this is the case, contact the above address.
// I am interested to hear how and where this IP is used, so please get
// in touch!
//-----------------------------------------------------------------
// Copyright 2020 Ultra-Embedded.com
// 
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// 
//     http://www.apache.org/licenses/LICENSE-2.0
// 
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//-----------------------------------------------------------------

module jpeg_output
(
    // Inputs
     input           clk_i
    ,input           rst_i
    ,input           img_start_i
    ,input           img_end_i
    ,input  [ 15:0]  img_width_i
    ,input  [ 15:0]  img_height_i
    ,input  [  1:0]  img_mode_i
    ,input           inport_valid_i
    ,input  [ 31:0]  inport_data_i
    ,input  [  5:0]  inport_idx_i
    ,input  [ 31:0]  inport_id_i
    ,input           outport_accept_i

    // Outputs
    ,output          inport_accept_o
    ,output          outport_valid_o
    ,output [ 15:0]  outport_width_o
    ,output [ 15:0]  outport_height_o
    ,output [ 15:0]  outport_pixel_x_o
    ,output [ 15:0]  outport_pixel_y_o
    ,output [  7:0]  outport_pixel_r_o
    ,output [  7:0]  outport_pixel_g_o
    ,output [  7:0]  outport_pixel_b_o
    ,output          idle_o
);



localparam BLOCK_Y          = 2'd0;
localparam BLOCK_CB         = 2'd1;
localparam BLOCK_CR         = 2'd2;
localparam BLOCK_EOF        = 2'd3;

localparam JPEG_MONOCHROME  = 2'd0;
localparam JPEG_YCBCR_444   = 2'd1;
localparam JPEG_YCBCR_420   = 2'd2;
localparam JPEG_UNSUPPORTED = 2'd3;

//-----------------------------------------------------------------
// FIFO: Y
//-----------------------------------------------------------------
wire               y_valid_w;
wire signed [31:0] y_value_w;
wire               y_pop_w;
wire [31:0]        y_level_w;

jpeg_output_y_ram
u_ram_y
(
     .clk_i(clk_i)
    ,.rst_i(rst_i)

    ,.flush_i(img_start_i)
    ,.level_o(y_level_w)

    ,.push_i(inport_valid_i && (inport_id_i[31:30] == BLOCK_Y || inport_id_i[31:30] == BLOCK_EOF))
    ,.wr_idx_i(inport_idx_i)
    ,.data_in_i(inport_data_i)

    ,.valid_o(y_valid_w)
    ,.data_out_o(y_value_w)
    ,.pop_i(y_pop_w)
);

//-----------------------------------------------------------------
// FIFO: Cb
//-----------------------------------------------------------------
wire               cb_valid_w;
wire signed [31:0] cb_value_w;
wire               cb_pop_w;
wire [31:0]        cb_level_w;

jpeg_output_cx_ram
u_ram_cb
(
     .clk_i(clk_i)
    ,.rst_i(rst_i)

    ,.flush_i(img_start_i)
    ,.level_o(cb_level_w)
    ,.mode420_i(img_mode_i == JPEG_YCBCR_420)

    ,.push_i(inport_valid_i && (inport_id_i[31:30] == BLOCK_CB || inport_id_i[31:30] == BLOCK_EOF))
    ,.wr_idx_i(inport_idx_i)
    ,.data_in_i(inport_data_i)

    ,.valid_o(cb_valid_w)
    ,.data_out_o(cb_value_w)
    ,.pop_i(cb_pop_w)
);

//-----------------------------------------------------------------
// FIFO: Cr
//-----------------------------------------------------------------
wire               cr_valid_w;
wire signed [31:0] cr_value_w;
wire               cr_pop_w;
wire [31:0]        cr_level_w;

jpeg_output_cx_ram
u_ram_cr
(
     .clk_i(clk_i)
    ,.rst_i(rst_i)

    ,.flush_i(img_start_i)
    ,.level_o(cr_level_w)
    ,.mode420_i(img_mode_i == JPEG_YCBCR_420)

    ,.push_i(inport_valid_i && (inport_id_i[31:30] == BLOCK_CR || inport_id_i[31:30] == BLOCK_EOF))
    ,.wr_idx_i(inport_idx_i)
    ,.data_in_i(inport_data_i)

    ,.valid_o(cr_valid_w)
    ,.data_out_o(cr_value_w)
    ,.pop_i(cr_pop_w)
);

//-----------------------------------------------------------------
// FIFO: Info
//-----------------------------------------------------------------
wire        id_valid_w;
wire [31:0] id_value_w;
wire        id_pop_w;

jpeg_output_fifo
#(
     .WIDTH(32)
    ,.DEPTH(8)
    ,.ADDR_W(3)
)
u_info
(
     .clk_i(clk_i)
    ,.rst_i(rst_i)
    ,.flush_i(img_start_i)
 
    ,.push_i(inport_valid_i && (inport_id_i[31:30] == BLOCK_Y || inport_id_i[31:30] == BLOCK_EOF) && inport_idx_i == 6'd0)
    ,.data_in_i(inport_id_i)
    ,.accept_o()

    ,.valid_o(id_valid_w)
    ,.data_out_o(id_value_w)
    ,.pop_i(id_pop_w)
);

assign inport_accept_o   = (y_level_w <= 32'd384 && cr_level_w <= 32'd128) | idle_o;

//-----------------------------------------------------------------
// Block counter (0 - 63)
//-----------------------------------------------------------------
reg [5:0] idx_q;

always @ (posedge clk_i )
if (rst_i)
    idx_q <= 6'b0;
else if (img_start_i)
    idx_q <= 6'b0;
else if (color_input_fire_w)
    idx_q <= idx_q + 6'd1;

//-----------------------------------------------------------------
// Subsampling counter (420 chroma subsampling)
//-----------------------------------------------------------------
reg [1:0] subsmpl_q;

always @ (posedge clk_i )
if (rst_i)
    subsmpl_q <= 2'b0;
else if (img_start_i)
    subsmpl_q <= 2'b0;
else if (color_input_fire_w && img_mode_i == JPEG_YCBCR_420 && idx_q == 6'd63)
    subsmpl_q <= subsmpl_q + 2'd1;

//-----------------------------------------------------------------
// YUV -> RGB
//-----------------------------------------------------------------
reg active_q;

reg        color_s1_valid_q;
reg        color_s1_emit_q;
reg        color_s1_mono_q;
reg [31:0] color_s1_y_q;
reg signed [31:0] color_s1_cr_1402_q;
reg signed [31:0] color_s1_cr_0714_q;
reg signed [31:0] color_s1_cb_0344_q;
reg signed [31:0] color_s1_cb_1772_q;
reg [15:0] color_s1_x_q;
reg [15:0] color_s1_ycoord_q;

reg        color_s2_valid_q;
reg [15:0] pixel_x_q;
reg [15:0] pixel_y_q;
reg [7:0]  pixel_r_q;
reg [7:0]  pixel_g_q;
reg [7:0]  pixel_b_q;

wire color_s2_ready_w = !color_s2_valid_q || outport_accept_i;
wire color_s1_ready_w = !color_s1_valid_q || color_s2_ready_w;
wire color_input_fire_w = active_q && color_s1_ready_w;

wire signed [31:0] cr_1_402_product_w = $signed(cr_value_w) * 32'sd5743;
wire signed [31:0] cr_1_402_w = cr_1_402_product_w >>> 12; // cr_value_w * 1.402
(* dsp_style = "no" *) wire signed [31:0] cr_0_714_product_w = ($signed(cr_value_w) <<< 12) - ($signed(cr_value_w) <<< 10) - ($signed(cr_value_w) <<< 7) - ($signed(cr_value_w) <<< 4) - ($signed(cr_value_w) <<< 2) + $signed(cr_value_w);
(* dsp_style = "no" *) wire signed [31:0] cr_0_714_w = cr_0_714_product_w >>> 12; // cr_value_w * 0.71414
(* dsp_style = "no" *) wire signed [31:0] cb_0_344_product_w = ($signed(cb_value_w) <<< 10) + ($signed(cb_value_w) <<< 8) + ($signed(cb_value_w) <<< 7) + ($signed(cb_value_w) <<< 1);
(* dsp_style = "no" *) wire signed [31:0] cb_0_344_w = cb_0_344_product_w >>> 12; // cb_value_w * 0.34414
wire signed [31:0] cb_1_772_product_w = $signed(cb_value_w) * 32'sd7258;
wire signed [31:0] cb_1_772_w = cb_1_772_product_w >>> 12; // cb_value_w * 1.772

wire signed [31:0] color_s2_r_w = color_s1_mono_q ? (32'sd128 + $signed(color_s1_y_q)) : (32'sd128 + $signed(color_s1_y_q) + color_s1_cr_1402_q);
wire signed [31:0] color_s2_g_w = color_s1_mono_q ? (32'sd128 + $signed(color_s1_y_q)) : (32'sd128 + $signed(color_s1_y_q) - color_s1_cb_0344_q - color_s1_cr_0714_q);
wire signed [31:0] color_s2_b_w = color_s1_mono_q ? (32'sd128 + $signed(color_s1_y_q)) : (32'sd128 + $signed(color_s1_y_q) + color_s1_cb_1772_q);

always @ (posedge clk_i )
if (rst_i)
    active_q <= 1'b0;
else if (img_start_i)
    active_q <= 1'b0;
else if (!active_q)
begin
    if (img_mode_i == JPEG_MONOCHROME)
        active_q <= (y_level_w >= 32'd64);
    else if (img_mode_i == JPEG_YCBCR_444)
        active_q <= (y_level_w >= 32'd64) && (cb_level_w >= 32'd64) && (cr_level_w >= 32'd64);
    else if (subsmpl_q != 2'b0) // 420
        active_q <= 1'b1;
    else // 420
        active_q <= (y_level_w >= 32'd256) && (cb_level_w >= 32'd256) && (cr_level_w >= 32'd256);
end
else if (color_input_fire_w && idx_q == 6'd63)
    active_q <= 1'b0;
assign y_pop_w  = color_input_fire_w;
assign cb_pop_w = color_input_fire_w;
assign cr_pop_w = color_input_fire_w;
assign id_pop_w = color_input_fire_w && (idx_q == 6'd63);

wire [31:0] x_start_w = {13'b0, id_value_w[15:0],3'b0};
wire [31:0] y_start_w = {15'b0, id_value_w[29:16],3'b0};

always @ (posedge clk_i)
if (rst_i || img_start_i)
begin
    color_s1_valid_q <= 1'b0;
    color_s1_emit_q <= 1'b0;
    color_s2_valid_q <= 1'b0;
    pixel_x_q <= 16'b0;
    pixel_y_q <= 16'b0;
    pixel_r_q <= 8'b0;
    pixel_g_q <= 8'b0;
    pixel_b_q <= 8'b0;
end
else
begin
    if (color_s2_ready_w)
        color_s2_valid_q <= color_s1_valid_q && color_s1_emit_q;
    if (color_s1_valid_q && color_s2_ready_w)
    begin
        pixel_x_q <= color_s1_x_q;
        pixel_y_q <= color_s1_ycoord_q;
        pixel_r_q <= (|color_s2_r_w[31:8]) ? (color_s2_r_w[31:24] ^ 8'hff) : color_s2_r_w[7:0];
        pixel_g_q <= (|color_s2_g_w[31:8]) ? (color_s2_g_w[31:24] ^ 8'hff) : color_s2_g_w[7:0];
        pixel_b_q <= (|color_s2_b_w[31:8]) ? (color_s2_b_w[31:24] ^ 8'hff) : color_s2_b_w[7:0];
    end
    if (color_s1_ready_w)
    begin
        color_s1_valid_q <= color_input_fire_w;
        if (color_input_fire_w)
        begin
            color_s1_emit_q <= (id_value_w[31:30] != BLOCK_EOF);
            color_s1_mono_q <= (img_mode_i == JPEG_MONOCHROME);
            color_s1_y_q <= y_value_w;
            color_s1_cr_1402_q <= cr_1_402_w;
            color_s1_cr_0714_q <= cr_0_714_w;
            color_s1_cb_0344_q <= cb_0_344_w;
            color_s1_cb_1772_q <= cb_1_772_w;
            /* verilator lint_off WIDTH */
            color_s1_x_q <= x_start_w + (idx_q % 8);
            color_s1_ycoord_q <= y_start_w + (idx_q / 8);
            /* verilator lint_on WIDTH */
        end
    end
end

//-----------------------------------------------------------------
// Outputs
//-----------------------------------------------------------------
assign outport_valid_o   = color_s2_valid_q;
assign outport_pixel_x_o = pixel_x_q;
assign outport_pixel_y_o = pixel_y_q;
assign outport_width_o   = img_width_i;
assign outport_height_o  = img_height_i;
assign outport_pixel_r_o = pixel_r_q;
assign outport_pixel_g_o = pixel_g_q;
assign outport_pixel_b_o = pixel_b_q;

//-----------------------------------------------------------------
// Idle
//-----------------------------------------------------------------
reg idle_q;

always @ (posedge clk_i )
if (rst_i)
    idle_q <= 1'b1;
else if (img_start_i)
    idle_q <= 1'b0;
else if (id_valid_w && id_value_w[31:30] == BLOCK_EOF)
    idle_q <= 1'b1;

assign idle_o = idle_q && !color_s1_valid_q && !color_s2_valid_q;


endmodule
