// 1024-point, real-input, fixed-point FFT spectrum analyzer.
// One audio sample is accepted for each audio_valid pulse while collecting.
// Samples arriving during window/FFT/scan/output are intentionally discarded.
`include "player_spectrum_bands.vh"
module player_spectrum_analyzer #(
    parameter HANN_FILE = "spectrum_hann.mem",
    parameter TWIDDLE_FILE = "spectrum_twiddle.mem",
    parameter integer FRAME_TIMEOUT_SAMPLES = 4096
) (
    input  wire               clk,
    input  wire               rst,
    input  wire               audio_valid,
    input  wire signed [15:0] audio_pcm,
    input  wire               source_change,
    output reg                band_valid,
    output reg         [4:0]  band_index,
    output reg         [15:0] band_value,
    output reg                frame_done,
    output reg         [1:0]  debug_coeff_nonzero,
    output wire [23:0] debug_progress, debug_events, debug_accepted,
    output wire [7:0] debug_control
);

    localparam [4:0] ST_CAPTURE   = 4'd0,
                     ST_WIN_REQ   = 4'd1,
                     ST_WIN_MUL   = 4'd2,
                     ST_WIN_WRITE = 4'd3,
                     ST_FFT_ISSUE = 4'd4,
                     ST_FFT_M0    = 4'd5,
                     ST_FFT_M1    = 4'd6,
                     ST_FFT_M2    = 4'd7,
                     ST_FFT_M3    = 4'd8,
                     ST_FFT_CALC  = 4'd9,
                     ST_FFT_WRITE = 4'd10,
                     ST_SCAN_REQ  = 4'd11,
                     ST_SCAN_USE  = 4'd12,
                     ST_EMIT      = 4'd13,
                     ST_FFT_WAIT  = 4'd14,
                     ST_FFT_SAVE3 = 4'd15,
                     ST_FFT_WRITE_B = 5'd16;

    (* fsm_encoding = "none" *) reg [4:0] state;
    reg [9:0] sample_count;
    reg [9:0] win_index;
    reg [3:0] fft_stage;
    reg [8:0] butterfly;
    reg [9:0] scan_bin;
    reg [4:0] scan_band;
    reg [15:0] band_max;
    reg [15:0] emit_value;
    reg [4:0] emit_index;

    // FFT-local reset: asynchronous assertion and pixel-clock release.
    // Retain binary encoding and the explicit default recovery (SWUG106 4.2.7).
    (* ASYNC_REG="TRUE" *) reg [1:0] reset_pipe=2'b11;
    always @(posedge clk or posedge rst) begin
        if(rst) reset_pipe<=2'b11;
        else reset_pipe<={reset_pipe[0],1'b0};
    end
    wire fft_reset=reset_pipe[1];
    reg [11:0] frame_age_samples;
    reg timeout_pulse;
    reg [7:0] recovery_count,source_change_count;
    reg [23:0] accepted_samples;
    wire sample_write_en;
    assign debug_progress={state,sample_count,win_index[8:0]};
    assign debug_events={8'd0,recovery_count,source_change_count};
    assign debug_accepted=accepted_samples;
    assign debug_control={fft_reset,source_change,timeout_pulse,sample_write_en,frame_done,band_valid,debug_coeff_nonzero};
    // A normal frame needs ~1024 capture + <200 compute-time audio pulses.
    // 4096 incoming pulses without completion recover only this analyzer.
    always @(posedge clk or posedge fft_reset) begin
        if(fft_reset) begin
            frame_age_samples<=0;timeout_pulse<=0;recovery_count<=0;
            source_change_count<=0;accepted_samples<=0;
        end else begin
            timeout_pulse<=0;
            if(source_change) begin
                frame_age_samples<=0;accepted_samples<=0;
                if(source_change_count!=8'hff) source_change_count<=source_change_count+1'b1;
            end else begin
                if(sample_write_en && accepted_samples!=24'hffffff)
                    accepted_samples<=accepted_samples+1'b1;
                if(frame_done) frame_age_samples<=0;
                else if(audio_valid) begin
                    if(FRAME_TIMEOUT_SAMPLES!=0 && frame_age_samples==FRAME_TIMEOUT_SAMPLES-1) begin
                        frame_age_samples<=0;timeout_pulse<=1;
                        if(recovery_count!=8'hff) recovery_count<=recovery_count+1'b1;
                    end else frame_age_samples<=frame_age_samples+1'b1;
                end
            end
        end
    end

    // Natural-order input staging RAM, inferred as synchronous BRAM.
    (* ram_style = "bram" *) reg signed [15:0] sample_mem [0:1023];
    reg signed [15:0] sample_q;
    wire [15:0] hann_q;
    wire [31:0] twiddle_q;
    reg [8:0] twiddle_addr;

    // Two replicated read banks per component provide both butterfly operands
    // with synchronous, one-cycle BRAM reads. Writes are mirrored exactly.
    (* ram_style = "bram" *) reg signed [15:0] real_mem_a [0:1023];
    (* ram_style = "bram" *) reg signed [15:0] real_mem_b [0:1023];
    (* ram_style = "bram" *) reg signed [15:0] imag_mem_a [0:1023];
    (* ram_style = "bram" *) reg signed [15:0] imag_mem_b [0:1023];
    reg signed [15:0] real_a_q, real_b_q, imag_a_q, imag_b_q;

    // Explicit local BRAM INIT parameters retain FFT coefficients while the
    // successful player baseline keeps global gate eram_init disabled.
    spectrum_coeff_rom #(.HANN_FILE(HANN_FILE), .TWIDDLE_FILE(TWIDDLE_FILE))
    u_coefficients (
        .clk(clk), .hann_en(state == ST_WIN_REQ), .hann_addr(win_index), .hann_q(hann_q),
        .twiddle_en(state == ST_FFT_ISSUE), .twiddle_addr(twiddle_addr), .twiddle_q(twiddle_q)
    );

    // Passive coefficient observations; never drive FFT or playback control.
    always @(posedge clk or posedge fft_reset) begin
        if (fft_reset) debug_coeff_nonzero <= 2'b00;
        else if (source_change) debug_coeff_nonzero <= 2'b00;
        else begin
            if (state == ST_WIN_MUL && hann_q != 0) debug_coeff_nonzero[1] <= 1'b1;
            if (state == ST_FFT_M0 && twiddle_q != 0) debug_coeff_nonzero[0] <= 1'b1;
        end
    end

    function [9:0] bit_reverse10;
        input [9:0] value;
        integer k;
        begin
            for (k = 0; k < 10; k = k + 1)
                bit_reverse10[k] = value[9-k];
        end
    endfunction

    function [9:0] band_edge;
        input [4:0] index;
        begin
            case (index)
                 0: band_edge = 10'd1;
                 1: band_edge = 10'd2;
                 2: band_edge = 10'd3;
                 3: band_edge = 10'd4;
                 4: band_edge = 10'd5;
                 5: band_edge = 10'd6;
                 6: band_edge = 10'd7;
                 7: band_edge = 10'd9;
                 8: band_edge = 10'd11;
                 9: band_edge = 10'd14;
                10: band_edge = 10'd18;
                11: band_edge = 10'd23;
                12: band_edge = 10'd29;
                13: band_edge = 10'd37;
                14: band_edge = 10'd47;
                15: band_edge = 10'd60;
                16: band_edge = 10'd76;
                17: band_edge = 10'd97;
                18: band_edge = 10'd124;
                19: band_edge = 10'd158;
                20: band_edge = 10'd201;
                21: band_edge = 10'd256;
                22: band_edge = 10'd326;
                23: band_edge = 10'd415;
                default: band_edge = 10'd513;
            endcase
        end
    endfunction

    function [15:0] abs16;
        input signed [15:0] value;
        begin
            abs16 = value[15] ? (~value + 16'd1) : value;
        end
    endfunction

    function [15:0] max16;
        input [15:0] a;
        input [15:0] b;
        begin max16 = (a > b) ? a : b; end
    endfunction

    reg [9:0] fft_addr_a, fft_addr_b;
    // The radix-2 DIT butterfly index is split into {group,j}. Insert the
    // stage's pair-selection bit directly instead of synthesizing variable
    // shifts and adders for each address.
    always @* begin
        fft_addr_a = 10'd0;
        fft_addr_b = 10'd1;
        twiddle_addr = 9'd0;
        case (fft_stage)
            4'd0: begin fft_addr_a={butterfly,1'b0};             fft_addr_b={butterfly,1'b1};             twiddle_addr=9'b000000000; end
            4'd1: begin fft_addr_a={butterfly[8:1],1'b0,butterfly[0:0]}; fft_addr_b={butterfly[8:1],1'b1,butterfly[0:0]}; twiddle_addr={butterfly[0:0],8'b0}; end
            4'd2: begin fft_addr_a={butterfly[8:2],1'b0,butterfly[1:0]}; fft_addr_b={butterfly[8:2],1'b1,butterfly[1:0]}; twiddle_addr={butterfly[1:0],7'b0}; end
            4'd3: begin fft_addr_a={butterfly[8:3],1'b0,butterfly[2:0]}; fft_addr_b={butterfly[8:3],1'b1,butterfly[2:0]}; twiddle_addr={butterfly[2:0],6'b0}; end
            4'd4: begin fft_addr_a={butterfly[8:4],1'b0,butterfly[3:0]}; fft_addr_b={butterfly[8:4],1'b1,butterfly[3:0]}; twiddle_addr={butterfly[3:0],5'b0}; end
            4'd5: begin fft_addr_a={butterfly[8:5],1'b0,butterfly[4:0]}; fft_addr_b={butterfly[8:5],1'b1,butterfly[4:0]}; twiddle_addr={butterfly[4:0],4'b0}; end
            4'd6: begin fft_addr_a={butterfly[8:6],1'b0,butterfly[5:0]}; fft_addr_b={butterfly[8:6],1'b1,butterfly[5:0]}; twiddle_addr={butterfly[5:0],3'b0}; end
            4'd7: begin fft_addr_a={butterfly[8:7],1'b0,butterfly[6:0]}; fft_addr_b={butterfly[8:7],1'b1,butterfly[6:0]}; twiddle_addr={butterfly[6:0],2'b0}; end
            4'd8: begin fft_addr_a={butterfly[8:8],1'b0,butterfly[7:0]}; fft_addr_b={butterfly[8:8],1'b1,butterfly[7:0]}; twiddle_addr={butterfly[7:0],1'b0}; end
            4'd9: begin fft_addr_a={1'b0,butterfly};             fft_addr_b={1'b1,butterfly};             twiddle_addr=butterfly; end
            default: begin end
        endcase
    end
    wire signed [15:0] twiddle_im = twiddle_q[15:0];

    // The positive Hann coefficient is extended with a zero sign bit so it is
    // never interpreted as a negative signed multiplier operand.
    reg signed [32:0] mul_product;
    wire signed [18:0] window_shifted = mul_product >>> 15;
    wire signed [15:0] window_value = window_shifted[15:0];

    reg signed [31:0] p0, p1, p2, p3;
    reg signed [16:0] tw_re_q;
    reg signed [15:0] tw_im_q;
    reg signed [32:0] rot_re_wide, rot_im_wide;
    reg signed [16:0] t_re, t_im;
    reg signed [17:0] sum_re, diff_re, sum_im, diff_im;
    reg signed [15:0] fft_out_ar, fft_out_ai, fft_out_br, fft_out_bi;

    reg signed [15:0] mul_a;
    reg signed [16:0] mul_b;

    // A single signed 16x17 registered multiplier is shared by Hann and all
    // four complex-rotation products. This creates exactly one '*' node.
    always @* begin
        mul_a = 16'sd0;
        mul_b = 17'sd0;
        case (state)
            ST_WIN_MUL: begin
                mul_a = sample_q;
                mul_b = $signed({1'b0, hann_q});
            end
            ST_FFT_M0: begin
                mul_a = real_b_q;
                mul_b = $signed({tw_re_q[15], tw_re_q[15:0]});
            end
            ST_FFT_M1: begin
                mul_a = imag_b_q;
                mul_b = $signed({tw_im_q[15], tw_im_q});
            end
            ST_FFT_M2: begin
                mul_a = real_b_q;
                mul_b = $signed({tw_im_q[15], tw_im_q});
            end
            ST_FFT_M3: begin
                mul_a = imag_b_q;
                mul_b = $signed({tw_re_q[15], tw_re_q[15:0]});
            end
            default: begin end
        endcase
    end
    always @(posedge clk) begin
        if (state == ST_WIN_MUL || state == ST_FFT_M0 ||
            state == ST_FFT_M1 || state == ST_FFT_M2 || state == ST_FFT_M3)
            mul_product <= $signed(mul_a) * $signed(mul_b);
    end

    // Synchronous BRAM read ports. Addresses are combinational from the active
    // butterfly counters and are sampled on ST_FFT_ISSUE.
    wire [9:0] real_a_read_addr = (state == ST_SCAN_REQ) ? scan_bin : fft_addr_a;

    // Keep each inferred RAM's write port in one dedicated clocked process.
    // The replicated FFT arrays share one write address and one data mux.
    assign sample_write_en = !fft_reset && !source_change && !timeout_pulse && (state == ST_CAPTURE) && audio_valid;
    wire work_ram_write_en = !fft_reset && !source_change && !timeout_pulse && ((state == ST_WIN_WRITE) ||
                             (state == ST_FFT_WRITE) ||
                             (state == ST_FFT_WRITE_B));
    wire [9:0] work_ram_write_addr = (state == ST_WIN_WRITE) ?
                                     bit_reverse10(win_index) :
                                     (state == ST_FFT_WRITE) ? fft_addr_a : fft_addr_b;
    wire signed [15:0] work_ram_write_real = (state == ST_WIN_WRITE) ?
                                             window_value :
                                             (state == ST_FFT_WRITE) ? fft_out_ar : fft_out_br;
    wire signed [15:0] work_ram_write_imag = (state == ST_WIN_WRITE) ?
                                             16'sd0 :
                                             (state == ST_FFT_WRITE) ? fft_out_ai : fft_out_bi;

    always @(posedge clk) begin
        if (sample_write_en)
            sample_mem[sample_count] <= audio_pcm;
        if (work_ram_write_en) begin
            real_mem_a[work_ram_write_addr] <= work_ram_write_real;
            real_mem_b[work_ram_write_addr] <= work_ram_write_real;
            imag_mem_a[work_ram_write_addr] <= work_ram_write_imag;
            imag_mem_b[work_ram_write_addr] <= work_ram_write_imag;
        end
    end

    always @(posedge clk) begin
        real_a_q <= real_mem_a[real_a_read_addr];
        imag_a_q <= imag_mem_a[real_a_read_addr];
        if (state == ST_FFT_ISSUE) begin
            real_b_q <= real_mem_b[fft_addr_b];
            imag_b_q <= imag_mem_b[fft_addr_b];
        end
        if (state == ST_WIN_REQ) begin
            sample_q <= sample_mem[win_index];
        end
    end

    reg [15:0] bin_proxy;
    reg [15:0] next_band_max;
    reg signed [16:0] tr_calc, ti_calc;
    task reset_control;
        begin
            state <= ST_CAPTURE;
            sample_count <= 10'd0;
            win_index <= 10'd0;
            fft_stage <= 4'd0;
            butterfly <= 9'd0;
            scan_bin <= 10'd1;
            scan_band <= 5'd0;
            band_max <= 16'd0;
            emit_value <= 16'd0;
            emit_index <= 5'd0;
            band_valid <= 1'b0;
            band_index <= 5'd0;
            band_value <= 16'd0;
            frame_done <= 1'b0;
            tw_re_q <= 17'd0;
            tw_im_q <= 16'sd0;
        end
    endtask
    always @(posedge clk or posedge fft_reset) begin
        if (fft_reset) begin
            reset_control();
        end else if (source_change || timeout_pulse) begin
            reset_control();
        end else begin
            band_valid <= 1'b0;
            frame_done <= 1'b0;
            case (state)
                ST_CAPTURE: if (audio_valid) begin
                    if (sample_count == 10'd1023) begin
                        sample_count <= 10'd0;
                        win_index <= 10'd0;
                        state <= ST_WIN_REQ;
                    end else begin
                        sample_count <= sample_count + 10'd1;
                    end
                end

                ST_WIN_REQ: state <= ST_WIN_MUL;
                ST_WIN_MUL: state <= ST_WIN_WRITE;
                ST_WIN_WRITE: begin
                    if (win_index == 10'd1023) begin
                        fft_stage <= 4'd0;
                        butterfly <= 9'd0;
                        state <= ST_FFT_ISSUE;
                    end else begin
                        win_index <= win_index + 10'd1;
                        state <= ST_WIN_REQ;
                    end
                end

                ST_FFT_ISSUE: state <= ST_FFT_WAIT;
                ST_FFT_WAIT: begin
                    tw_re_q <= {twiddle_q[31], twiddle_q[31:16]};
                    tw_im_q <= twiddle_q[15:0];
                    state <= ST_FFT_M0;
                end
                ST_FFT_M0: state <= ST_FFT_M1;
                ST_FFT_M1: begin p0 <= mul_product[31:0]; state <= ST_FFT_M2; end
                ST_FFT_M2: begin p1 <= mul_product[31:0]; state <= ST_FFT_M3; end
                ST_FFT_M3: begin p2 <= mul_product[31:0]; state <= ST_FFT_SAVE3; end
                ST_FFT_SAVE3: begin p3 <= mul_product[31:0]; state <= ST_FFT_CALC; end
                ST_FFT_CALC: begin
                    rot_re_wide = $signed({p0[31], p0}) - $signed({p1[31], p1});
                    rot_im_wide = $signed({p2[31], p2}) + $signed({p3[31], p3});
                    tr_calc = rot_re_wide >>> 15;
                    ti_calc = rot_im_wide >>> 15;
                    sum_re = $signed({real_a_q[15], real_a_q}) + $signed({tr_calc[16], tr_calc});
                    diff_re = $signed({real_a_q[15], real_a_q}) - $signed({tr_calc[16], tr_calc});
                    sum_im = $signed({imag_a_q[15], imag_a_q}) + $signed({ti_calc[16], ti_calc});
                    diff_im = $signed({imag_a_q[15], imag_a_q}) - $signed({ti_calc[16], ti_calc});
                    fft_out_ar <= sum_re >>> 1;
                    fft_out_br <= diff_re >>> 1;
                    fft_out_ai <= sum_im >>> 1;
                    fft_out_bi <= diff_im >>> 1;
                    state <= ST_FFT_WRITE;
                end
                ST_FFT_WRITE: begin
                    state <= ST_FFT_WRITE_B;
                end
                ST_FFT_WRITE_B: begin
                    if (butterfly == 9'd511) begin
                        butterfly <= 9'd0;
                        if (fft_stage == 4'd9) begin
                            scan_bin <= 10'd1;
                            scan_band <= 5'd0;
                            band_max <= 16'd0;
                            state <= ST_SCAN_REQ;
                        end else begin
                            fft_stage <= fft_stage + 4'd1;
                            state <= ST_FFT_ISSUE;
                        end
                    end else begin
                        butterfly <= butterfly + 9'd1;
                        state <= ST_FFT_ISSUE;
                    end
                end

                ST_SCAN_REQ: state <= ST_SCAN_USE;
                ST_SCAN_USE: begin
                    bin_proxy = max16(abs16(real_a_q), abs16(imag_a_q));
                    next_band_max = max16(band_max, bin_proxy);
                    if (scan_bin == (band_edge(scan_band + 5'd1) - 10'd1)) begin
                        emit_index <= scan_band;
                        emit_value <= next_band_max;
                        state <= ST_EMIT;
                    end else begin
                        band_max <= next_band_max;
                        scan_bin <= scan_bin + 10'd1;
                        state <= ST_SCAN_REQ;
                    end
                end
                ST_EMIT: begin
                    band_valid <= 1'b1;
                    band_index <= emit_index;
                    band_value <= emit_value;
                    if (emit_index == 5'd23) begin
                        frame_done <= 1'b1;
                        sample_count <= 10'd0;
                        state <= ST_CAPTURE;
                    end else begin
                        scan_band <= emit_index + 5'd1;
                        scan_bin <= scan_bin + 10'd1;
                        band_max <= 16'd0;
                        state <= ST_SCAN_REQ;
                    end
                end
                default: begin
                    reset_control();
                end
            endcase
        end
    end
endmodule
