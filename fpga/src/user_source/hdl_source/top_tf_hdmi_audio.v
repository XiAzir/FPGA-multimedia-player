
module top(
    input                       clk,
    input                       rst_n,
    input                       key1,           // 手动下一张
    input                       key2,           // 自动播放 开/关

    output [3:0]                led,
    output seg7_dio, seg7_sclk, seg7_rclk,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso
);

localparam DISPLAY_WIDTH = 640;
localparam DISPLAY_HEIGHT = 480;


wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;
wire hdmi_5x_clk_raw;
EG_LOGIC_BUFG u_hdmi_serial_bufg (.i(hdmi_5x_clk_raw),.o(hdmi_5x_clk));
// Explicit declaration before passive diagnostic synchronizers use rst_all.
wire rst_all;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data_raw;
wire [23:0] vout_data;
wire [23:0] vout_data_base;
wire        debug_tone_press, debug_tone_mode;
wire        display_valid;

wire [3:0]  state_code;

wire        video_read_req;
wire        video_read_req_ack;
wire        video_read_req_osd;
wire        video_read_en;
wire [23:0] video_read_data;

wire        sd_card_write_en;
wire [23:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
wire        frame_write_finish;
wire display_finish_toggle, wipe_active;
wire [8:0] wipe_rows;
wire [1:0] wipe_new_buffer;
reg         frame_write_toggle_mem;

wire [1:0]  write_buf_idx;
wire [1:0]  disp_buf_idx;
wire [1:0]  current_image_index, osd_buffer_idx, osd_image_index;
wire [2:0]  osd_image_count;
wire        bmp_auto_mode, osd_auto_mode, osd_frame_valid;
wire        probe_mode, probe_tone_toggle;
wire bmp_key_next_req,bmp_key_auto_req,bmp_key_next_ack,bmp_key_auto_ack;

wire hs_0;
wire vs_0;
wire de_0;

wire bmp_card_read, bmp_card_valid, bmp_card_end;
wire [31:0] bmp_card_addr;
wire [7:0] bmp_card_data;
wire wav_card_read, wav_card_valid, wav_card_end;
wire [31:0] wav_card_addr;
wire [7:0] wav_card_data;
wire shared_card_read, shared_card_valid, shared_card_end, card_init_done;
wire [31:0] shared_card_addr;
wire [7:0] shared_card_data;
wire wav_sample_take, wav_sample_available, wav_primed, wav_error;
wire [15:0] wav_sample_data;
wire audio_underflow;
wire fs_ready, fs_error, fs_wav_found, bmp_error;
wire fs_video_found;
wire [31:0] fs_video_cluster, fs_video_size;
wire [7:0] fs_error_code, bmp_map_error_code, wav_map_error_code;
wire [31:0] fs_fat_lba, fs_data_lba, fs_cluster_count;
wire [3:0] fs_cluster_shift;
wire [2:0] fs_bmp_count;
wire [127:0] fs_bmp_clusters, fs_bmp_sizes;
wire [31:0] fs_wav_cluster, fs_wav_size, bmp_file_cluster, bmp_file_size;
wire fs_read, bmp_map_error, wav_map_error;
wire [31:0] fs_addr;
wire arb_card_read, arb_card_valid, arb_card_end;
wire [31:0] arb_card_addr;
// Stereo PCM and HDMI audio clock regeneration, all in the pixel clock domain.
wire        audio_valid;
wire [23:0] audio_left_data;
wire [23:0] audio_right_data;
wire        acr_valid;
wire [19:0] acr_cts;
wire [19:0] acr_n;
// HDMI 1.4b 相关
wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;
wire        hdmi_video_locked;
wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

// 统一复位：TF 图像链路 + HDMI 链路
wire sys_pll_lock;
wire video_pll_lock;

reg [19:0] rst_cnt = 20'd0;
reg rst_all_reg = 1'b1;

// Startup timing shares the existing global 50 MHz system clock.
always @(posedge sd_card_clk) begin
    if (!rst_n) begin
        rst_cnt <= 20'd0;
        rst_all_reg <= 1'b1;
    end else if (!rst_all_reg) begin
        // 一旦复位释放，忽略后续微小的 PLL 抖动，防止系统在使用时随机复位
        rst_all_reg <= 1'b0;
    end else if (sys_pll_lock && video_pll_lock) begin
        // 等待 PLL 连续稳定 20ms @ 50MHz
        if (rst_cnt < 20'd1_000_000) begin
            rst_cnt <= rst_cnt + 1'b1;
            rst_all_reg <= 1'b1;
        end else begin
            rst_all_reg <= 1'b0;
        end
    end else begin
        rst_cnt <= 20'd0;
        rst_all_reg <= 1'b1;
    end
end

// The control classifier survives a media restart so held gestures rearm once.
wire video_mode_press;
reg video_mode;
reg media_reset_active;
reg [4:0] media_reset_count;
reg [1:0] video_mode_sd_sync;
reg [1:0] video_restart_sync;
reg video_restart_seen;
reg video_restart_toggle;
wire video_next_press, video_auto_press;
wire video_key_next_ack, video_key_auto_ack;
wire photo_key_next_ack, photo_key_auto_ack;
wire video_mode_sd=video_mode_sd_sync[1];
always @(posedge video_clk or posedge rst_all_reg) begin
    if(rst_all_reg) begin
        video_mode<=0;media_reset_active<=0;media_reset_count<=0;
        video_restart_sync<=0;video_restart_seen<=0;
    end else begin
        video_restart_sync<={video_restart_sync[0],video_restart_toggle};
        if(video_mode_press || video_restart_sync[1]!=video_restart_seen) begin
            if(video_mode_press) video_mode<=~video_mode;
            video_restart_seen<=video_restart_sync[1];
            media_reset_active<=1;media_reset_count<=31;
        end else if(media_reset_active) begin
            if(media_reset_count==0) media_reset_active<=0;
            else media_reset_count<=media_reset_count-1'b1;
        end
    end
end
always @(posedge sd_card_clk or posedge rst_all_reg) begin
    if(rst_all_reg) begin video_mode_sd_sync<=0;video_restart_toggle<=0;end
    else begin
        video_mode_sd_sync<={video_mode_sd_sync[0],video_mode};
        if(video_mode_sd && video_next_press) video_restart_toggle<=~video_restart_toggle;
    end
end
assign rst_all = rst_all_reg | media_reset_active;
key_event_mailbox_sink u_video_keys (
    .clk(sd_card_clk),.rst(rst_all_reg),
    .next_req_toggle(bmp_key_next_req),.next_ack_toggle(video_key_next_ack),.next_press(video_next_press),
    .auto_req_toggle(bmp_key_auto_req),.auto_ack_toggle(video_key_auto_ack),.auto_press(video_auto_press)
);
assign bmp_key_next_ack=video_mode ? video_key_next_ack : photo_key_next_ack;
assign bmp_key_auto_ack=video_mode ? video_key_auto_ack : photo_key_auto_ack;

// 保持你原来的 TF / SDRAM / video 时钟
sys_pll sys_pll_m0(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (sys_pll_lock),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (video_pll_lock),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk_raw)
);

// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
always @(posedge ext_mem_clk or posedge rst_all) begin
    if (rst_all)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

// Mount owns the card at startup. Runtime clients request logical file sectors.
fat32_catalog u_catalog (
    .clk(sd_card_clk),.rst(rst_all),.sd_init_done(card_init_done),
    .audio_video_mode(video_mode_sd),
    .sd_read(fs_read),.sd_addr(fs_addr),.sd_data(shared_card_data),
    .sd_valid(!fs_ready && shared_card_valid),.sd_end(!fs_ready && shared_card_end),
    .ready(fs_ready),.error(fs_error),.error_code(fs_error_code),
    .fat_lba(fs_fat_lba),.data_lba(fs_data_lba),.cluster_count(fs_cluster_count),
    .sectors_per_cluster_shift(fs_cluster_shift),.bmp_count(fs_bmp_count),
    .bmp_clusters(fs_bmp_clusters),.bmp_sizes(fs_bmp_sizes),
    .wav_found(fs_wav_found),.wav_cluster(fs_wav_cluster),.wav_size(fs_wav_size),
    .video_found(fs_video_found),.video_cluster(fs_video_cluster),.video_size(fs_video_size)
);
wire photo_write_req, photo_write_en, photo_display_valid, photo_error;
wire [23:0] photo_write_data;
wire [1:0] photo_write_buffer,photo_display_buffer;
wire [3:0] photo_state;
wire [31:0] photo_file_cluster,photo_file_size;
wire photo_card_read;
wire [31:0] photo_card_addr;
wire video_card_read;
wire [31:0] video_card_addr;
wire [1:0] video_write_buffer,video_display_buffer;
wire video_write_req,video_display_valid,video_audio_go;
wire [3:0] video_state;
wire video_reader_start,video_reader_next,video_file_ready,video_frame_sent;
wire video_reader_error,video_core_idle,video_core_reset;
wire video_jpeg_valid,video_jpeg_accept,video_jpeg_last;
wire [31:0] video_jpeg_data;
wire [3:0] video_jpeg_strb;
wire video_pixel_valid;
wire [15:0] video_pixel_x,video_pixel_y;
wire [7:0] video_pixel_r,video_pixel_g,video_pixel_b;
reg video_paused;
always @(posedge sd_card_clk or posedge rst_all) begin
    if(rst_all) video_paused<=0;
    else if(video_mode_sd && video_auto_press) video_paused<=~video_paused;
end
assign bmp_file_cluster=video_mode_sd ? fs_video_cluster : photo_file_cluster;
assign bmp_file_size=video_mode_sd ? fs_video_size : photo_file_size;
assign bmp_card_read=video_mode_sd ? video_card_read : photo_card_read;
assign bmp_card_addr=video_mode_sd ? video_card_addr : photo_card_addr;
assign write_buf_idx=video_mode_sd ? video_write_buffer : photo_write_buffer;
assign disp_buf_idx=video_mode_sd ? video_display_buffer : photo_display_buffer;
assign sd_card_write_req=video_mode_sd ? video_write_req : photo_write_req;
assign sd_card_write_en=video_mode_sd ? (video_pixel_valid && bmp_write_ready) : photo_write_en;
assign sd_card_write_data=video_mode_sd ? {video_pixel_r,video_pixel_g,video_pixel_b} : photo_write_data;
assign display_valid=video_mode_sd ? video_display_valid : photo_display_valid;
assign bmp_error=video_mode_sd ? video_reader_error : photo_error;
assign state_code=video_mode_sd ? video_state : photo_state;
player_video_schedule u_video_schedule (
    .clk(sd_card_clk),.rst(rst_all),.enable(video_mode_sd),
    .catalog_ready(fs_ready),.video_found(fs_video_found),.wav_primed(wav_primed),
    .file_ready(video_file_ready),.reader_frame_sent(video_frame_sent),.decoder_idle(video_core_idle),
    .reader_start(video_reader_start),.reader_next(video_reader_next),.decoder_reset(video_core_reset),
    .write_finish_toggle(frame_write_toggle_mem),.display_finish_toggle(display_finish_toggle),
    .sample_take(wav_sample_take),.write_req(video_write_req),.write_req_ack(sd_card_write_req_ack),
    .write_buffer(video_write_buffer),.display_buffer(video_display_buffer),
    .display_valid(video_display_valid),.audio_go(video_audio_go),.state_code(video_state),
    .displayed_frame(),.frame_late()
);
mjp_file_reader u_video_reader (
    .clk(sd_card_clk),.rst(rst_all),.start(video_reader_start),.next_frame(video_reader_next),
    .card_read(video_card_read),.card_addr(video_card_addr),.card_data(bmp_card_data),
    .card_valid(bmp_card_valid && video_mode_sd),.card_end(bmp_card_end && video_mode_sd),
    .file_error(bmp_map_error && video_mode_sd),.file_ready(video_file_ready),.last_index(),
    .frame_ready(),.frame_index(),.frame_length(),
    .jpeg_valid(video_jpeg_valid),.jpeg_data(video_jpeg_data),.jpeg_strb(video_jpeg_strb),
    .jpeg_last(video_jpeg_last),.jpeg_accept(video_jpeg_accept),.frame_sent(video_frame_sent),
    .sequence_index(),.busy(),.error(video_reader_error)
);
jpeg_core #(.SUPPORT_WRITABLE_DHT(0), .FIXED_MODE(2),
    .FIXED_WIDTH(16'd640), .FIXED_HEIGHT(16'd480)) u_jpeg_core (
    .clk_i(sd_card_clk),.rst_i(video_core_reset || !video_mode_sd),
    .inport_valid_i(video_jpeg_valid),.inport_data_i(video_jpeg_data),
    .inport_strb_i(video_jpeg_strb),.inport_last_i(video_jpeg_last),
    .outport_accept_i(bmp_write_ready),.inport_accept_o(video_jpeg_accept),
    .outport_valid_o(video_pixel_valid),.outport_width_o(),.outport_height_o(),
    .outport_pixel_x_o(video_pixel_x),.outport_pixel_y_o(video_pixel_y),
    .outport_pixel_r_o(video_pixel_r),.outport_pixel_g_o(video_pixel_g),
    .outport_pixel_b_o(video_pixel_b),.idle_o(video_core_idle)
);

