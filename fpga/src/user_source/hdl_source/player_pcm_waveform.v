`timescale 1ns/1ps
// Passive spectrum overlay; preserve the historical top-level interface.
module player_pcm_waveform #(
    parameter integer CLK_FREQ_HZ=25000000,
    parameter integer STALE_MS=100,
    parameter integer FFT_TIMEOUT_SAMPLES=4096
) (
    input wire clk, input wire rst, input wire vs, input wire de,
    input wire overlay_enable,
    input wire [23:0] rgb_in, input wire audio_valid,
    input wire [23:0] audio_pcm, input wire tone_mode,
    input wire freeze_toggle, output reg [23:0] rgb_out,
    output reg [23:0] spectrum_debug_frames, output wire [23:0] spectrum_debug_data,
    output wire [23:0] spectrum_debug_progress,spectrum_debug_events,spectrum_debug_accepted,
    output wire [7:0] spectrum_debug_control
);
    localparam integer BANDS=24,MAX_HEIGHT=84;
    localparam [63:0] STALE_CYCLES=(64'd1*CLK_FREQ_HZ*STALE_MS)/1000;
    localparam integer STALE_W=(STALE_CYCLES>1)?$clog2(STALE_CYCLES+1):1;
    reg vs_prev,tone_prev,source_pending;
    wire vs_rise=vs && !vs_prev;
    wire source_change=(tone_mode!=tone_prev);
    wire source_waiting=source_change || source_pending;
    wire band_valid,frame_done;
    wire [4:0] band_index;
    wire [15:0] band_value;
    wire [1:0] debug_coeff_nonzero;
    player_spectrum_analyzer #(.FRAME_TIMEOUT_SAMPLES(FFT_TIMEOUT_SAMPLES)) u_spectrum (
        .clk(clk),.rst(rst),.audio_valid(audio_valid),
        .audio_pcm($signed(audio_pcm[23:8])),.source_change(source_change),
        .band_valid(band_valid),.band_index(band_index),.band_value(band_value),.frame_done(frame_done),.debug_coeff_nonzero(debug_coeff_nonzero),
        .debug_progress(spectrum_debug_progress),.debug_events(spectrum_debug_events),.debug_accepted(spectrum_debug_accepted),.debug_control(spectrum_debug_control)
    );
    // Piecewise-log amplitude: 16-count floor, 10 px/octave, 8 substeps.
    function [6:0] magnitude_height;
        input [15:0] value;
        integer k,exponent;
        reg [7:0] height;
        reg [15:0] fraction;
        begin
            exponent=0;
            for(k=0;k<16;k=k+1) if(value[k]) exponent=k;
            if(value<=16) magnitude_height=0;
            else begin
                fraction=value>>(exponent-3);
                height=(exponent-4)*10+fraction[2:0];
                magnitude_height=(height>MAX_HEIGHT)?MAX_HEIGHT:height[6:0];
            end
        end
    endfunction
    // Ping-pong completed FFT targets. No parallel copies or resettable
    // register arrays; a bank is visible only after all 24 values arrive.
    (* ram_style="bram" *) reg [6:0] target_mem[0:63];
    reg [6:0] target_q;
    reg capture_bank,ready_bank,snapshot_bank,ready_valid,snapshot_valid;
    // One synchronous 64x14 BRAM: two banks of 24 {height, peak} words.
    (* ram_style="bram" *) reg [13:0] wave_mem[0:63];
    reg [13:0] wave_q;
    reg front_bank,front_valid;
    reg front_nonzero,back_nonzero;
    // One synchronous RAM holds {level, peak, hold} for the shared updater.
    // The two visible arrays change together only after every band is ready.
    (* ram_style="bram" *) reg [17:0] state_mem[0:31];
    reg [17:0] state_q;
    localparam [2:0] U_IDLE=0,U_INIT=1,U_READ=2,U_CALC=3,U_COMMIT=4;
    reg [2:0] update_state;
    reg [4:0] update_index;
    reg update_done,snapshot_tone;
    wire update_busy=(update_state!=U_IDLE);
    wire commit_now=!rst && !source_waiting && (update_state==U_COMMIT);
    reg [6:0] next_height,next_peak;
    reg [3:0] next_hold;
    reg [7:0] level_delta,level_step;
    wire [6:0] effective_target=snapshot_valid?target_q:7'd0;
    always @* begin
        next_height=state_q[17:11];next_peak=state_q[10:4];next_hold=state_q[3:0];
        level_delta=0;level_step=0;
        if(effective_target>state_q[17:11]) begin
            level_delta=effective_target-state_q[17:11];
            level_step=(level_delta+1)>>1;next_height=state_q[17:11]+level_step;
        end else if(effective_target<state_q[17:11]) begin
            level_delta=state_q[17:11]-effective_target;
            level_step=(level_delta+7)>>3;next_height=state_q[17:11]-level_step;
        end
        if(next_height>=state_q[10:4]) begin
            next_peak=next_height;next_hold=(next_height==0)?0:10;
        end else if(state_q[3:0]!=0) next_hold=state_q[3:0]-1'b1;
        else next_peak=(state_q[10:4]>next_height+2)?state_q[10:4]-2:next_height;
    end
    wire state_write_en=!rst && !source_waiting && (update_state==U_INIT || update_state==U_CALC);
    wire [17:0] state_write_data=(update_state==U_INIT)?18'd0:{next_height,next_peak,next_hold};
    always @(posedge clk) begin
        state_q<=state_mem[update_index];
        target_q<=target_mem[{snapshot_bank,update_index}];
        if(state_write_en) state_mem[update_index]<=state_write_data;
        if(!rst && !source_waiting && update_state==U_CALC) begin
            wave_mem[{~front_bank,update_index}]<={next_height,next_peak};
        end
        if(!rst && !source_waiting && band_valid && band_index<BANDS)
            target_mem[{capture_bank,band_index}]<=magnitude_height(band_value);
    end
    reg frame_pending,freeze_requested,frozen_front,frame_tone_mode;
    reg [STALE_W-1:0] stale_count;
    reg have_audio,stale;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            vs_prev<=0;tone_prev<=0;source_pending<=0;
            frame_pending<=0;freeze_requested<=0;frozen_front<=0;frame_tone_mode<=0;
            stale_count<=0;have_audio<=0;stale<=0;
            update_state<=U_INIT;update_index<=0;update_done<=0;snapshot_tone<=0;
            capture_bank<=1;ready_bank<=0;snapshot_bank<=0;ready_valid<=0;snapshot_valid<=0;
            front_bank<=0;front_valid<=0;front_nonzero<=0;back_nonzero<=0;
        end else begin
            vs_prev<=vs;tone_prev<=tone_mode;
            update_done<=0;
            if(audio_valid) begin stale_count<=0;have_audio<=1;stale<=0;end
            else if(have_audio && !stale && STALE_CYCLES!=0) begin
                if(stale_count>=STALE_CYCLES-1) stale<=1;
                else stale_count<=stale_count+1'b1;
            end
            if(freeze_toggle && !source_waiting) freeze_requested<=!freeze_requested;
            if(source_change) begin
                source_pending<=1;freeze_requested<=0;frame_pending<=0;
                update_state<=U_IDLE;
                ready_valid<=0;snapshot_valid<=0;
                stale_count<=0;have_audio<=0;stale<=0;
            end
            // Source selection wins over HOLD; visible state changes at VS.
            if(vs_rise && source_waiting) begin
                source_pending<=0;frame_pending<=0;freeze_requested<=0;
                frozen_front<=0;frame_tone_mode<=tone_mode;
                update_state<=U_INIT;update_index<=0;snapshot_tone<=tone_mode;
                capture_bank<=1;ready_bank<=0;snapshot_bank<=0;ready_valid<=0;snapshot_valid<=0;
                front_bank<=0;front_valid<=0;front_nonzero<=0;back_nonzero<=0;
            end else if(!source_waiting) begin
                case(update_state)
                U_INIT: begin
                    if(update_index==23) begin update_index<=0;update_state<=U_IDLE;end
                    else update_index<=update_index+1'b1;
                end
                U_READ: update_state<=U_CALC;
                U_CALC: begin
                    if(update_index==0) back_nonzero<=(next_height!=0);
                    else back_nonzero<=back_nonzero || (next_height!=0);
                    if(update_index==23) update_state<=U_COMMIT;
                    else begin update_index<=update_index+1'b1;update_state<=U_READ;end
                end
                U_COMMIT: begin
                    front_bank<=~front_bank;front_valid<=1'b1;
                    front_nonzero<=back_nonzero;
                    frame_tone_mode<=snapshot_tone;frozen_front<=0;
                    update_done<=1;update_state<=U_IDLE;
                end
                default: begin end
                endcase
                if(vs_rise) begin
                    if(freeze_requested) frozen_front<=1;
                    else if(update_state==U_IDLE) begin
                        frame_pending<=0;snapshot_tone<=tone_mode;update_index<=0;update_state<=U_READ;
                        snapshot_bank<=ready_bank;snapshot_valid<=ready_valid && !stale;
                    end
                end
                if(frame_done) begin
                    ready_bank<=capture_bank;capture_bank<=!capture_bank;ready_valid<=1;
                    frame_pending<=1;
                end
            end
        end
    end
    // Page B: completed FFT frames, reset on source change. Page C:
    // {PCM seen, frame seen, nonzero band seen, Hann nonzero, twiddle nonzero,
    //  front commit seen, nonzero front seen, frozen front, last frame max[15:0]}.
    reg diag_pcm_seen,diag_frame_seen,diag_band_seen,diag_commit_seen,diag_front_seen;
    reg [15:0] diag_work_max,diag_last_max;
    wire diag_front_nonzero=front_valid && front_nonzero;
    wire [15:0] diag_final_max=(band_index==0)?band_value:
                                 ((band_value>diag_work_max)?band_value:diag_work_max);
    assign spectrum_debug_data={diag_pcm_seen,diag_frame_seen,diag_band_seen,
        debug_coeff_nonzero,diag_commit_seen,diag_front_seen,frozen_front,diag_last_max};
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            spectrum_debug_frames<=0;diag_pcm_seen<=0;diag_frame_seen<=0;
            diag_band_seen<=0;diag_commit_seen<=0;diag_front_seen<=0;
            diag_work_max<=0;diag_last_max<=0;
        end else if(source_change) begin
            spectrum_debug_frames<=0;diag_pcm_seen<=0;diag_frame_seen<=0;
            diag_band_seen<=0;diag_commit_seen<=0;diag_front_seen<=0;
            diag_work_max<=0;diag_last_max<=0;
        end else begin
            if(audio_valid) diag_pcm_seen<=1;
            if(update_done) diag_commit_seen<=1;
            if(!source_waiting && |diag_front_nonzero) diag_front_seen<=1;
            if(band_valid) begin
                diag_work_max<=diag_final_max;
                if(band_value!=0) diag_band_seen<=1;
                if(frame_done) diag_last_max<=diag_final_max;
            end
            if(frame_done) begin
                diag_frame_seen<=1;
                if(spectrum_debug_frames!=24'hffffff)
                    spectrum_debug_frames<=spectrum_debug_frames+1'b1;
            end
        end
    end

    reg [9:0] x_pos;
    reg [8:0] y_pos;
    reg de_prev,arm_first_line;
    always @(posedge clk or posedge rst) begin
        if(rst) begin x_pos<=0;y_pos<=0;de_prev<=0;arm_first_line<=1;end
        else begin
            de_prev<=de;
            if(vs!=vs_prev) begin x_pos<=0;y_pos<=0;arm_first_line<=1;end
            else if(de) begin
                x_pos<=x_pos+1'b1;
                if(!de_prev && arm_first_line) begin y_pos<=0;arm_first_line<=0;end
            end else begin
                x_pos<=0;
                if(de_prev && y_pos!=511) y_pos<=y_pos+1'b1;
            end
        end
    end
    // Read the bank and column that will be visible after this edge. This
    // mirrors x_pos priority and selects the incoming front bank on U_COMMIT.
    reg [9:0] render_x_next;
    reg [4:0] render_col_next;
    reg [8:0] render_plot_offset;
    wire render_bank_next=commit_now ? ~front_bank : front_bank;
    always @* begin
        if(rst || vs!=vs_prev || !de) render_x_next=0;
        else render_x_next=x_pos+1'b1;
        render_plot_offset=render_x_next-10'd176;
        if(render_x_next>=176 && render_x_next<464)
            render_col_next=render_plot_offset/9'd12;
        else render_col_next=0;
    end
    always @(posedge clk) wave_q<=wave_mem[{render_bank_next,render_col_next}];
    function [34:0] glyph;
        input [7:0] c;
        begin case(c)
        "S":glyph=35'b01111_10000_10000_01110_00001_00001_11110;
        "P":glyph=35'b11110_10001_10001_11110_10000_10000_10000;
        "E":glyph=35'b11111_10000_10000_11110_10000_10000_11111;
        "C":glyph=35'b01111_10000_10000_10000_10000_10000_01111;
        "T":glyph=35'b11111_00100_00100_00100_00100_00100_00100;
        "R":glyph=35'b11110_10001_10001_11110_10100_10010_10001;
        "U":glyph=35'b10001_10001_10001_10001_10001_10001_01110;
        "M":glyph=35'b10001_11011_10101_10101_10001_10001_10001;
        "W":glyph=35'b10001_10001_10001_10101_10101_10101_01010;
        "A":glyph=35'b01110_10001_10001_11111_10001_10001_10001;
        "V":glyph=35'b10001_10001_10001_10001_10001_01010_00100;
        "O":glyph=35'b01110_10001_10001_10001_10001_10001_01110;
        "N":glyph=35'b10001_11001_10101_10011_10001_10001_10001;
        "H":glyph=35'b10001_10001_10001_11111_10001_10001_10001;
        "L":glyph=35'b10000_10000_10000_10000_10000_10000_11111;
        "D":glyph=35'b11110_10001_10001_10001_10001_10001_11110;
        "I":glyph=35'b01110_00100_00100_00100_00100_00100_01110;
        "G":glyph=35'b01111_10000_10000_10111_10001_10001_01111;
        default:glyph=0;
        endcase end
    endfunction
    function [7:0] title_char;
        input [3:0] n;
        input held,tone;
        begin
            title_char=" ";
            if(held) begin case(n)
            0:title_char="H";1:title_char="O";2:title_char="L";3:title_char="D";
            5:title_char=tone?"T":"W";6:title_char=tone?"O":"A";
            7:title_char=tone?"N":"V";8:title_char=tone?"E":" ";
            endcase end
            else begin case(n)
            0:title_char="S";1:title_char="P";2:title_char="E";3:title_char="C";
            4:title_char="T";5:title_char="R";6:title_char="U";7:title_char="M";
            9:title_char=tone?"T":"W";10:title_char=tone?"O":"A";
            11:title_char=tone?"N":"V";12:title_char=tone?"E":" ";
            endcase end
        end
    endfunction
    function [23:0] bar_color;
        input [3:0] n;
        begin case(n)
        0:bar_color=24'h24525c;1:bar_color=24'h2b626b;2:bar_color=24'h33747c;
        3:bar_color=24'h3c868c;4:bar_color=24'h46979c;5:bar_color=24'h50a8ac;
        6:bar_color=24'h5ab8bb;7:bar_color=24'h63c6c8;8:bar_color=24'h6dd2d4;
        default:bar_color=24'h78dddf;
        endcase end
    endfunction
    reg in_column;
    reg [6:0] height_at_x,peak_at_x;
    wire [7:0] compact_height_sum={1'b0,wave_q[13:7]}+({1'b0,wave_q[13:7]}>>1);
    wire [7:0] compact_peak_sum={1'b0,wave_q[6:0]}+({1'b0,wave_q[6:0]}>>1);
    reg [9:0] text_x,legend_x;
    reg [8:0] text_y;
    reg [3:0] char_index;
    reg [2:0] glyph_x,glyph_y;
    reg [34:0] glyph_bits,legend_glyph;
    reg text_on,legend_on;
    reg [7:0] legend_c;
    wire [8:0] plot_distance=9'd428-y_pos;
    wire [9:0] plot_x=x_pos-10'd176;
    wire [3:0] plot_cell_x=plot_x%10'd12;
    wire [23:0] dim_rgb={1'b0,rgb_in[23:17],1'b0,rgb_in[15:9],1'b0,rgb_in[7:1]};
    always @* begin
        in_column=(x_pos>=176 && x_pos<464 && plot_cell_x>=2 && plot_cell_x<10);
        height_at_x=front_valid?{1'b0,compact_height_sum[7:2]}:7'd0;
        peak_at_x=front_valid?{1'b0,compact_peak_sum[7:2]}:7'd0;
        text_x=x_pos-168;text_y=y_pos-382;
        char_index=text_x[6:3];glyph_x=text_x[2:0];glyph_y=text_y;
        glyph_bits=glyph(title_char(char_index,frozen_front,frame_tone_mode));
        text_on=(text_x<104 && text_y<7 && glyph_x<5 && glyph_y<7)?glyph_bits[(6-glyph_y)*5+4-glyph_x]:1'b0;
        legend_x=(x_pos<320)?x_pos-176:x_pos-432;legend_c=" ";
        if(x_pos<320) begin case(legend_x[9:3]) 0:legend_c="L";1:legend_c="O";2:legend_c="W";endcase end
        else begin case(legend_x[9:3]) 0:legend_c="H";1:legend_c="I";2:legend_c="G";3:legend_c="H";endcase end
        legend_glyph=glyph(legend_c);
        legend_on=(y_pos>=428 && y_pos<435 && legend_x<32 && legend_x[2:0]<5)?legend_glyph[(434-y_pos)*5+4-legend_x[2:0]]:1'b0;
        rgb_out=rgb_in;
        if(overlay_enable && de && x_pos>=160 && x_pos<480 && y_pos>=380 && y_pos<436) begin
            rgb_out=dim_rgb;
            if(x_pos>=176 && x_pos<464 && (y_pos==396 || y_pos==412 || y_pos==427)) rgb_out=24'h293b40;
            if(in_column && height_at_x!=0 && y_pos<428 && y_pos>=428-height_at_x) rgb_out=bar_color({1'b0,plot_distance[4:2]});
            if(in_column && peak_at_x!=0 && y_pos>=428-peak_at_x-1 && y_pos<428-peak_at_x) rgb_out=24'hb7eeee;
            if(text_on) rgb_out=frozen_front?24'h95adb8:24'hddebf2;
            if(legend_on) rgb_out=24'h829cac;
        end
    end
endmodule
