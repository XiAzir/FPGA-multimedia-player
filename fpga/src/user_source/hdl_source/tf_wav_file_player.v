// Dynamic WAV player for the FAT32 logical-file-sector interface.
// Supports RIFF/WAVE PCM16 mono 48 kHz only. Parsing scans chunk headers and
// fmt payloads, skips payloads by absolute file position, then seeks to data.
module tf_wav_file_player #(
    parameter integer FIFO_DEPTH = 2048,
    parameter [31:0] WAIT_LIMIT = 32'd5000000
) (
    input wire clk, input wire rst, input wire sd_init_done,
    input wire [31:0] file_size,
    input wire file_error,
    output reg sd_read, output reg [31:0] sd_addr,
    input wire [7:0] sd_data, input wire sd_valid, input wire sd_end,
    input wire sample_take, output wire [15:0] sample_data,
    output wire sample_available, output reg primed, output reg error,
    output wire [3:0] debug_state, output wire [3:0] debug_phase,
    output wire [31:0] debug_scan_pos, output wire [7:0] debug_scan_byte,
    output wire [12:0] debug_fifo_level,
    output wire debug_sample_push, output wire [15:0] debug_push_data,
    output wire [31:0] debug_push_pos, debug_data_offset
);
    localparam integer PTR_W = (FIFO_DEPTH <= 2) ? 1 : $clog2(FIFO_DEPTH);
    localparam [12:0] DEPTH_COUNT = FIFO_DEPTH;
    localparam [12:0] PRIME_LEVEL = FIFO_DEPTH / 2;

    localparam [3:0] ST_WAIT=0, ST_SCAN_REQ=1, ST_SCAN_ACTIVE=2,
        ST_GAP0=3, ST_GAP1=4, ST_GAP2=5, ST_SCAN_PARSE=6,
        ST_PLAY_REQ=7, ST_PLAY_ACTIVE=8, ST_PLAY_GAP0=9,
        ST_PLAY_GAP1=10, ST_PLAY_GAP2=11, ST_HALTED=12;
    reg [3:0] state;

    // One sector cache. Parsing only reads the current sector and can resume
    // a multi-byte field on the following sector without special cases.
    // TD SWUG106 ram_style: keep the synchronous sector cache in block RAM.
    (* ram_style = "bram" *) reg [7:0] sector_mem [0:511];
    reg [7:0] scan_byte;
    reg [31:0] scan_byte_pos;
    reg scan_byte_valid;
    // Ten bits are required to represent the completed count of 512 bytes.
    reg [9:0] sector_write_count;
    reg [31:0] loaded_sector;
    reg loaded_sector_valid;
    reg [31:0] scan_pos, riff_end;
    reg [3:0] scan_phase;
    // Passive taps; no additional RAM output register or parser delay.
    assign debug_state = state;
    assign debug_phase = scan_phase;
    assign debug_scan_pos = scan_byte_pos;
    assign debug_scan_byte = scan_byte;
    localparam [3:0] P_RIFF=0, P_WAVE=1, P_CHUNK_ID=2, P_CHUNK_SIZE=3,
        P_FMT=4, P_SKIP=5, P_DONE=6;
    reg [2:0] field_index;
    reg [31:0] field_acc;
    reg [31:0] chunk_id;
    reg [31:0] chunk_next;
    reg [4:0] fmt_index;
    reg fmt_fields_valid;
    reg fmt_found, data_found;
    reg [31:0] data_offset, data_end;
    // The data chunk is validated as nonempty and even before this endpoint
    // is latched. Its extent is already bounded by riff_end in P_CHUNK_SIZE.
    reg [23:0] riff_size_lo;
    wire [31:0] current_chunk_size = {scan_byte,field_acc[31:8]};
    reg [31:0] wait_count;

    reg [31:0] play_pos;
    reg [8:0] play_byte;
    reg [7:0] low_byte;
    reg low_valid;

    // Keep the sample storage in a synchronous block RAM rather than the
    // large distributed read mux. Independent, reset-free RAM port processes
    // preserve canonical inference. A registered bypass handles same address
    // read/write without relying on the primitive's collision result.
    (* ram_style = "bram" *) reg [15:0] fifo_mem [0:FIFO_DEPTH-1];
    reg [PTR_W-1:0] wr_ptr, rd_ptr;
    reg [12:0] fifo_count;
    reg [15:0] fifo_ram_q, fifo_bypass_word;
    reg fifo_head_bypass;
    wire [15:0] fifo_head = fifo_head_bypass ? fifo_bypass_word : fifo_ram_q;
    reg fifo_head_valid;
    wire fifo_pop = sample_take && sample_available;
    wire [12:0] fifo_after_pop = fifo_count - (fifo_pop ? 13'd1 : 13'd0);
    wire fifo_space_sector = (DEPTH_COUNT - fifo_count) >= 13'd256;
    wire play_in_range = (play_pos >= data_offset) &&
                         (play_pos < data_end);
    wire play_push_req = (state == ST_PLAY_ACTIVE) && sd_valid &&
                         play_in_range && play_pos[0];
    wire play_push = play_push_req && ((fifo_count < DEPTH_COUNT) || fifo_pop);
    wire [12:0] fifo_next_count = fifo_after_pop + (play_push ? 13'd1 : 13'd0);
    wire prefetch_needed = !fifo_head_valid || fifo_pop;
    wire [PTR_W-1:0] prefetch_ptr = fifo_pop ? rd_ptr + 1'b1 : rd_ptr;
    wire prefetch_bypass = play_push && (wr_ptr == prefetch_ptr);
    wire [15:0] prefetch_value = {sd_data, low_byte};
    wire fifo_load_head = prefetch_needed && fifo_next_count!=0;
    // Legal FIFO depths cap PRIME_LEVEL at 2048. Thirteen bits hold every
    // unsaturated sample count below that threshold; larger lengths clamp.
    reg [12:0] prime_target;

    assign debug_fifo_level = fifo_count;
    assign sample_data = fifo_head;
    assign sample_available = fifo_head_valid && (fifo_count != 0);
    // Passive aliases of the exact write event/value/absolute high-byte offset.
    assign debug_sample_push=play_push;
    assign debug_push_data=prefetch_value;
    assign debug_push_pos=play_pos;
    assign debug_data_offset=data_offset;

    // Keep the RAM ports in canonical independent clocked processes so TD can
    // map the attributed array to an EG4 block RAM.
    always @(posedge clk) begin
        if (!rst && state == ST_SCAN_ACTIVE && sd_valid &&
            sector_write_count < 10'd512)
            sector_mem[sector_write_count[8:0]] <= sd_data;
    end

    // The block RAM read output is intentionally not reset.
    always @(posedge clk) begin
        scan_byte <= sector_mem[scan_pos[8:0]];
    end

    always @(posedge clk) begin
        if(!rst && play_push) fifo_mem[wr_ptr] <= prefetch_value;
    end
    // No reset on the RAM read register; its value is only used while the
    // externally reset head-valid flag is asserted.
    always @(posedge clk) begin
        if(!rst && fifo_load_head) fifo_ram_q <= fifo_mem[prefetch_ptr];
    end

    always @(posedge clk) begin
        if (rst) begin
            state<=ST_WAIT; sd_read<=0; sd_addr<=0; sector_write_count<=0;
            scan_byte_pos<=0; scan_byte_valid<=0;
            loaded_sector<=0; loaded_sector_valid<=0; scan_pos<=0; riff_end<=0;
            scan_phase<=P_RIFF; field_index<=0; field_acc<=0; chunk_id<=0;
            chunk_next<=0; fmt_index<=0;
            fmt_fields_valid<=0; fmt_found<=0; data_found<=0;
            data_offset<=0; data_end<=0; riff_size_lo<=0; prime_target<=0; play_pos<=0; play_byte<=0;
            wait_count<=0;
            low_byte<=0; low_valid<=0; wr_ptr<=0; rd_ptr<=0; fifo_count<=0;
            fifo_head_bypass<=0;fifo_bypass_word<=0;
            fifo_head_valid<=0;
            primed<=0; error<=0;
        end else begin
            if (file_error) begin error<=1; sd_read<=0; state<=ST_HALTED; end
            if (play_push) wr_ptr<=wr_ptr+1'b1;
            if (fifo_pop) rd_ptr<=rd_ptr+1'b1;
            fifo_count<=fifo_next_count;
            if (fifo_load_head) begin
                fifo_head_bypass<=prefetch_bypass;
                if(prefetch_bypass) fifo_bypass_word<=prefetch_value;
                fifo_head_valid<=1;
            end else if (fifo_pop && fifo_next_count==0) fifo_head_valid<=0;
            if (!primed && prime_target!=0 && fifo_next_count>=prime_target) primed<=1;
            if (play_push_req && !play_push) error<=1;
            if (sample_take && primed && !sample_available) error<=1;

            case (state)
                ST_WAIT: begin
                    sd_read<=0;
                    if (sd_init_done) begin
                        if (FIFO_DEPTH < 256 || FIFO_DEPTH > 4096 ||
                            (FIFO_DEPTH & (FIFO_DEPTH-1)) != 0) begin
                            error<=1; state<=ST_HALTED;
                        end else if (file_size < 12) begin error<=1; state<=ST_HALTED; end
                        else begin scan_pos<=0; scan_phase<=P_RIFF; field_index<=0;
                            field_acc<=0; loaded_sector_valid<=0; state<=ST_SCAN_REQ; end
                    end
                end
                ST_SCAN_REQ: begin
                    sd_read<=1; sd_addr<=scan_pos[31:9]; sector_write_count<=0;
                    scan_byte_valid<=0;
                    wait_count<=0;
                    state<=ST_SCAN_ACTIVE;
                end
                ST_SCAN_ACTIVE: begin
                    sd_read<=1;
                    if (sd_valid) begin
                        if (sector_write_count >= 10'd512) begin
                            error<=1; sd_read<=0; state<=ST_HALTED;
                        end else begin
                            sector_write_count<=sector_write_count+1'b1;
                            wait_count<=0;
                        end
                    end else if (!sd_end) begin
                        if (wait_count>=WAIT_LIMIT) begin error<=1; sd_read<=0; state<=ST_HALTED; end
                        else wait_count<=wait_count+1'b1;
                    end
                    if (sd_end) begin
                        sd_read<=0;
                        if (sector_write_count != 10'd512) begin
                            error<=1; state<=ST_HALTED;
                        end else begin
                            loaded_sector<=sd_addr; loaded_sector_valid<=1;
                            state<=ST_GAP0;
                        end
                    end
                end
                ST_GAP0: begin sd_read<=0; state<=ST_GAP1; end
                ST_GAP1: begin sd_read<=0; state<=ST_GAP2; end
                ST_GAP2: begin sd_read<=0; state<=ST_SCAN_PARSE; end
                ST_SCAN_PARSE: begin
                    sd_read<=0;
                    if (scan_pos >= file_size || (riff_end!=0 && scan_pos>=riff_end)) begin
                        if (!fmt_found || !data_found || riff_end>file_size ||
                            data_end==data_offset || (data_end[0]!=data_offset[0]) ||
                            (data_end>riff_end) ||
                            (scan_pos >= riff_end &&
                             (scan_phase != P_CHUNK_ID || field_index != 0))) begin
                            error<=1; state<=ST_HALTED;
                        end else begin
                            if (!fmt_fields_valid || data_offset[0]) begin
                                error<=1; state<=ST_HALTED;
                            end else begin
                                play_pos<=data_offset; play_byte<=data_offset[8:0];
                                low_valid<=0; loaded_sector_valid<=0; state<=ST_PLAY_REQ;
                            end
                        end
                    end else if (!loaded_sector_valid || loaded_sector != scan_pos[31:9]) begin
                        state<=ST_SCAN_REQ;
                    end else begin
                        // Synchronous single read port for the sector cache.
                        // A byte is parsed on the cycle after this register load.
                        scan_byte_pos<=scan_pos;
                        scan_byte_valid<=1;
                        if (!scan_byte_valid || scan_byte_pos != scan_pos) begin
                            // Wait for the registered byte to match scan_pos.
                        end else begin
                        // Byte-oriented parser. The sector cache may be crossed
                        // in the middle of any ID, size, or fmt field.
                        case (scan_phase)
                            P_RIFF: begin
                                if (scan_pos<=3 && ((scan_pos==0 && scan_byte!=8'h52) ||
                                    (scan_pos==1 && scan_byte!=8'h49) ||
                                    (scan_pos==2 && scan_byte!=8'h46) ||
                                    (scan_pos==3 && scan_byte!=8'h46))) begin error<=1; state<=ST_HALTED; end
                                if (scan_pos>=8 && scan_pos<=11 &&
                                    ((scan_pos==8 && scan_byte!=8'h57) ||
                                     (scan_pos==9 && scan_byte!=8'h41) ||
                                     (scan_pos==10 && scan_byte!=8'h56) ||
                                     (scan_pos==11 && scan_byte!=8'h45))) begin error<=1; state<=ST_HALTED; end
                                if (scan_pos==4) riff_size_lo[7:0]<=scan_byte;
                                if (scan_pos==5) riff_size_lo[15:8]<=scan_byte;
                                if (scan_pos==6) riff_size_lo[23:16]<=scan_byte;
                                if (scan_pos==7) begin
                                    riff_end<= {scan_byte,riff_size_lo}+8;
                                    if ({scan_byte,riff_size_lo}<4 ||
                                        file_size<8 || {scan_byte,riff_size_lo}>file_size-8) begin error<=1; state<=ST_HALTED; end
                                end
                                if (scan_pos==11) begin scan_phase<=P_CHUNK_ID; field_index<=0; chunk_id<=0; end
                                scan_pos<=scan_pos+1;
                            end
                            P_CHUNK_ID: begin
                                // Little-endian ID bytes arrive low first; shift
                                // the accumulated word toward its final order.
                                chunk_id<={scan_byte,chunk_id[31:8]};
                                scan_pos<=scan_pos+1;
                                if(field_index==3) begin field_index<=0; field_acc<=0; scan_phase<=P_CHUNK_SIZE; end
                                else field_index<=field_index+1;
                            end
                            P_CHUNK_SIZE: begin
                                field_acc<={scan_byte,field_acc[31:8]};
                                scan_pos<=scan_pos+1;
                                if(field_index==3) begin
                                    chunk_next<=scan_pos+1+current_chunk_size+current_chunk_size[0];
                                    field_index<=0; fmt_index<=0;
                                    if (scan_pos>=riff_end || current_chunk_size>riff_end-(scan_pos+1) ||
                                        current_chunk_size[0]>riff_end-(scan_pos+1+current_chunk_size)) begin error<=1; state<=ST_HALTED; end
                                    else if(chunk_id==32'h20746d66) begin
                                        if (current_chunk_size<16) begin error<=1; state<=ST_HALTED; end
                                        else begin scan_phase<=P_FMT; fmt_fields_valid<=1; end
                                    end else if(chunk_id==32'h61746164) begin
                                        if (current_chunk_size==0 || current_chunk_size[0]) begin error<=1; state<=ST_HALTED; end
                                        else if(!data_found) begin
                                            data_found<=1; data_offset<=scan_pos+1; data_end<=scan_pos+1+current_chunk_size;
                                            // The validated even length divided by two is
                                            // exact in [13:1] below 8192 samples; any upper
                                            // bit or a count at PRIME_LEVEL saturates here.
                                            prime_target <= (current_chunk_size[31:14] != 0 || current_chunk_size[13:1] >= PRIME_LEVEL)
                                                ? PRIME_LEVEL : current_chunk_size[13:1];
                                            scan_pos<=scan_pos+1+current_chunk_size+current_chunk_size[0]; scan_phase<=P_CHUNK_ID; chunk_id<=0;
                                        end
                                        else begin error<=1; state<=ST_HALTED; end
                                    end else begin scan_pos<=scan_pos+1+current_chunk_size+current_chunk_size[0]; scan_phase<=P_CHUNK_ID; chunk_id<=0; end
                                end else field_index<=field_index+1;
                            end
                            P_FMT: begin
                                // The supported WAVE profile is fixed. Reduce
                                // each base fmt byte into one sticky validity bit
                                // instead of storing 128 bits for final equality tests.
                                case(fmt_index)
                                    0: if(scan_byte!=8'h01) fmt_fields_valid<=0;
                                    1: if(scan_byte!=8'h00) fmt_fields_valid<=0;
                                    2: if(scan_byte!=8'h01) fmt_fields_valid<=0;
                                    3: if(scan_byte!=8'h00) fmt_fields_valid<=0;
                                    4: if(scan_byte!=8'h80) fmt_fields_valid<=0;
                                    5: if(scan_byte!=8'hbb) fmt_fields_valid<=0;
                                    6: if(scan_byte!=8'h00) fmt_fields_valid<=0;
                                    7: if(scan_byte!=8'h00) fmt_fields_valid<=0;
                                    8: if(scan_byte!=8'h00) fmt_fields_valid<=0;
                                    9: if(scan_byte!=8'h77) fmt_fields_valid<=0;
                                    10: if(scan_byte!=8'h01) fmt_fields_valid<=0;
                                    11: if(scan_byte!=8'h00) fmt_fields_valid<=0;
                                    12: if(scan_byte!=8'h02) fmt_fields_valid<=0;
                                    13: if(scan_byte!=8'h00) fmt_fields_valid<=0;
                                    14: if(scan_byte!=8'h10) fmt_fields_valid<=0;
                                    15: if(scan_byte!=8'h00) fmt_fields_valid<=0;
                                endcase
                                scan_pos<=scan_pos+1; fmt_index<=fmt_index+1;
                                // Only the 16-byte PCM base fmt fields are needed.
                                // Skip an arbitrarily large extension by its declared
                                // chunk extent instead of walking every extension byte.
                                if(fmt_index+1==16) begin fmt_found<=1; scan_pos<=chunk_next; scan_phase<=P_CHUNK_ID; chunk_id<=0; end
                            end
                            default: begin scan_pos<=scan_pos+1; end
                        endcase
                        end
                    end
                end
                ST_PLAY_REQ: begin
                    sd_read<=0;
                    if (fifo_space_sector && !error) begin
                        sd_addr<=play_pos[31:9]; play_byte<=play_pos[8:0];
                        play_pos<={play_pos[31:9],9'd0};
                        wait_count<=0;
                        sector_write_count<=0; sd_read<=1; state<=ST_PLAY_ACTIVE;
                    end
                end
                ST_PLAY_ACTIVE: begin
                    sd_read<=1;
                    if (sd_valid) begin
                        if (sector_write_count >= 10'd512) begin
                            error<=1; sd_read<=0; state<=ST_HALTED;
                        end else begin
                            sector_write_count<=sector_write_count+1'b1;
                            wait_count<=0;
                            if (play_in_range) begin
                                if (!play_pos[0]) begin low_byte<=sd_data; low_valid<=1; end
                                else if(low_valid) low_valid<=0;
                            end
                            if (play_pos < data_end) play_pos<=play_pos+1;
                        end
                    end else if (!sd_end) begin
                        if (wait_count>=WAIT_LIMIT) begin error<=1; sd_read<=0; state<=ST_HALTED; end
                        else wait_count<=wait_count+1'b1;
                    end
                    if (sd_end) begin
                        sd_read<=0;
                        if (sector_write_count != 10'd512) begin
                            error<=1; state<=ST_HALTED;
                        end else state<=ST_PLAY_GAP0;
                    end
                end
                ST_PLAY_GAP0: begin sd_read<=0; state<=ST_PLAY_GAP1; end
                ST_PLAY_GAP1: begin sd_read<=0; state<=ST_PLAY_GAP2; end
                ST_PLAY_GAP2: begin
                    sd_read<=0;
                    // The payload ends at an even byte boundary. If the data
                    // chunk ends inside this sector, immediately loop to its
                    // first sector after honoring the required request gap.
                    if (play_pos >= data_end) begin
                        play_pos<=data_offset; state<=ST_PLAY_REQ;
                    end else state<=ST_PLAY_REQ;
                end
                ST_HALTED: begin sd_read<=0; end
                default: begin sd_read<=0; error<=1; state<=ST_HALTED; end
            endcase
            // Fatal indications take priority over state progress. `error` is
            // sticky, so a fault raised inside the case cannot be overwritten
            // by another assignment on the following cycle.
            if (error || file_error) begin error<=1; sd_read<=0; state<=ST_HALTED; end
        end
    end
endmodule