tf_bmp_file_player #(.CLK_FREQ_HZ(50000000),
    .FRAME_WIDTH(DISPLAY_WIDTH),.FRAME_HEIGHT(DISPLAY_HEIGHT)) u_bmp_file_player (
    .clk(sd_card_clk),.rst(rst_all || video_mode_sd),
    .key_next_req_toggle(bmp_key_next_req),.key_auto_req_toggle(bmp_key_auto_req),
    .key_next_ack_toggle(photo_key_next_ack),.key_auto_ack_toggle(photo_key_auto_ack),
    .catalog_ready(fs_ready),.bmp_count(fs_bmp_count),
    .bmp_clusters(fs_bmp_clusters),.bmp_sizes(fs_bmp_sizes),
    .file_cluster(photo_file_cluster),.file_size(photo_file_size),
    .card_read(photo_card_read),.card_addr(photo_card_addr),
    .card_data(bmp_card_data),.card_valid(bmp_card_valid),.card_end(bmp_card_end),
    .file_error(bmp_map_error),.write_finish_toggle(frame_write_toggle_mem),
    .display_finish_toggle(display_finish_toggle),
    .write_buf_idx(photo_write_buffer),.disp_buf_idx(photo_display_buffer),
    .write_req(photo_write_req),.write_req_ack(sd_card_write_req_ack),
    .write_ready(bmp_write_ready),
    .write_en(photo_write_en),.write_data(photo_write_data),
    .display_valid(photo_display_valid),.error(photo_error),.state_code(photo_state),
    .current_image_index(current_image_index),.auto_mode(bmp_auto_mode),
    .failure_detail()
);
// One FAT execution engine; both clients retain independent file contexts.
fat32_dual_file_sector #(.REQUEST_STABLE(1),.WAV_STATIC_FILE(1)) u_file_mapper (
    .clk(sd_card_clk),.rst(rst_all),
    .fat_lba(fs_fat_lba),.data_lba(fs_data_lba),.cluster_count(fs_cluster_count),
    .sectors_per_cluster_shift(fs_cluster_shift),
    .bmp_enable(fs_ready && !fs_error),.bmp_start_cluster(bmp_file_cluster),
    .bmp_file_size(bmp_file_size),.bmp_file_read(bmp_card_read),.bmp_file_sector(bmp_card_addr),
    .bmp_file_data(bmp_card_data),.bmp_file_valid(bmp_card_valid),.bmp_file_end(bmp_card_end),
    .bmp_error(bmp_map_error),.bmp_error_code(bmp_map_error_code),
    .wav_enable(fs_ready && fs_wav_found && !fs_error),.wav_start_cluster(fs_wav_cluster),
    .wav_file_size(fs_wav_size),.wav_file_read(wav_card_read),.wav_file_sector(wav_card_addr),
    .wav_file_data(wav_card_data),.wav_file_valid(wav_card_valid),.wav_file_end(wav_card_end),
    .wav_error(wav_map_error),.wav_error_code(wav_map_error_code),
    .sd_read(arb_card_read),.sd_addr(arb_card_addr),
    .sd_data(shared_card_data),.sd_valid(arb_card_valid),.sd_end(arb_card_end)
);

