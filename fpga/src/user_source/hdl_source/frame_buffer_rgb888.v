// Pixel interface independent of SDRAM word layout.
// Photos: four RGB888 pixels occupy three 32-bit SDRAM words.
// JPEG video: two RGB565 pixels per word align each 8-pixel block row to BL4.
// Rows must contain a multiple of four pixels; frames use whole 256-word bursts.
module frame_buffer_rgb888 #(
    parameter FRAME_WIDTH = 640,
    parameter FRAME_HEIGHT = 480,
    parameter WRITE_V_FLIP = 1,
    // Data-leading-valid candidate; physical validation is still required.
    parameter SDR_READ_CAPTURE_DELAY = 0,
    parameter SDR_READ_DATA_DELAY = 1
)(
    input         rst,
    input         mem_clk,
    input         mem_clk_shift,
    input         write_clk,
    input         write_req,
    output        write_req_ack,
    input  [1:0]  write_frame_index,
    input         write_jpeg420,
    input         write_pixel_en,
    input  [23:0] write_pixel_rgb,
    output        write_pixel_ready,
    output        write_finish,
    input         read_clk,
    input         read_req,
    output        read_req_ack,
    input  [1:0]  read_frame_index,
    input         read_jpeg420,
    input         read_wipe_active,
    input  [8:0]  read_wipe_rows,
    input  [1:0]  read_wipe_new_index,
    input         read_pixel_en,
    output wire [15:0] debug_memory,
    output [23:0] read_pixel_rgb
);
    // Addresses below are 32-bit SDRAM word addresses, never pixel API ports.
    // This backend supports only frame indices 0 and 1.
    localparam ADDR_BITS = 21;
    localparam LINE_WORDS = (FRAME_WIDTH / 4) * 3;
    localparam [ADDR_BITS-1:0] FRAME_WORDS = LINE_WORDS * FRAME_HEIGHT;
    localparam [ADDR_BITS-1:0] VIDEO_FRAME_WORDS = (FRAME_WIDTH / 2) * FRAME_HEIGHT;
    localparam [ADDR_BITS-1:0] BUF0_WORD_ADDR = 0;
    localparam [ADDR_BITS-1:0] BUF1_WORD_ADDR = FRAME_WORDS;
    localparam [ADDR_BITS-1:0] UNUSED_WORD_ADDR = 0;

    wire init_done, init_ref_valid, mem_busy;
    wire [3:0] debug_write_state;
    wire debug_write_req_sync;
    assign debug_memory={init_done,init_ref_valid,mem_busy,app_read_en,app_write_en,
        write_req,write_req_ack,write_finish,debug_write_state,debug_write_req_sync,
        write_fifo_clear,backend_write_ready,read_fifo_empty};
    wire app_read_en, app_write_en, mem_read_valid;
    wire [ADDR_BITS-1:0] app_read_addr, app_write_addr;
    wire [31:0] mem_read_word, mem_write_word, read_word;
    wire [ADDR_BITS-1:0] wipe_read_addr;
    wire [3:0] write_mask;
    wire [31:0] write_word;
    wire write_word_en, read_word_pop;
    wire [31:0] photo_write_word, video_write_word;
    wire photo_write_en, video_write_en, photo_read_pop, video_read_pop;
    wire [23:0] photo_read_rgb, video_read_rgb;
    wire photo_underflow, video_underflow;
    wire read_underflow;
    assign write_word = write_jpeg420 ? video_write_word : photo_write_word;
    assign write_word_en = write_jpeg420 ? video_write_en : photo_write_en;
    assign read_word_pop = read_jpeg420 ? video_read_pop : photo_read_pop;
    assign read_pixel_rgb = read_jpeg420 ? video_read_rgb : photo_read_rgb;
    assign read_underflow = read_jpeg420 ? video_underflow : photo_underflow;
    wire read_fifo_empty, read_fifo_clear, write_fifo_clear;
    wire backend_write_ready;
    assign write_pixel_ready = backend_write_ready && !write_req && !rst;

    // Reject unsupported geometry instead of silently corrupting row/frame tails.
    generate
        if (FRAME_WIDTH <= 0 || FRAME_HEIGHT <= 0 || FRAME_WIDTH % 4 != 0 ||
            (LINE_WORDS * FRAME_HEIGHT) % 256 != 0 ||
            2 * LINE_WORDS * FRAME_HEIGHT > 2097152) begin : invalid_geometry
            RGB888_REQUIRES_ALIGNED_ROWS_WHOLE_BURSTS_AND_TWO_FRAMES_FITTING_SDRAM invalid();
        end
    endgenerate

    rgb888_pack32 u_pack (
        .clk(write_clk), .rst(rst | write_fifo_clear), .clear(write_req),
        .pixel_en(write_pixel_en && !write_jpeg420), .pixel_rgb(write_pixel_rgb),
        .word_en(photo_write_en), .word_data(photo_write_word)
    );
    rgb888_unpack32 u_unpack (
        .clk(read_clk), .rst(rst | read_fifo_clear), .clear(read_req),
        .pixel_en(read_pixel_en && !read_jpeg420), .pixel_rgb(photo_read_rgb),
        .word_empty(read_fifo_empty || read_jpeg420), .word_pop(photo_read_pop),
        .word_data(read_word), .underflow(photo_underflow)
    );
    rgb565_pack32 u_video_pack (
        .clk(write_clk), .rst(rst | write_fifo_clear), .clear(write_req),
        .pixel_en(write_pixel_en && write_jpeg420), .pixel_rgb(write_pixel_rgb),
        .word_en(video_write_en), .word_data(video_write_word)
    );
    rgb565_unpack32 u_video_unpack (
        .clk(read_clk), .rst(rst | read_fifo_clear), .clear(read_req),
        .pixel_en(read_pixel_en && read_jpeg420), .pixel_rgb(video_read_rgb),
        .word_empty(read_fifo_empty || !read_jpeg420), .word_pop(video_read_pop),
        .word_data(read_word), .underflow(video_underflow)
    );

    // Legacy queues/controller operate entirely in storage-word units.
    // FRAME_WIDTH below is the WORD stride used by the vertical flip mapper.
    // Completion remains in mem_clk; video consumes a registered pixel next edge.
    frame_read_write #(
        .SDR_READ_CAPTURE_DELAY(SDR_READ_CAPTURE_DELAY),
        .SDR_READ_DATA_DELAY(SDR_READ_DATA_DELAY),
        .WRITE_V_FLIP(WRITE_V_FLIP),
        .FRAME_WIDTH(LINE_WORDS),
        .FRAME_HEIGHT(FRAME_HEIGHT)
    ) u_legacy_frame_backend (
        .mem_clk(mem_clk), .rst(rst),
        .Sdr_init_done(init_done), .Sdr_init_ref_vld(init_ref_valid),
        .Sdr_busy(mem_busy),
        .App_rd_en(app_read_en), .App_rd_addr(app_read_addr),
        .Sdr_rd_en(mem_read_valid), .Sdr_rd_dout(mem_read_word),
        .read_clk(read_clk), .read_req(read_req), .read_req_ack(read_req_ack),
        .read_finish(),
        .read_fifo_empty(read_fifo_empty), .read_fifo_clear(read_fifo_clear),
        .write_fifo_clear(write_fifo_clear),
        .write_fifo_ready(backend_write_ready),
        .debug_write_state(debug_write_state),.debug_write_req_sync(debug_write_req_sync),
        .read_addr_0(BUF0_WORD_ADDR), .read_addr_1(BUF1_WORD_ADDR),
        .read_addr_2(UNUSED_WORD_ADDR), .read_addr_3(UNUSED_WORD_ADDR),
        .read_addr_index(read_frame_index), .read_len(read_jpeg420 ? VIDEO_FRAME_WORDS : FRAME_WORDS),
        .read_en(read_word_pop), .read_data(read_word),
        .App_wr_en(app_write_en), .App_wr_addr(app_write_addr),
        .App_wr_din(mem_write_word), .App_wr_dm(write_mask),
        .write_clk(write_clk), .write_req(write_req), .write_jpeg420(write_jpeg420),
        .write_req_ack(write_req_ack), .write_finish(write_finish),
        .write_addr_0(BUF0_WORD_ADDR), .write_addr_1(BUF1_WORD_ADDR),
        .write_addr_2(UNUSED_WORD_ADDR), .write_addr_3(UNUSED_WORD_ADDR),
        .write_addr_index(write_frame_index), .write_len(write_jpeg420 ? VIDEO_FRAME_WORDS : FRAME_WORDS),
        .write_en(write_word_en), .write_data(write_word)
    );

    player_wipe_address #(.FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT),
        .ADDR_BITS(ADDR_BITS)) u_wipe_address (
        .clk(mem_clk),.rst(rst),.frame_ack(read_req_ack),
        .wipe_active_async(read_wipe_active),.wipe_rows_async(read_wipe_rows),
        .old_buffer_async(read_frame_index),.new_buffer_async(read_wipe_new_index),
        .linear_addr(app_read_addr),.mapped_addr(wipe_read_addr)
    );
    sdram u_sdram (
        .Clk(mem_clk), .Clk_sft(mem_clk_shift), .Rst(rst),
        .Sdr_init_done(init_done), .Sdr_init_ref_vld(init_ref_valid),
        .Sdr_busy(mem_busy),
        .App_wr_en(app_write_en), .App_wr_addr(app_write_addr),
        .App_wr_dm(write_mask), .App_wr_din(mem_write_word),
        .App_rd_en(app_read_en), .App_rd_addr(wipe_read_addr),
        .Sdr_rd_en(mem_read_valid), .Sdr_rd_dout(mem_read_word)
    );
endmodule
