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

module jpeg_idct_ram
(
    // Inputs
     input           clk_i
    ,input           rst_i
    ,input           img_start_i
    ,input           img_end_i
    ,input           inport_valid_i
    ,input  [ 15:0]  inport_data_i
    ,input  [  5:0]  inport_idx_i
    ,input           inport_eob_i
    ,input           outport_ready_i

    // Outputs
    ,output          inport_accept_o
    ,output          outport_valid_o
    ,output [ 15:0]  outport_data0_o
    ,output [ 15:0]  outport_data1_o
    ,output [ 15:0]  outport_data2_o
    ,output [ 15:0]  outport_data3_o
    ,output [  2:0]  outport_idx_o
);



reg [1:0]   block_wr_q;
reg [1:0]   block_rd_q;
reg [3:0]   block_ready_q;
reg [5:0]   rd_idx_q;
reg [3:0]   rd_addr_q;
reg         clear_active_q;
reg [3:0]   clear_addr_q;
reg [1:0]   clear_block_q;
reg         slot_prepared_q;

wire clear_start_w = !slot_prepared_q && !clear_active_q &&
                      !block_ready_q[block_wr_q];
wire input_write_w = inport_valid_i && inport_accept_o;
wire [5:0] ram_wr_ptr_w = clear_active_q ? {clear_block_q, clear_addr_q} :
                           {block_wr_q, inport_idx_i[5:3], inport_idx_i[0]};

wire [15:0] outport_data0_w;
wire [15:0] outport_data1_w;
wire [15:0] outport_data2_w;
wire [15:0] outport_data3_w;

wire wr0_w = input_write_w && (inport_idx_i[2:0] == 3'd0 || inport_idx_i[2:0] == 3'd1);
wire wr1_w = input_write_w && (inport_idx_i[2:0] == 3'd2 || inport_idx_i[2:0] == 3'd3);
wire wr2_w = input_write_w && (inport_idx_i[2:0] == 3'd4 || inport_idx_i[2:0] == 3'd5);
wire wr3_w = input_write_w && (inport_idx_i[2:0] == 3'd6 || inport_idx_i[2:0] == 3'd7);