// AC201 has four active-low LEDs and a serial segment-display interface.
// Show the reader state while loading; all four LEDs light after a frame commit.
// Active-low LEDs show the live playback state in the final candidate.

// ===================== 原图像时序与帧缓存 =====================
video_timing_data video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0)
);

video_delay video_delay_m0(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .read_en           (video_read_en),
    .read_data         (video_read_data),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .hs_r              (hs),
    .vs_r              (vs),
    .de_r              (de),
    .vout_data         (vout_data_raw)
);

// Select a frame and its OSD label atomically before issuing the memory read.
// A commit during active video is presented on the next read-frame boundary.
player_osd_state u_osd_state (
    .sd_clk(sd_card_clk),.pixel_clk(video_clk),.rst(rst_all),
    .source_buffer(disp_buf_idx),.source_image(current_image_index),
    .source_count(fs_bmp_count),.source_auto(bmp_auto_mode),
    .source_valid(display_valid),.source_video(video_mode),.read_req(video_read_req),.read_req_ack(video_read_req_ack),
    .wipe_active(wipe_active),.wipe_rows(wipe_rows),.wipe_new_buffer(wipe_new_buffer),
    .display_finish_toggle(display_finish_toggle),
    .read_req_out(video_read_req_osd),.frame_buffer(osd_buffer_idx),
    .frame_image(osd_image_index),.frame_count(osd_image_count),
    .frame_auto(osd_auto_mode),.frame_valid(osd_frame_valid)
);

