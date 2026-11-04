module player_adjust_control #(
    parameter integer CLK_FREQ_HZ = 25000000,
    parameter integer DEBOUNCE_MS = 20,
    parameter integer HOLD_MS = 1500,
    parameter integer PULSE_MS = 100,
    parameter integer LEGACY_GAP_MS = 100
) (
    input wire clk,
    input wire rst,
    input wire vs,
    input wire key0_n,
    input wire key1_n,
    output reg next_req_toggle,
    input wire next_ack_async,
    output reg auto_req_toggle,
    input wire auto_ack_async,
    output reg tone_press,
    output reg waveform_toggle,
    output reg video_mode_press,
    output wire [15:0] debug_state,
    output reg [1:0] mode,
    output reg [3:0] brightness_index,
    output reg [2:0] contrast_index
);

    localparam [1:0] MODE_PLAY = 2'd0;
    localparam [1:0] MODE_BRIGHTNESS = 2'd1;
    localparam [1:0] MODE_CONTRAST = 2'd2;
    localparam [63:0] DB_CYCLES = ((64'd1 * CLK_FREQ_HZ * DEBOUNCE_MS) / 1000 < 1) ? 1 : ((64'd1 * CLK_FREQ_HZ * DEBOUNCE_MS) / 1000);
    localparam [63:0] HOLD_CYCLES = ((64'd1 * CLK_FREQ_HZ * HOLD_MS) / 1000 < 1) ? 1 : ((64'd1 * CLK_FREQ_HZ * HOLD_MS) / 1000);
    localparam [63:0] PULSE_CYCLES = ((64'd1 * CLK_FREQ_HZ * PULSE_MS) / 1000 < 1) ? 1 : ((64'd1 * CLK_FREQ_HZ * PULSE_MS) / 1000);
    localparam [63:0] GAP_CYCLES = ((64'd1 * CLK_FREQ_HZ * LEGACY_GAP_MS) / 1000 < 1) ? 1 : ((64'd1 * CLK_FREQ_HZ * LEGACY_GAP_MS) / 1000);
    localparam [63:0] EVENT_INTERVAL_CYCLES = PULSE_CYCLES + GAP_CYCLES;
    localparam integer DB_W = (DB_CYCLES <= 1) ? 1 : $clog2(DB_CYCLES + 1);
    localparam integer HOLD_W = (HOLD_CYCLES <= 1) ? 1 : $clog2(HOLD_CYCLES + 1);
    localparam integer EVENT_W = (EVENT_INTERVAL_CYCLES <= 1) ? 1 : $clog2(EVENT_INTERVAL_CYCLES + 1);

    (* async_reg = "true" *) reg [1:0] key0_sync;
    (* async_reg = "true" *) reg [1:0] key1_sync;
    (* async_reg = "true" *) reg [1:0] next_ack_sync;
    (* async_reg = "true" *) reg [1:0] auto_ack_sync;
    reg key0_pressed;
    reg key1_pressed;
    reg key0_pressed_d;
    reg key1_pressed_d;
    reg [DB_W-1:0] key0_db_count;
    reg [DB_W-1:0] key1_db_count;

    reg key0_armed;
    reg key1_armed;
    reg key0_long_done;
    reg key1_long_done;
    reg chord_active;
    reg chord_long_done;
    reg [HOLD_W-1:0] key0_hold_count;
    reg [HOLD_W-1:0] key1_hold_count;
    reg [HOLD_W-1:0] chord_hold_count;
    reg [EVENT_W-1:0] next_event_cooldown;
    reg [EVENT_W-1:0] auto_event_cooldown;
    reg next_pending;
    reg auto_pending;
    reg [3:0] brightness_pending;
    reg [2:0] contrast_pending;
    reg vs_d;

    wire next_req_busy = (next_req_toggle != next_ack_sync[1]);
    wire auto_req_busy = (auto_req_toggle != auto_ack_sync[1]);
    wire [7:0] chord_hold_count_hi8 = chord_hold_count >> (HOLD_W > 8 ? HOLD_W - 8 : 0);
    assign debug_state = {key0_pressed,key1_pressed,chord_active,chord_long_done,
                          chord_hold_count_hi8,mode[1:0],next_req_busy,auto_req_busy};

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            key0_sync <= 2'b00;
            key1_sync <= 2'b00;
            key0_pressed <= 1'b0;
            key1_pressed <= 1'b0;
            key0_db_count <= {DB_W{1'b0}};
            key1_db_count <= {DB_W{1'b0}};
        end else begin
            key0_sync <= {key0_sync[0], ~key0_n};
            key1_sync <= {key1_sync[0], ~key1_n};

            if (key0_sync[1] == key0_pressed) begin
                key0_db_count <= {DB_W{1'b0}};
            end else if (key0_db_count >= DB_CYCLES - 1) begin
                key0_pressed <= key0_sync[1];
                key0_db_count <= {DB_W{1'b0}};
            end else begin
                key0_db_count <= key0_db_count + 1'b1;
            end

            if (key1_sync[1] == key1_pressed) begin
                key1_db_count <= {DB_W{1'b0}};
            end else if (key1_db_count >= DB_CYCLES - 1) begin
                key1_pressed <= key1_sync[1];
                key1_db_count <= {DB_W{1'b0}};
            end else begin
                key1_db_count <= key1_db_count + 1'b1;
            end
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            brightness_index <= 4'd4;
            contrast_index <= 3'd2;
            vs_d <= 1'b0;
        end else begin
            vs_d <= vs;
            if (vs && !vs_d) begin
                brightness_index <= brightness_pending;
                contrast_index <= contrast_pending;
            end
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            next_req_toggle <= 1'b0;
            auto_req_toggle <= 1'b0;
            next_ack_sync <= 2'b00;
            auto_ack_sync <= 2'b00;
            tone_press <= 1'b0;
            waveform_toggle <= 1'b0;
            video_mode_press <= 1'b0;
            mode <= MODE_PLAY;
            key0_armed <= 1'b1;
            key1_armed <= 1'b1;
            key0_long_done <= 1'b0;
            key1_long_done <= 1'b0;
            chord_active <= 1'b0;
            chord_long_done <= 1'b0;
            key0_hold_count <= {HOLD_W{1'b0}};
            key1_hold_count <= {HOLD_W{1'b0}};
            chord_hold_count <= {HOLD_W{1'b0}};
            next_event_cooldown <= {EVENT_W{1'b0}};
            auto_event_cooldown <= {EVENT_W{1'b0}};
            next_pending <= 1'b0;
            auto_pending <= 1'b0;
            brightness_pending <= 4'd4;
            contrast_pending <= 3'd2;
            key0_pressed_d <= 1'b0;
            key1_pressed_d <= 1'b0;
        end else begin
            next_ack_sync <= {next_ack_sync[0], next_ack_async};
            auto_ack_sync <= {auto_ack_sync[0], auto_ack_async};
            key0_pressed_d <= key0_pressed;
            key1_pressed_d <= key1_pressed;
            tone_press <= 1'b0;
            waveform_toggle <= 1'b0;
            video_mode_press <= 1'b0;

            if (next_event_cooldown != 0)
                next_event_cooldown <= next_event_cooldown - 1'b1;
            if (auto_event_cooldown != 0)
                auto_event_cooldown <= auto_event_cooldown - 1'b1;

            // One request is held until the destination acknowledges it.
            // A separate one-bit pending flag preserves legacy coalescing.
            if (next_pending && next_event_cooldown == 0 && !next_req_busy) begin
                next_req_toggle <= ~next_req_toggle;
                next_event_cooldown <= EVENT_INTERVAL_CYCLES;
                next_pending <= 1'b0;
            end
            if (auto_pending && auto_event_cooldown == 0 && !auto_req_busy) begin
                auto_req_toggle <= ~auto_req_toggle;
                auto_event_cooldown <= EVENT_INTERVAL_CYCLES;
                auto_pending <= 1'b0;
            end

            if (chord_active) begin
                key0_hold_count <= {HOLD_W{1'b0}};
                key1_hold_count <= {HOLD_W{1'b0}};
                if (key0_pressed && key1_pressed) begin
                    if (!chord_long_done) begin
                        if (chord_hold_count >= HOLD_CYCLES - 1) begin
                            mode <= MODE_PLAY;
                            brightness_pending <= 4'd4;
                            contrast_pending <= 3'd2;
                            chord_long_done <= 1'b1;
                        end else begin
                            chord_hold_count <= chord_hold_count + 1'b1;
                        end
                    end
                end else begin
                    chord_hold_count <= {HOLD_W{1'b0}};
                end
                if (!key0_pressed && !key1_pressed) begin
                    if (!chord_long_done && mode == MODE_PLAY) waveform_toggle <= 1'b1;
                    if (chord_long_done) video_mode_press <= 1'b1;
                    chord_active <= 1'b0;
                    chord_long_done <= 1'b0;
                    key0_armed <= 1'b1;
                    key1_armed <= 1'b1;
                    key0_long_done <= 1'b0;
                    key1_long_done <= 1'b0;
                    chord_hold_count <= {HOLD_W{1'b0}};
                end
            end else if (key0_pressed && key1_pressed) begin
                chord_active <= 1'b1;
                key0_armed <= 1'b0;
                key1_armed <= 1'b0;
                key0_long_done <= 1'b1;
                key1_long_done <= 1'b1;
                chord_long_done <= 1'b0;
                chord_hold_count <= {HOLD_W{1'b0}};
                key0_hold_count <= {HOLD_W{1'b0}};
                key1_hold_count <= {HOLD_W{1'b0}};
            end else begin
                if (key0_pressed && !key0_pressed_d) begin
                    key0_armed <= 1'b1;
                    key0_long_done <= 1'b0;
                    key0_hold_count <= {HOLD_W{1'b0}};
                end
                if (key1_pressed && !key1_pressed_d) begin
                    key1_armed <= 1'b1;
                    key1_long_done <= 1'b0;
                    key1_hold_count <= {HOLD_W{1'b0}};
                end

                if (key0_pressed) begin
                    if (!key0_long_done) begin
                        if (key0_hold_count >= HOLD_CYCLES - 1) begin
                            case (mode)
                                MODE_PLAY: mode <= MODE_BRIGHTNESS;
                                MODE_BRIGHTNESS: mode <= MODE_CONTRAST;
                                default: mode <= MODE_PLAY;
                            endcase
                            key0_long_done <= 1'b1;
                        end else begin
                            key0_hold_count <= key0_hold_count + 1'b1;
                        end
                    end
                end else begin
                    key0_hold_count <= {HOLD_W{1'b0}};
                end

                if (key1_pressed) begin
                    if (!key1_long_done) begin
                        if (key1_hold_count >= HOLD_CYCLES - 1) begin
                            if (mode == MODE_PLAY) tone_press <= 1'b1;
                            key1_long_done <= 1'b1;
                        end else begin
                            key1_hold_count <= key1_hold_count + 1'b1;
                        end
                    end
                end else begin
                    key1_hold_count <= {HOLD_W{1'b0}};
                end

                if (key0_pressed_d && !key0_pressed && !chord_active && key0_armed && !key0_long_done) begin
                    case (mode)
                        MODE_PLAY: begin
                            if (next_event_cooldown == 0 && !next_pending && !next_req_busy) begin
                                next_req_toggle <= ~next_req_toggle;
                                next_event_cooldown <= EVENT_INTERVAL_CYCLES;
                            end else next_pending <= 1'b1;
                        end
                        MODE_BRIGHTNESS: if (brightness_pending != 0) brightness_pending <= brightness_pending - 1'b1;
                        MODE_CONTRAST: if (contrast_pending != 0) contrast_pending <= contrast_pending - 1'b1;
                        default: begin end
                    endcase
                end

                if (key1_pressed_d && !key1_pressed && !chord_active && key1_armed && !key1_long_done) begin
                    case (mode)
                        MODE_PLAY: begin
                            if (auto_event_cooldown == 0 && !auto_pending && !auto_req_busy) begin
                                auto_req_toggle <= ~auto_req_toggle;
                                auto_event_cooldown <= EVENT_INTERVAL_CYCLES;
                            end else auto_pending <= 1'b1;
                        end
                        MODE_BRIGHTNESS: if (brightness_pending < 8) brightness_pending <= brightness_pending + 1'b1;
                        MODE_CONTRAST: if (contrast_pending < 4) contrast_pending <= contrast_pending + 1'b1;
                        default: begin end
                    endcase
                end
            end
        end
    end

endmodule
