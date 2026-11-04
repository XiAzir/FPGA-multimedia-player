// Remap one existing compact RGB888 frame stream at an aligned row boundary.
// No extra memory requests, FIFO clearing, pixel latency or data pipelines.
module player_wipe_address #(
    parameter integer FRAME_WIDTH=640,
    parameter integer FRAME_HEIGHT=480,
    parameter integer ADDR_BITS=21
)(
    input wire clk, rst,
    input wire frame_ack,
    input wire wipe_active_async,
    input wire [8:0] wipe_rows_async,
    input wire [1:0] old_buffer_async, new_buffer_async,
    input wire [ADDR_BITS-1:0] linear_addr,
    output wire [ADDR_BITS-1:0] mapped_addr
);
    localparam integer LINE_WORDS=(FRAME_WIDTH/4)*3;
    localparam [ADDR_BITS-1:0] FRAME_WORDS=LINE_WORDS*FRAME_HEIGHT;
    // Metadata is held by the pixel-side read-frame request until memory ACK.
    // Capture on ACK, rather than on request arrival: a previous burst may
    // still be draining before the backend reaches its ACK state.
    reg active_s0,active_s1;
    reg [8:0] rows_s0,rows_s1;
    reg [1:0] old_s0,old_s1,new_s0,new_s1;
    reg ack_prev,active;
    reg [ADDR_BITS-1:0] cut_words,old_base,new_base;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            active_s0<=0;active_s1<=0;rows_s0<=0;rows_s1<=0;
            old_s0<=0;old_s1<=0;new_s0<=0;new_s1<=0;
            ack_prev<=0;active<=0;cut_words<=0;old_base<=0;new_base<=0;
        end else begin
            active_s0<=wipe_active_async;active_s1<=active_s0;
            rows_s0<=wipe_rows_async;rows_s1<=rows_s0;
            old_s0<=old_buffer_async;old_s1<=old_s0;
            new_s0<=new_buffer_async;new_s1<=new_s0;
            ack_prev<=frame_ack;
            if(frame_ack && !ack_prev) begin
                active<=active_s1;
                cut_words<=rows_s1*LINE_WORDS;
                old_base<=old_s1[0] ? FRAME_WORDS : {ADDR_BITS{1'b0}};
                new_base<=new_s1[0] ? FRAME_WORDS : {ADDR_BITS{1'b0}};
            end
        end
    end
    wire [ADDR_BITS-1:0] offset=linear_addr-old_base;
    assign mapped_addr=(active && offset<cut_words) ? new_base+offset : linear_addr;
endmodule