// Product controls arbitrate short/long/chord gestures before legacy BMP debounce.
wire [1:0] adjust_mode;
wire [3:0] brightness_index;
wire [2:0] contrast_index;
wire waveform_toggle;
wire [15:0] control_debug_state;
player_adjust_control u_adjust_control (
 .clk(video_clk),.rst(rst_all_reg),.vs(vs),.key0_n(key1),.key1_n(key2),
 .next_req_toggle(bmp_key_next_req),.next_ack_async(bmp_key_next_ack),
 .auto_req_toggle(bmp_key_auto_req),.auto_ack_async(bmp_key_auto_ack),.tone_press(debug_tone_press),
 .mode(adjust_mode),.brightness_index(brightness_index),.contrast_index(contrast_index),
 .waveform_toggle(waveform_toggle),.video_mode_press(video_mode_press),.debug_state(control_debug_state)
);
// key0_n_async was tied high in C29: test pattern mode is unreachable.
assign probe_mode = 1'b0;
assign probe_tone_toggle = debug_tone_press;
assign vout_data_base = osd_frame_valid ? vout_data_raw : 24'd0;

// RGB888 pixel API; SDRAM word layout is owned by the frame buffer.
wire bmp_write_ready;
frame_buffer_rgb888 #(
    .FRAME_WIDTH       (DISPLAY_WIDTH),
    .FRAME_HEIGHT      (DISPLAY_HEIGHT),
    .WRITE_V_FLIP      (1)
) u_frame_buffer (
    .rst               (rst_all),
    .mem_clk           (ext_mem_clk),
    .mem_clk_shift     (ext_mem_clk_sft),
    .write_clk         (sd_card_clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_frame_index (write_buf_idx),
    .write_jpeg420     (video_mode_sd),
    .write_pixel_en    (sd_card_write_en),
    .write_pixel_rgb   (sd_card_write_data),
    .write_pixel_ready (bmp_write_ready),
    .write_finish      (frame_write_finish),
    .read_clk          (video_clk),
    .read_req          (video_read_req_osd),
    .read_req_ack      (video_read_req_ack),
    .read_frame_index  (osd_buffer_idx),
    .read_jpeg420      (video_mode),
    .read_wipe_active  (wipe_active),.read_wipe_rows(wipe_rows),
    .read_wipe_new_index(wipe_new_buffer),
    .read_pixel_en     (video_read_en),
    .read_pixel_rgb    (video_read_data),
    .debug_memory()
);

// One RIFF player: BGM.WAV in photo mode, TEST.WAV in video mode.
tf_wav_file_player #(
    .FIFO_DEPTH          (2048)
) u_wav_player (
    .clk(sd_card_clk), .rst(rst_all), .sd_init_done(fs_ready && fs_wav_found),
    .file_size(fs_wav_size),.file_error(wav_map_error),
    .sd_read(wav_card_read), .sd_addr(wav_card_addr),
    .sd_data(wav_card_data), .sd_valid(wav_card_valid), .sd_end(wav_card_end),
    .sample_take(wav_sample_take), .sample_data(wav_sample_data),
    .sample_available(wav_sample_available), .primed(wav_primed), .error(wav_error),
    .debug_state(),.debug_phase(),.debug_scan_pos(),.debug_scan_byte(),
    .debug_sample_push(),.debug_push_data(),.debug_fifo_level(),
    .debug_push_pos(),.debug_data_offset()
);

