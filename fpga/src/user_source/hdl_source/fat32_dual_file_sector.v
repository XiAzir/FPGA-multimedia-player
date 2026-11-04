// Arch17 shared FAT32 sector mapper candidate.
// One physical-sector engine serves two independent file-walk contexts. The
// engine returns to arbitration after every FAT or data sector; WAV receives
// at most AUDIO_BURST_MAX consecutive sectors while BMP is waiting.
module fat32_dual_file_sector #(
    parameter [31:0] WAIT_LIMIT = 32'd50000000,
    parameter integer AUDIO_BURST_MAX = 2,
    parameter integer REQUEST_STABLE = 1,
    parameter integer WAV_STATIC_FILE = 1
)(
    input wire clk, input wire rst,
    input wire [31:0] fat_lba, input wire [31:0] data_lba,
    input wire [31:0] cluster_count, input wire [3:0] sectors_per_cluster_shift,

    input wire bmp_enable, input wire [31:0] bmp_start_cluster,
    input wire [31:0] bmp_file_size, input wire bmp_file_read,
    input wire [31:0] bmp_file_sector,
    output reg [7:0] bmp_file_data, output reg bmp_file_valid,
    output reg bmp_file_end, output reg bmp_error,
    output reg [7:0] bmp_error_code,

    input wire wav_enable, input wire [31:0] wav_start_cluster,
    input wire [31:0] wav_file_size, input wire wav_file_read,
    input wire [31:0] wav_file_sector,
    output reg [7:0] wav_file_data, output reg wav_file_valid,
    output reg wav_file_end, output reg wav_error,
    output reg [7:0] wav_error_code,

    output reg sd_read, output reg [31:0] sd_addr,
    input wire [7:0] sd_data, input wire sd_valid, input wire sd_end
);
    localparam [3:0] C_IDLE=0, C_SETUP=1, C_FAT_WAIT=2,
                     C_DATA_WAIT=3, C_GAP=4, C_FAT_EVAL=5,
                     C_DISPATCH=6, C_DRAIN=7;
    localparam [7:0] E_RANGE=8'h01, E_CLUSTER=8'h03, E_ADDR=8'h04,
                     E_SHORT=8'h05, E_FAT=8'h06, E_EOC=8'h07,
                     E_LOOP=8'h08, E_LIMIT=8'h09, E_TIMEOUT=8'h0a;

    // Per-client request, walk, Brent, cache, and handshake context.
    reg [31:0] rq_sector_q [0:1];
    reg [31:0] rq_start_q [0:1];
    reg [31:0] rq_size_q [0:1];
    wire [31:0] rq_sector [0:1];
    wire [31:0] rq_start [0:1];
    wire [31:0] rq_size [0:1];
    reg [27:0] current_cluster [0:1];
    reg [11:0] target_index [0:1];
    reg [11:0] walk_index [0:1];
    reg [27:0] cache_start [0:1];
    reg [31:0] cache_size [0:1];
    reg cache_valid [0:1];
    wire [27:0] cache_cluster [0:1];
    wire [11:0] cache_index [0:1];
    wire [27:0] cache_brent_anchor [0:1];
    wire [12:0] cache_brent_power [0:1];
    wire [12:0] cache_brent_length [0:1];
    reg [27:0] brent_anchor [0:1];
    reg [12:0] brent_power [0:1];
    reg [12:0] brent_length [0:1];
    reg armed [0:1];
    reg busy [0:1];
    reg queued [0:1];
    reg walk_initialized [0:1];

    reg [3:0] core_state;
    reg active_client;
    reg [1:0] audio_streak;
    reg [1:0] gap_count;
    reg gap_was_fat;
    reg [9:0] byte_count;
    reg [8:0] wanted_offset;
    reg [7:0] fat_b0, fat_b1, fat_b2, fat_b3;
    reg [31:0] wait_count [0:1];
    reg [31:0] next_cluster;

    wire [31:0] in_start [0:1];
    wire [31:0] in_size [0:1];
    wire [31:0] in_sector [0:1];
    wire [1:0] in_enable;
    wire [1:0] in_read;
    assign in_start[0]=bmp_start_cluster;
    assign in_start[1]=wav_start_cluster;
    assign in_size[0]=bmp_file_size;
    assign in_size[1]=wav_file_size;
    assign in_sector[0]=bmp_file_sector;
    assign in_sector[1]=wav_file_sector;
    assign in_enable={wav_enable,bmp_enable};
    assign in_read={wav_file_read,bmp_file_read};
    assign rq_sector[0] = REQUEST_STABLE ? bmp_file_sector : rq_sector_q[0];
    assign rq_sector[1] = REQUEST_STABLE ? wav_file_sector : rq_sector_q[1];
    assign rq_start[0] = REQUEST_STABLE ? bmp_start_cluster : rq_start_q[0];
    assign rq_start[1] = (REQUEST_STABLE || WAV_STATIC_FILE) ? wav_start_cluster : rq_start_q[1];
    assign rq_size[0] = REQUEST_STABLE ? bmp_file_size : rq_size_q[0];
    assign rq_size[1] = (REQUEST_STABLE || WAV_STATIC_FILE) ? wav_file_size : rq_size_q[1];
    assign cache_cluster[0]=current_cluster[0];
    assign cache_cluster[1]=current_cluster[1];
    assign cache_index[0]=target_index[0];
    assign cache_index[1]=target_index[1];
    assign cache_brent_anchor[0]=brent_anchor[0];
    assign cache_brent_anchor[1]=brent_anchor[1];
    assign cache_brent_power[0]=brent_power[0];
    assign cache_brent_power[1]=brent_power[1];
    assign cache_brent_length[0]=brent_length[0];
    assign cache_brent_length[1]=brent_length[1];

    wire [23:0] sectors_needed =
        {1'b0, rq_size[active_client][31:9]} +
        {23'd0, (|rq_size[active_client][8:0])};
    wire [43:0] data_addr_tmp = {12'd0, data_lba} +
        (({16'd0, (current_cluster[active_client] - 28'd2)} <<
          sectors_per_cluster_shift) |
         (rq_sector[active_client] &
          ((32'd1 << sectors_per_cluster_shift) - 32'd1)));
    wire [32:0] fat_addr_tmp = {1'b0, fat_lba} +
        {12'd0, current_cluster[active_client][27:7]};

    task fail_active;
        input [7:0] code;
        begin
            if (active_client) begin
                wav_error <= 1'b1;
                wav_error_code <= code;
                wav_file_end <= 1'b1;
            end else begin
                bmp_error <= 1'b1;
                bmp_error_code <= code;
                bmp_file_end <= 1'b1;
            end
            busy[active_client] <= 1'b0;
            queued[active_client] <= 1'b0;
            walk_initialized[active_client] <= 1'b0;
            if (sd_read && !sd_end) core_state <= C_DRAIN;
            else begin
                sd_read <= 1'b0;
                core_state <= C_IDLE;
            end
        end
    endtask

    integer i, j;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            core_state <= C_IDLE;
            active_client <= 0;
            audio_streak <= 0;
            gap_count <= 0;
            gap_was_fat <= 0;
            byte_count <= 0;
            wanted_offset <= 0;
            fat_b0 <= 0; fat_b1 <= 0; fat_b2 <= 0; fat_b3 <= 0;
            next_cluster <= 0;
            sd_read <= 0;
            sd_addr <= 0;
            bmp_file_data <= 0; bmp_file_valid <= 0; bmp_file_end <= 0;
            bmp_error <= 0; bmp_error_code <= 0;
            wav_file_data <= 0; wav_file_valid <= 0; wav_file_end <= 0;
            wav_error <= 0; wav_error_code <= 0;
            for (i=0;i<2;i=i+1) begin
                rq_sector_q[i] <= 0; rq_start_q[i] <= 0; rq_size_q[i] <= 0;
                current_cluster[i] <= 0; target_index[i] <= 0; walk_index[i] <= 0;
                cache_start[i] <= 0; cache_size[i] <= 0; cache_valid[i] <= 0;
                brent_anchor[i] <= 0; brent_power[i] <= 1; brent_length[i] <= 0;
                armed[i] <= 0; busy[i] <= 0; queued[i] <= 0;
                walk_initialized[i] <= 0;
                wait_count[i] <= 0;
            end
        end else begin
            bmp_file_valid <= 0; bmp_file_end <= 0;
            wav_file_valid <= 0; wav_file_end <= 0;

            // Preserve each legacy mapper's disable/re-arm and cache behavior.
            for (i=0;i<2;i=i+1) begin
                if (!in_enable[i]) begin
                    busy[i] <= 0;
                    queued[i] <= 0;
                    armed[i] <= 0;
                    cache_valid[i] <= 0;
                    walk_initialized[i] <= 0;
                    wait_count[i] <= 0;
                end else if (!busy[i]) begin
                    if (!in_read[i]) armed[i] <= 1;
                    if (in_read[i] && armed[i] &&
                        !((core_state == C_DRAIN) && (active_client == i)) &&
                        ((i==0) ? !bmp_error : !wav_error)) begin
                        armed[i] <= 0;
                        busy[i] <= 1;
                        queued[i] <= 1;
                        walk_initialized[i] <= 0;
                        if (!REQUEST_STABLE) rq_sector_q[i] <= in_sector[i];
                        if (!(REQUEST_STABLE || ((i==1) && WAV_STATIC_FILE)))
                            rq_start_q[i] <= in_start[i];
                        if (!(REQUEST_STABLE || ((i==1) && WAV_STATIC_FILE)))
                            rq_size_q[i] <= in_size[i];
                    end
                end
            end

            if (core_state == C_IDLE) begin
                sd_read <= 0;
                if (wav_enable && queued[1] &&
                    (!bmp_enable || !queued[0] || audio_streak < AUDIO_BURST_MAX)) begin
                    active_client <= 1;
                    queued[1] <= 0;
                    if (audio_streak < AUDIO_BURST_MAX)
                        audio_streak <= audio_streak + 1'b1;
                    core_state <= C_SETUP;
                end else if (bmp_enable && queued[0]) begin
                    active_client <= 0;
                    queued[0] <= 0;
                    audio_streak <= 0;
                    core_state <= C_SETUP;
                end
            end else if (core_state == C_SETUP) begin
                if (!in_enable[active_client] || !busy[active_client]) begin
                    busy[active_client] <= 0;
                    queued[active_client] <= 0;
                    core_state <= C_IDLE;
                end else if (walk_initialized[active_client]) begin
                    core_state <= C_DISPATCH;
                end else if ((rq_size[active_client] == 0) ||
                    ({1'b0,rq_sector[active_client]} >= sectors_needed)) begin
                    fail_active(E_RANGE);
                end else if (sectors_needed >
                    (33'd4096 << sectors_per_cluster_shift)) begin
                    fail_active(E_LIMIT);
                end else if ((rq_start[active_client] < 2) ||
                    (rq_start[active_client] > cluster_count + 1)) begin
                    fail_active(E_CLUSTER);
                end else begin
                    if (cache_valid[active_client] &&
                        ((active_client && WAV_STATIC_FILE) ||
                         ((cache_start[active_client] == rq_start[active_client]) &&
                          (cache_size[active_client] == rq_size[active_client]))) &&
                        ((rq_sector[active_client] >> sectors_per_cluster_shift) >=
                         cache_index[active_client])) begin
                        walk_index[active_client] <= cache_index[active_client];
                    end else begin
                        current_cluster[active_client] <= rq_start[active_client];
                        walk_index[active_client] <= 0;
                        brent_anchor[active_client] <= rq_start[active_client];
                        brent_power[active_client] <= 1;
                        brent_length[active_client] <= 0;
                        if (cache_valid[active_client] &&
                            ((cache_start[active_client] != rq_start[active_client]) ||
                             (cache_size[active_client] != rq_size[active_client])))
                            cache_valid[active_client] <= 0;
                    end
                    target_index[active_client] <=
                        rq_sector[active_client] >> sectors_per_cluster_shift;
                    walk_initialized[active_client] <= 1;
                    core_state <= C_DISPATCH;
                end
            end else if (core_state == C_DISPATCH) begin
                if (!in_enable[active_client] || !busy[active_client]) begin
                    sd_read <= 0;
                    core_state <= C_IDLE;
                end else if (walk_index[active_client] == target_index[active_client]) begin
                    if (|data_addr_tmp[43:32]) fail_active(E_ADDR);
                    else begin
                        sd_addr <= data_addr_tmp[31:0];
                        sd_read <= 1;
                        byte_count <= 0;
                        core_state <= C_DATA_WAIT;
                    end
                end else begin
                    if (fat_addr_tmp[32]) fail_active(E_ADDR);
                    else begin
                        sd_addr <= fat_addr_tmp[31:0];
                        wanted_offset <= {current_cluster[active_client][6:0],2'b00};
                        byte_count <= 0; fat_b0<=0; fat_b1<=0; fat_b2<=0; fat_b3<=0;
                        sd_read <= 1;
                        core_state <= C_FAT_WAIT;
                    end
                end
            end else if (core_state == C_FAT_WAIT || core_state == C_DATA_WAIT) begin
                if (sd_valid && in_enable[active_client]) begin
                    if (byte_count >= 10'd512) begin
                        fail_active(E_SHORT);
                    end else begin
                        if (core_state == C_FAT_WAIT) begin
                            if (byte_count == wanted_offset) fat_b0 <= sd_data;
                            if (byte_count == wanted_offset + 1'b1) fat_b1 <= sd_data;
                            if (byte_count == wanted_offset + 2'd2) fat_b2 <= sd_data;
                            if (byte_count == wanted_offset + 2'd3) fat_b3 <= sd_data;
                        end else if (active_client) begin
                            wav_file_data <= sd_data;
                            wav_file_valid <= 1;
                        end else begin
                            bmp_file_data <= sd_data;
                            bmp_file_valid <= 1;
                        end
                        byte_count <= byte_count + 1'b1;
                    end
                end
                if (sd_end) begin
                    sd_read <= 0;
                    gap_count <= 0;
                    gap_was_fat <= (core_state == C_FAT_WAIT);
                    core_state <= C_GAP;
                    if (!in_enable[active_client]) begin
                        busy[active_client] <= 0;
                        queued[active_client] <= 0;
                        walk_initialized[active_client] <= 0;
                        core_state <= C_IDLE;
                    end else if (byte_count != 10'd512) begin
                        fail_active(E_SHORT);
                    end else if (core_state == C_DATA_WAIT) begin
                        if (in_enable[active_client]) begin
                            if (active_client) wav_file_end <= 1;
                            else bmp_file_end <= 1;
                            busy[active_client] <= 0;
                            cache_valid[active_client] <= 1;
                            if (!(active_client && WAV_STATIC_FILE)) begin
                                cache_start[active_client] <= rq_start[active_client];
                                cache_size[active_client] <= rq_size[active_client];
                            end
                            walk_initialized[active_client] <= 0;
                        end
                        queued[active_client] <= 0;
                    end
                end
            end else if (core_state == C_GAP) begin
                if (gap_count == 2) begin
                    gap_count <= 0;
                    if (gap_was_fat) core_state <= C_FAT_EVAL;
                    else core_state <= C_IDLE;
                end else gap_count <= gap_count + 1'b1;
            end else if (core_state == C_FAT_EVAL) begin
                if (!in_enable[active_client] || !busy[active_client]) begin
                    queued[active_client] <= 0;
                    walk_initialized[active_client] <= 0;
                    core_state <= C_IDLE;
                end else begin
                    next_cluster = {fat_b3,fat_b2,fat_b1,fat_b0} & 32'h0fffffff;
                    if ((next_cluster == 0) || (next_cluster == 1) ||
                        (next_cluster == 32'h0ffffff7) ||
                        ((next_cluster >= 32'h0ffffff0) && (next_cluster <= 32'h0ffffff6)))
                        fail_active(E_FAT);
                    else if (next_cluster >= 32'h0ffffff8) fail_active(E_EOC);
                    else if ((next_cluster < 2) || (next_cluster > cluster_count + 1))
                        fail_active(E_CLUSTER);
                    else if (next_cluster == brent_anchor[active_client])
                        fail_active(E_LOOP);
                    else begin
                        current_cluster[active_client] <= next_cluster[27:0];
                        walk_index[active_client] <= walk_index[active_client] + 1'b1;
                        if (brent_length[active_client] + 1'b1 == brent_power[active_client]) begin
                            brent_anchor[active_client] <= next_cluster[27:0];
                            brent_power[active_client] <= brent_power[active_client] << 1;
                            brent_length[active_client] <= 0;
                        end else brent_length[active_client] <= brent_length[active_client] + 1'b1;
                        queued[active_client] <= 1;
                        core_state <= C_IDLE;
                    end
                end
            end else if (core_state == C_DRAIN) begin
                if (sd_end) begin
                    sd_read <= 0;
                    core_state <= C_IDLE;
                end
            end

            // Apply watchdog outcomes after the shared FSM so a same-cycle
            // timeout cannot dispatch a new physical request.
            for (j=0;j<2;j=j+1) begin
                if (!in_enable[j] || !busy[j]) begin
                    wait_count[j] <= 0;
                end else if ((active_client == j) &&
                             ((core_state == C_FAT_WAIT) ||
                              (core_state == C_DATA_WAIT)) && (sd_valid || sd_end)) begin
                    wait_count[j] <= 0;
                end else if (queued[j] || ((active_client == j) &&
                             ((core_state == C_SETUP) || (core_state == C_DISPATCH) ||
                              (core_state == C_FAT_WAIT) || (core_state == C_DATA_WAIT)))) begin
                    if (wait_count[j] >= WAIT_LIMIT-1'b1) begin
                        if (j==1) begin wav_error<=1; wav_error_code<=E_TIMEOUT; wav_file_end<=1; end
                        else begin bmp_error<=1; bmp_error_code<=E_TIMEOUT; bmp_file_end<=1; end
                        busy[j] <= 0;
                        queued[j] <= 0;
                        walk_initialized[j] <= 0;
                        wait_count[j] <= 0;
                        // In C_IDLE, active_client still names the previous
                        // owner while the scheduler may be dispatching a new
                        // client in this same clock edge. Retire only this
                        // client's queue; do not overwrite that new dispatch.
                        if ((active_client == j) && (core_state != C_IDLE)) begin
                            if (sd_read && !sd_end) core_state <= C_DRAIN;
                            else begin sd_read<=0; core_state<=C_IDLE; end
                        end
                    end else wait_count[j] <= wait_count[j] + 1'b1;
                end else wait_count[j] <= 0;
            end
            if (!in_enable[active_client] && sd_read && !sd_end)
                core_state <= C_DRAIN;
        end
    end

endmodule
