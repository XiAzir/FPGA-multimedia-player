// Decode into the inactive buffer; present at PCM sample-number deadlines.
// 48 kHz / 15 fps = 3200 source samples per content frame.
module player_video_schedule (
    input wire clk, rst, enable,
    input wire catalog_ready, video_found, wav_primed,
    input wire file_ready, reader_frame_sent, decoder_idle,
    output reg reader_start, reader_next,
    output wire decoder_reset,
    input wire write_finish_toggle, display_finish_toggle,
    input wire sample_take,
    output reg write_req,
    input wire write_req_ack,
    output reg [1:0] write_buffer, display_buffer,
    output reg display_valid, audio_go,
    output wire [3:0] state_code,
    output reg [8:0] displayed_frame,
    output reg frame_late
);
    localparam [3:0] WAIT_FILE=0, WAIT_READY=1, WRITE_REQ=2, WRITE_GAP=3,
                     DECODE=4, WAIT_DUE=5, WAIT_DISPLAY=6;
    reg [3:0] state;
    reg [3:0] gap;
    reg [2:0] write_sync, display_sync;
    reg memory_done, input_done, frame_due;
    reg [11:0] sample_in_frame;
    wire memory_pulse=write_sync[2]^write_sync[1];
    wire display_pulse=display_sync[2]^display_sync[1];
    assign decoder_reset=rst || (state==WRITE_REQ) || (state==WRITE_GAP && gap>=4);
    assign state_code=state;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=WAIT_FILE;gap<=0;write_sync<=0;display_sync<=0;
            reader_start<=0;reader_next<=0;write_req<=0;
            write_buffer<=0;display_buffer<=0;display_valid<=0;audio_go<=0;
            memory_done<=0;input_done<=0;frame_due<=0;sample_in_frame<=0;
            displayed_frame<=0;frame_late<=0;
        end else begin
            write_sync<={write_sync[1:0],write_finish_toggle};
            display_sync<={display_sync[1:0],display_finish_toggle};
            reader_start<=0;reader_next<=0;
            if(audio_go && sample_take) begin
                if(sample_in_frame==3199) begin
                    sample_in_frame<=0;frame_due<=1;
                    if(state==DECODE) frame_late<=1;
                end else sample_in_frame<=sample_in_frame+1'b1;
            end
            if(memory_pulse) memory_done<=1;
            if(reader_frame_sent) input_done<=1;
            case(state)
                WAIT_FILE: if(enable && catalog_ready && video_found) begin
                    reader_start<=1;state<=WAIT_READY;
                end
                WAIT_READY: if(file_ready) begin
                    write_buffer<=0;write_req<=1;state<=WRITE_REQ;
                end
                WRITE_REQ: if(write_req_ack) begin
                    write_req<=0;memory_done<=0;input_done<=0;
                    gap<=8;state<=WRITE_GAP;
                end
                WRITE_GAP: if(gap!=0) gap<=gap-1'b1;
                           else begin reader_next<=1;state<=DECODE;end
                DECODE: if((memory_done||memory_pulse) &&
                           (input_done||reader_frame_sent) && decoder_idle) state<=WAIT_DUE;
                WAIT_DUE: if((!display_valid && wav_primed)||frame_due) begin
                    display_buffer<=write_buffer;display_valid<=1;
                    frame_due<=0;state<=WAIT_DISPLAY;
                end
                WAIT_DISPLAY: if(display_pulse) begin
                    if(!audio_go) begin audio_go<=1;displayed_frame<=0;end
                    else if(displayed_frame==299) displayed_frame<=0;
                    else displayed_frame<=displayed_frame+1'b1;
                    write_buffer<={1'b0,~display_buffer[0]};
                    write_req<=1;state<=WRITE_REQ;
                end
            endcase
        end
    end
endmodule