// Combinational overlays retain the existing VS/DE and pixel latency.
wire [23:0] vout_data_osd, vout_data_adjusted, vout_data_dynamic, vout_data_adjust_osd;
wire [23:0] adjusted_rgb;
player_rgb_adjust u_rgb_adjust (.rgb_in(vout_data_base),
 .brightness_index(brightness_index),.contrast_index(contrast_index),.rgb_out(adjusted_rgb));
assign vout_data_adjusted = de ? adjusted_rgb : vout_data_base;
// Passive pixel-domain measurement: each acknowledged new display buffer is
// counted once. Repeated HDMI scans of the same content do not increment FPS.
reg [1:0] video_paused_pixel;
reg video_display_seen;
reg [24:0] video_fps_tick;
reg [3:0] video_fps_count_tens, video_fps_count_ones;
reg [3:0] video_fps_tens, video_fps_ones;
reg video_fps_valid;
wire video_new_frame = display_finish_toggle != video_display_seen;
wire video_fps_saturated = video_fps_count_tens == 4'd9 && video_fps_count_ones == 4'd9;
wire [3:0] video_fps_next_ones = video_fps_saturated ? 4'd9 :
    (video_fps_count_ones == 4'd9 ? 4'd0 : video_fps_count_ones + 4'd1);
wire [3:0] video_fps_next_tens = video_fps_saturated ? 4'd9 :
    (video_fps_count_ones == 4'd9 ? video_fps_count_tens + 4'd1 : video_fps_count_tens);
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        video_paused_pixel <= 0;
        video_display_seen <= 0;
        video_fps_tick <= 0;
        video_fps_count_tens <= 0; video_fps_count_ones <= 0;
        video_fps_tens <= 0; video_fps_ones <= 0; video_fps_valid <= 0;
    end else begin
        video_paused_pixel <= {video_paused_pixel[0], video_paused};
        video_display_seen <= display_finish_toggle;
        if (!video_mode || !osd_frame_valid || video_paused_pixel[1]) begin
            video_fps_tick <= 0;
            video_fps_count_tens <= 0; video_fps_count_ones <= 0;
            video_fps_tens <= 0; video_fps_ones <= 0;
            video_fps_valid <= video_mode && video_paused_pixel[1];
        end else if (video_fps_tick == 25'd24999999) begin
            video_fps_tick <= 0;
            video_fps_tens <= video_new_frame ? video_fps_next_tens : video_fps_count_tens;
            video_fps_ones <= video_new_frame ? video_fps_next_ones : video_fps_count_ones;
            video_fps_count_tens <= 0; video_fps_count_ones <= 0;
            video_fps_valid <= 1;
        end else begin
            video_fps_tick <= video_fps_tick + 1'b1;
            if (video_new_frame) begin
                video_fps_count_tens <= video_fps_next_tens;
                video_fps_count_ones <= video_fps_next_ones;
            end
        end
    end
end

player_osd u_osd (
    .clk(video_clk),.rst(rst_all),.vs(vs),.de(de),.rgb_in(vout_data_adjusted),
    .image_index(osd_image_index),.image_count(osd_image_count),
    .video_mode(video_mode),.video_paused(video_paused_pixel[1]),
    .fps_tens(video_fps_tens),.fps_ones(video_fps_ones),.fps_valid(video_fps_valid),
    .auto_mode(osd_auto_mode),.image_valid(osd_frame_valid),.rgb_out(vout_data_osd)
);
player_dynamic_text #(.CLK_FREQ_HZ(25000000)) u_dynamic_text (
    .clk(video_clk),.rst(rst_all),.vs(vs),.de(de),
    .probe_mode(probe_mode),.rgb_in(vout_data_osd),.rgb_out(vout_data_dynamic)
);

player_adjust_osd u_adjust_osd (.clk(video_clk),.rst(rst_all),.vs(vs),.de(de),
 .rgb_in(vout_data_dynamic),.mode(adjust_mode),.brightness_index(brightness_index),
 .contrast_index(contrast_index),.rgb_out(vout_data_adjust_osd));
// Passive observer of the exact PCM/VALID buses presented to the HDMI core.
player_pcm_waveform #(.CLK_FREQ_HZ(25000000)) u_pcm_waveform (
 .clk(video_clk),.rst(rst_all),.vs(vs),.de(de),.rgb_in(vout_data_adjust_osd),
 .overlay_enable(!video_mode),
 .audio_valid(audio_valid),.audio_pcm(audio_left_data),.tone_mode(debug_tone_mode),
 .freeze_toggle(waveform_toggle),
 .rgb_out(vout_data),.spectrum_debug_frames(),.spectrum_debug_data(),
 .spectrum_debug_progress(),.spectrum_debug_events(),.spectrum_debug_accepted(),
 .spectrum_debug_control()
);
player_audio_probe #(.PLAY_GATE(1)) u_audio_probe (
    .pixel_clk(video_clk),.sd_clk(sd_card_clk),.rst(rst_all),
    .tone_toggle(probe_tone_toggle),.primed(wav_primed && (!video_mode_sd || video_audio_go)),
    .play_enable(!video_mode_sd || (video_audio_go && !video_paused)),
    .sample_available(wav_sample_available),.sample_data(wav_sample_data),
    .sample_take(wav_sample_take),.underflow(audio_underflow),
    .underflow_event(),
    .audio_valid(audio_valid),.audio_left(audio_left_data),.audio_right(audio_right_data),
    .acr_valid(acr_valid),.acr_cts(acr_cts),.acr_n(acr_n),
    .led(led),.tone_mode(debug_tone_mode)
);


