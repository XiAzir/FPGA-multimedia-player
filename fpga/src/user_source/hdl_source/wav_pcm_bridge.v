// One outstanding sample request; its bundled data remains stable through ack.
// The SD side has ~1042 cycles to respond before the next 48 kHz pixel tick.
module wav_pcm_bridge #(
    parameter integer PIXEL_HZ = 25000000,
    parameter integer SAMPLE_HZ = 48000,
    parameter integer PLAY_GATE = 0
)(
    input pixel_clk, sd_clk, rst,
    input primed,
    input play_enable,
    input sample_available, input [15:0] sample_data,
    output reg sample_take,
    output reg audio_valid,
    output reg [23:0] audio_left, audio_right,
    output wire underflow_event,
    output reg underflow
);
reg request_toggle;
reg acknowledge_toggle;
reg [15:0] sample_mailbox;
(* ASYNC_REG = "TRUE" *) reg [1:0] request_sync;
(* ASYNC_REG = "TRUE" *) reg [1:0] acknowledge_sync;
(* ASYNC_REG = "TRUE" *) reg [1:0] primed_sync;
reg sd_request_seen;
reg ack_seen;
reg started, waiting, prefetch_valid;
reg [15:0] prefetch;
reg [31:0] sample_acc;
reg [1:0] play_sync;
wire play_run = !PLAY_GATE || play_sync[1];
always @(posedge pixel_clk or posedge rst) begin
    if(rst) play_sync<=0;
    else play_sync<={play_sync[0],play_enable};
end
wire [31:0] next_acc = sample_acc + SAMPLE_HZ;
wire ack_arrived = waiting && (acknowledge_sync[1] != ack_seen);
assign underflow_event = started && play_run && next_acc >= PIXEL_HZ && !prefetch_valid && !ack_arrived;
always @(posedge sd_clk or posedge rst) begin
    if (rst) begin
        request_sync <= 0; sd_request_seen <= 0;
        sample_mailbox <= 0; acknowledge_toggle <= 0; sample_take <= 0;
    end else begin
        request_sync <= {request_sync[0], request_toggle};
        sample_take <= 0;
        if (request_sync[1] != sd_request_seen) begin
            // No ack until a valid sample exists; pixel side substitutes silence.
            if (sample_available) begin
                sample_mailbox <= sample_data;
                sample_take <= 1;
                sd_request_seen <= request_sync[1];
                acknowledge_toggle <= request_sync[1];
            end
        end
    end
end
always @(posedge pixel_clk or posedge rst) begin
    if (rst) begin
        acknowledge_sync <= 0; primed_sync <= 0; ack_seen <= 0;
        request_toggle <= 0; started <= 0; waiting <= 0;
        prefetch_valid <= 0; prefetch <= 0; sample_acc <= 0;
        audio_valid <= 0; audio_left <= 0; audio_right <= 0; underflow <= 0;
    end else begin
        acknowledge_sync <= {acknowledge_sync[0], acknowledge_toggle};
        primed_sync <= {primed_sync[0], primed};
        audio_valid <= 0;
        if (!started) begin
            sample_acc <= 0;
            if (primed_sync[1] && !waiting && play_run) begin
                request_toggle <= ~request_toggle;
                waiting <= 1;
            end
            if (waiting && acknowledge_sync[1] != ack_seen) begin
                ack_seen <= acknowledge_sync[1];
                prefetch <= sample_mailbox;
                prefetch_valid <= 1;
                waiting <= 0;
                started <= 1;
            end
        end else begin
            if (waiting && acknowledge_sync[1] != ack_seen) begin
                ack_seen <= acknowledge_sync[1];
                prefetch <= sample_mailbox;
                prefetch_valid <= 1;
                waiting <= 0;
            end
            if (play_run && next_acc >= PIXEL_HZ) begin
                sample_acc <= next_acc - PIXEL_HZ;
                audio_valid <= 1;
                audio_left <= prefetch_valid ? {prefetch,8'b0} :
                              ack_arrived ? {sample_mailbox,8'b0} : 24'd0;
                audio_right <= prefetch_valid ? {prefetch,8'b0} :
                               ack_arrived ? {sample_mailbox,8'b0} : 24'd0;
                if (!prefetch_valid && !ack_arrived) underflow <= 1;
                prefetch_valid <= 0;
                if (!waiting || ack_arrived) begin
                    request_toggle <= ~request_toggle;
                    waiting <= 1;
                end
            end else if(play_run) sample_acc <= next_acc;
        end
    end
end
endmodule
