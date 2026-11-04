// Coherent SD-to-pixel status mailbox plus frame-boundary wipe ownership.
// The memory read ACK is synchronized before it can release the old buffer.
module player_osd_state #(
    parameter integer FRAME_HEIGHT = 480,
    parameter integer WIPE_STEP_ROWS = 8
) (
    input sd_clk, pixel_clk, rst,
    input [1:0] source_buffer, source_image,
    input [2:0] source_count,
    input source_auto, source_valid,
    input source_video,
    input read_req,
    input read_req_ack,
    output reg read_req_out,
    output [1:0] frame_buffer, frame_image,
    output [2:0] frame_count,
    output frame_auto, frame_valid,
    output reg wipe_active,
    output reg [8:0] wipe_rows,
    output wire [1:0] wipe_new_buffer,
    output reg display_finish_toggle
);
    // {valid, buffer[1:0], image[1:0], count[2:0], auto}
    reg [8:0] held_sd;
    reg request_sd, acknowledge_pixel;
    reg [1:0] ack_sync_sd, req_sync_pixel;
    reg [8:0] latest_pixel, frame_pixel, target_pixel;
    reg [1:0] read_ack_sync;
    reg read_req_prev, have_frame, release_pending;
    wire frame_edge = read_req && !read_req_prev;
    wire read_ack_pixel = read_ack_sync[1];
    wire [9:0] stepped_rows = {1'b0, wipe_rows} + WIPE_STEP_ROWS;
    wire [8:0] row_limit = (FRAME_HEIGHT > 511) ? 9'd511 : FRAME_HEIGHT[8:0];

    always @(posedge sd_clk or posedge rst) begin
        if (rst) begin
            held_sd <= 9'd0;
            request_sd <= 1'b0;
            ack_sync_sd <= 2'b00;
        end else begin
            ack_sync_sd <= {ack_sync_sd[0], acknowledge_pixel};
            // Publish only when the previous entire bundle has been consumed.
            if (ack_sync_sd[1] == request_sd) begin
                held_sd <= {source_valid, source_buffer, source_image,
                            source_count, source_auto};
                request_sd <= ~request_sd;
            end
        end
    end

    always @(posedge pixel_clk or posedge rst) begin
        if (rst) begin
            req_sync_pixel <= 2'b00;
            acknowledge_pixel <= 1'b0;
            latest_pixel <= 9'd0;
            frame_pixel <= 9'd0;
            target_pixel <= 9'd0;
            read_ack_sync <= 2'b00;
            read_req_prev <= 1'b0;
            read_req_out <= 1'b0;
            have_frame <= 1'b0;
            release_pending <= 1'b0;
            wipe_active <= 1'b0;
            wipe_rows <= 9'd0;
            display_finish_toggle <= 1'b0;
        end else begin
            req_sync_pixel <= {req_sync_pixel[0], request_sd};
            read_ack_sync <= {read_ack_sync[0], read_req_ack};
            if (req_sync_pixel[1] != acknowledge_pixel) begin
                // held_sd has settled before the synchronized toggle arrives,
                // and cannot be changed until this ACK returns to sd_clk.
                latest_pixel <= held_sd;
                acknowledge_pixel <= req_sync_pixel[1];
                if (!held_sd[8]) begin
                    // A runtime validity clear cancels an animation without
                    // claiming that a completed display read released memory.
                    wipe_active <= 1'b0;
                    wipe_rows <= 9'd0;
                    release_pending <= 1'b0;
                    have_frame <= 1'b0;
                    frame_pixel <= {1'b0, frame_pixel[7:0]};
                end
            end

            read_req_prev <= read_req;
            read_req_out <= read_req;

            // ACK may remain asserted for several cycles after raw read_req
            // falls. Keep the release pending until the synchronized level is
            // observed; this also tolerates the delayed read_req_out pipeline.
            if (release_pending && read_ack_pixel) begin
                display_finish_toggle <= ~display_finish_toggle;
                release_pending <= 1'b0;
            end

            if (frame_edge) begin
                if (latest_pixel[8]) begin
                    if (!have_frame) begin
                        // The first complete image is displayed directly.
                        frame_pixel <= latest_pixel;
                        have_frame <= 1'b1;
                        release_pending <= 1'b1;
                        wipe_active <= 1'b0;
                        wipe_rows <= 9'd0;
                    end else if (wipe_active) begin
                        // Keep old buffer/image ownership throughout the wipe;
                        // labels can follow the newest coherent mailbox bundle.
                        frame_pixel <= {frame_pixel[8:4], latest_pixel[3:0]};
                        if (stepped_rows >= row_limit) begin
                            frame_pixel <= {target_pixel[8:4], latest_pixel[3:0]};
                            wipe_active <= 1'b0;
                            wipe_rows <= 9'd0;
                            release_pending <= 1'b1;
                        end else begin
                            wipe_rows <= stepped_rows[8:0];
                        end
                    end else if (release_pending) begin
                        // A release ACK is still in flight; do not start a
                        // second transition or acknowledge another buffer.
                        frame_pixel <= {frame_pixel[8:4], latest_pixel[3:0]};
                    end else if (source_video && (latest_pixel[7:6] != frame_pixel[7:6])) begin
                        frame_pixel <= latest_pixel;
                        wipe_active <= 1'b0;
                        wipe_rows <= 9'd0;
                        release_pending <= 1'b1;
                    end else if ((latest_pixel[7:6] != frame_pixel[7:6]) ||
                                 (latest_pixel[5:4] != frame_pixel[5:4])) begin
                        target_pixel <= latest_pixel;
                        frame_pixel <= {frame_pixel[8:4], latest_pixel[3:0]};
                        wipe_active <= 1'b1;
                        wipe_rows <= (WIPE_STEP_ROWS >= row_limit) ? row_limit : WIPE_STEP_ROWS;
                    end else begin
                        // Same buffer/image: refresh count/auto only, with no
                        // animation and no ownership release toggle.
                        frame_pixel <= {frame_pixel[8:4], latest_pixel[3:0]};
                    end
                end
            end
        end
    end

    assign {frame_valid, frame_buffer, frame_image, frame_count, frame_auto}
        = frame_pixel;
    assign wipe_new_buffer = target_pixel[7:6];
endmodule