// C31 controlled ablation restores C29 audio observations and LED meanings.
assign shared_card_read=fs_ready ? arb_card_read : fs_read;
assign shared_card_addr=fs_ready ? arb_card_addr : fs_addr;
assign arb_card_valid=fs_ready && shared_card_valid;
assign arb_card_end=fs_ready && shared_card_end;

wire [15:0] tf_crc_checked, tf_crc_bad;
// C14103: use the original two-system-cycle SPI half-period for 40 ns readback margin.
sd_card_top #(.SPI_HIGH_SPEED_DIV(0), .SPI_FAST_DIV0(0)) u_shared_card (
    .clk(sd_card_clk), .rst(rst_all),
    .SD_nCS(sd_ncs), .SD_DCLK(sd_dclk), .SD_MOSI(sd_mosi), .SD_MISO(sd_miso),
    .sd_init_done(card_init_done),
    .sd_sec_read(shared_card_read), .sd_sec_read_addr(shared_card_addr),
    .sd_sec_read_data(shared_card_data), .sd_sec_read_data_valid(shared_card_valid),
    .sd_sec_read_end(shared_card_end),
    .sd_sec_write(1'b0), .sd_sec_write_addr(32'd0), .sd_sec_write_data(8'd0),
    .debug_state(), .debug_command(),
    .read_crc_checked(tf_crc_checked), .read_crc_bad(tf_crc_bad),
    .sd_sec_write_data_req(), .sd_sec_write_end()
);
// ===================== RGB/DE 转 AXIS 视频 =====================
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_all),
    .I_vs          (vs),
    .I_de          (de),
    .I_rgb         (vout_data),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

