// Diagnostic source selection and independent observations; no TF writes.
module player_audio_probe #(
    parameter integer PIXEL_HZ = 25000000,
    parameter integer SAMPLE_HZ = 48000,
    parameter integer PLAY_GATE = 0
)(
    input pixel_clk, sd_clk, rst, tone_toggle,
    input primed, sample_available,
    input play_enable,
    input [15:0] sample_data,
    output sample_take, underflow,
    output underflow_event,
    output audio_valid,
    output [23:0] audio_left, audio_right,
    output acr_valid,
    output [19:0] acr_cts, acr_n,
    output [3:0] led,
    output reg tone_mode
);
    wire wav_valid, tone_valid;
    wire [23:0] wav_left, wav_right, tone_left, tone_right;
    reg fifo_nonzero_seen, take_seen;
    reg wav_varied_seen, wav_acr_seen, wav_first_seen;
    reg [23:0] wav_first_sample;
    reg tone_valid_seen, tone_nonzero_seen, tone_acr_seen;
    reg [31:0] blink_count;
    reg blink;
    localparam integer CTS_FLOOR = (PIXEL_HZ * 48) / SAMPLE_HZ;
    localparam integer CTS_CEIL = (PIXEL_HZ * 48 + SAMPLE_HZ - 1) / SAMPLE_HZ;
    wire acr_rate_ok = acr_valid && acr_n == 20'd6144 &&
        acr_cts >= CTS_FLOOR && acr_cts <= CTS_CEIL;

    wav_pcm_bridge #(.PIXEL_HZ(PIXEL_HZ),.SAMPLE_HZ(SAMPLE_HZ),.PLAY_GATE(PLAY_GATE)) u_bridge (
        .pixel_clk(pixel_clk),.sd_clk(sd_clk),.rst(rst),
        .primed(primed),.sample_available(sample_available),.sample_data(sample_data),
        .play_enable(play_enable),
        .sample_take(sample_take),.audio_valid(wav_valid),
        .audio_left(wav_left),.audio_right(wav_right),.underflow(underflow),
        .underflow_event(underflow_event)
    );
    hdmi_audio_tone_pcm_scale #(.CLK_FREQ_HZ(PIXEL_HZ),
        .SAMPLE_RATE_HZ(SAMPLE_HZ),.AMP(24'sd1000000)) u_tone (
        .I_clk(pixel_clk),.I_rst(rst),.O_audio_valid(tone_valid),
        .O_audio_left_data(tone_left),.O_audio_right_data(tone_right)
    );
    assign audio_valid = tone_mode ? tone_valid : wav_valid;
    assign audio_left = tone_mode ? tone_left : wav_left;
    assign audio_right = tone_mode ? tone_right : wav_right;
    audio_arc_calculate #(.ACR_N(6144)) u_acr (
        .I_clk(pixel_clk),.I_rst(rst),.I_audio_valid(audio_valid),
        .O_acr_valid(acr_valid),.O_acr_cts(acr_cts),.O_acr_n(acr_n)
    );

    always @(posedge sd_clk or posedge rst) begin
        if (rst) begin fifo_nonzero_seen<=0; take_seen<=0; end
        else begin
            if (sample_available && sample_data!=0) fifo_nonzero_seen<=1;
            if (sample_take) take_seen<=1;
        end
    end
    always @(posedge pixel_clk or posedge rst) begin
        if (rst) begin
            tone_mode<=0; blink_count<=0; blink<=0;
            wav_varied_seen<=0; wav_acr_seen<=0; wav_first_seen<=0; wav_first_sample<=0;
            tone_valid_seen<=0; tone_nonzero_seen<=0; tone_acr_seen<=0;
        end else begin
            if (tone_toggle) tone_mode<=~tone_mode;
            if (blink_count >= PIXEL_HZ/2-1) begin blink_count<=0; blink<=~blink; end
            else blink_count<=blink_count+1'b1;
            if (!tone_mode) begin
                // A nonzero constant PCM can be inaudible DC. Require a change
                // in the samples actually presented to the HDMI input.
                if (audio_valid) begin
                    if (!wav_first_seen) begin wav_first_seen<=1; wav_first_sample<=audio_left; end
                    else if (audio_left!=wav_first_sample) wav_varied_seen<=1;
                end
                if (acr_rate_ok) wav_acr_seen<=1;
            end else begin
                if (audio_valid) tone_valid_seen<=1;
                if (audio_valid && (audio_left!=0 || audio_right!=0)) tone_nonzero_seen<=1;
                if (acr_rate_ok) tone_acr_seen<=1;
            end
        end
    end
    // Sticky observations prove an event occurred, not continuous playback.
    // WAV: D3 FIFO nonzero, D2 sample consumed, D1 output varied, D0 valid ACR.
    // Tone: D3 blinks for mode; D2 valid, D1 nonzero, D0 valid ACR.
    assign led = tone_mode ? ~{blink,tone_valid_seen,tone_nonzero_seen,tone_acr_seen} :
        ~{fifo_nonzero_seen,take_seen,wav_varied_seen,wav_acr_seen};
endmodule