jpeg_idct_ram_dp
u_ram0
(
     .clk0_i(clk_i)
    ,.rst0_i(rst_i)
    ,.clk1_i(clk_i)
    ,.rst1_i(rst_i)

    ,.addr0_i(ram_wr_ptr_w)
    ,.data0_i(clear_active_q ? 16'b0 : inport_data_i)
    ,.wr0_i(clear_active_q || wr0_w)
    ,.data0_o()

    ,.addr1_i({block_rd_q, rd_addr_q})
    ,.data1_i(16'b0)
    ,.wr1_i(1'b0)
    ,.data1_o(outport_data0_w)
);

jpeg_idct_ram_dp
u_ram1
(
     .clk0_i(clk_i)
    ,.rst0_i(rst_i)
    ,.clk1_i(clk_i)
    ,.rst1_i(rst_i)

    ,.addr0_i(ram_wr_ptr_w)
    ,.data0_i(clear_active_q ? 16'b0 : inport_data_i)
    ,.wr0_i(clear_active_q || wr1_w)
    ,.data0_o()

    ,.addr1_i({block_rd_q, rd_addr_q})
    ,.data1_i(16'b0)
    ,.wr1_i(1'b0)
    ,.data1_o(outport_data1_w)
);

jpeg_idct_ram_dp
u_ram2
(
     .clk0_i(clk_i)
    ,.rst0_i(rst_i)
    ,.clk1_i(clk_i)
    ,.rst1_i(rst_i)

    ,.addr0_i(ram_wr_ptr_w)
    ,.data0_i(clear_active_q ? 16'b0 : inport_data_i)
    ,.wr0_i(clear_active_q || wr2_w)
    ,.data0_o()

    ,.addr1_i({block_rd_q, rd_addr_q})
    ,.data1_i(16'b0)
    ,.wr1_i(1'b0)
    ,.data1_o(outport_data2_w)
);

jpeg_idct_ram_dp
u_ram3
(
     .clk0_i(clk_i)
    ,.rst0_i(rst_i)
    ,.clk1_i(clk_i)
    ,.rst1_i(rst_i)

    ,.addr0_i(ram_wr_ptr_w)
    ,.data0_i(clear_active_q ? 16'b0 : inport_data_i)
    ,.wr0_i(clear_active_q || wr3_w)
    ,.data0_o()

    ,.addr1_i({block_rd_q, rd_addr_q})
    ,.data1_i(16'b0)
    ,.wr1_i(1'b0)
    ,.data1_o(outport_data3_w)
);

//-----------------------------------------------------------------
// Clear one 16-word slot in all four RAM banks before accepting its block.
//-----------------------------------------------------------------
always @ (posedge clk_i)
if (rst_i || img_start_i)
begin
    clear_active_q  <= 1'b0;
    clear_addr_q    <= 4'd0;
    clear_block_q   <= 2'd0;
    slot_prepared_q <= 1'b0;
end
else
begin
    if (clear_start_w)
    begin
        clear_active_q <= 1'b1;
        clear_addr_q   <= 4'd0;
        clear_block_q  <= block_wr_q;
    end
    else if (clear_active_q)
    begin
        if (clear_addr_q == 4'd15)
        begin
            clear_active_q  <= 1'b0;
            slot_prepared_q <= 1'b1;
        end
        else
            clear_addr_q <= clear_addr_q + 4'd1;
    end

    if (inport_eob_i && inport_accept_o)
        slot_prepared_q <= 1'b0;
end


//-----------------------------------------------------------------
// Input Buffer
//-----------------------------------------------------------------
always @ (posedge clk_i )
if (rst_i)
begin
    block_ready_q     <= 4'b0;
    block_wr_q        <= 2'b0;
    block_rd_q        <= 2'b0;
end
else if (img_start_i)
begin
    block_ready_q     <= 4'b0;
    block_wr_q        <= 2'b0;
    block_rd_q        <= 2'b0;
end
else
begin
    if (inport_eob_i && inport_accept_o)
    begin
        block_ready_q[block_wr_q] <= 1'b1;
        block_wr_q                <= block_wr_q + 2'd1;
    end

    if (outport_valid_o && rd_idx_q[5:0] == 6'd63)
    begin
        block_ready_q[block_rd_q] <= 1'b0;
        block_rd_q                <= block_rd_q + 2'd1;
    end
end

assign inport_accept_o = ~block_ready_q[block_wr_q] && slot_prepared_q && !clear_active_q;

//-----------------------------------------------------------------
// FSM
//-----------------------------------------------------------------
localparam STATE_W           = 2;
localparam STATE_IDLE        = 2'd0;
localparam STATE_SETUP       = 2'd1;
localparam STATE_ACTIVE      = 2'd2;

reg [STATE_W-1:0] state_q;
reg [STATE_W-1:0] next_state_r;

always @ *
begin
    next_state_r = state_q;

    case (state_q)
    STATE_IDLE:
    begin
        if (block_ready_q[block_rd_q] && outport_ready_i)
            next_state_r = STATE_SETUP;
    end
    STATE_SETUP:
    begin
        next_state_r = STATE_ACTIVE;
    end
    STATE_ACTIVE:
    begin
        if (outport_valid_o && rd_idx_q == 6'd63)
            next_state_r = STATE_IDLE;
    end
    default: ;
    endcase

    if (img_start_i)
        next_state_r = STATE_IDLE;
end

always @ (posedge clk_i )
if (rst_i)
    state_q <= STATE_IDLE;
else
    state_q <= next_state_r;

always @ (posedge clk_i )
if (rst_i)
    rd_idx_q <= 6'b0;
else if (img_start_i)
    rd_idx_q <= 6'b0;
else if (state_q == STATE_ACTIVE)
    rd_idx_q <= rd_idx_q + 6'd1;

always @ (posedge clk_i )
if (rst_i)
    rd_addr_q <= 4'b0;
else if (state_q == STATE_IDLE)
    rd_addr_q <= 4'b0;
else if (state_q == STATE_SETUP)
    rd_addr_q <= 4'd1;
else if (state_q == STATE_ACTIVE)
begin
    case (rd_idx_q[2:0])
    3'd0: rd_addr_q <= rd_addr_q - 1;
    3'd1: rd_addr_q <= rd_addr_q + 1;
    3'd2: ;
    3'd3: rd_addr_q <= rd_addr_q - 1;
    3'd4: rd_addr_q <= rd_addr_q + 1;
    3'd5: rd_addr_q <= rd_addr_q - 1;
    3'd6: rd_addr_q <= rd_addr_q + 2;
    3'd7: rd_addr_q <= rd_addr_q + 1;
    endcase
end

assign outport_valid_o = (state_q == STATE_ACTIVE);
assign outport_idx_o   = rd_idx_q[2:0];
assign outport_data0_o = outport_data0_w;
assign outport_data1_o = outport_data1_w;
assign outport_data2_o = outport_data2_w;
assign outport_data3_o = outport_data3_w;


endmodule