// AC201 does not connect HDMI DDC to the FPGA. Use fixed 640x480 timing.

// ===================== HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 800        ),
    .HSA                    ( 96         ),
    .HFP                    ( 16         ),
    .HBP                    ( 48         ),
    .HACTIVE                ( 640        ),
    .VTOTAL                 ( 525        ),
    .VSA                    ( 2          ),
    .VFP                    ( 10         ),
    .VBP                    ( 33         ),
    .VACTIVE                ( 480        ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_all),
    .I_edid_read_trig   (1'b0),
    .O_edid_read_valid  (),
    .O_edid_read_data   (),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_valid),
    .I_audio_left_data  (audio_left_data),
    .I_audio_right_data (audio_right_data),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (hdmi_video_locked),
    .O_ddc_scl          (),
    .IO_ddc_sda         (),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_all),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

// TF25 test pages share the 50MHz SD domain with the CRC counters.
// Passive display-only snapshots; no feedback into controls or media paths.
(* ASYNC_REG = "TRUE" *) reg [15:0] control_debug_meta, control_debug_sync;
(* ASYNC_REG = "TRUE" *) reg [7:0] health_debug_meta, health_debug_sync;
wire [7:0] health_debug_source = {audio_underflow,debug_tone_mode,
    hdmi_video_locked,wav_primed,rst_all_reg,media_reset_active,key1,key2};
always @(posedge sd_card_clk or posedge rst_all_reg) begin
    if (rst_all_reg) begin
        control_debug_meta<=0; control_debug_sync<=0;
        health_debug_meta<=0; health_debug_sync<=0;
    end else begin
        control_debug_meta<=control_debug_state;
        control_debug_sync<=control_debug_meta;
        health_debug_meta<=health_debug_source;
        health_debug_sync<=health_debug_meta;
    end
end
reg [25:0] tf_page_count;
reg [2:0] tf_page;
always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin tf_page_count <= 0; tf_page <= 0; end
    else if (tf_page_count == 26'd49999999) begin
        tf_page_count <= 0;
        tf_page <= tf_page == 4 ? 0 : tf_page + 1'b1;
    end else tf_page_count <= tf_page_count + 1'b1;
end
wire [31:0] tf_page_word = tf_page == 0 ? 32'h00C14116 :
                            tf_page == 1 ? {16'hC000,tf_crc_checked} :
                            tf_page == 2 ? {16'hE000,tf_crc_bad} :
                            tf_page == 3 ? {16'hD000,control_debug_sync} :
                                           {24'hB00000,health_debug_sync};
status_hex595 #(.CLK_HZ(50000000)) u_status_hex (
    .clk(sd_card_clk),.rst(rst_all),.hex_value(tf_page_word),
    .seg7_dio(seg7_dio),.seg7_sclk(seg7_sclk),.seg7_rclk(seg7_rclk)
);
endmodule
