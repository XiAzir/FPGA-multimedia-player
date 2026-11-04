`timescale 1ns/1ps
// Read-only FAT32 mount and root-directory catalog. Sector bytes are consumed
// in place; no 512-byte sector buffer is inferred.
module fat32_catalog #(
    parameter MAX_ROOT_CLUSTERS = 256,
    parameter SECTOR_TIMEOUT_CYCLES = 1000000
)(
    input wire clk, input wire rst, input wire sd_init_done,
    input wire audio_video_mode,
    output reg sd_read, output reg [31:0] sd_addr,
    input wire [7:0] sd_data, input wire sd_valid, input wire sd_end,
    output reg ready, output reg error, output reg [7:0] error_code,
    output reg [31:0] fat_lba, output reg [31:0] data_lba,
    output reg [31:0] cluster_count, output reg [3:0] sectors_per_cluster_shift,
    output reg [2:0] bmp_count, output reg [127:0] bmp_clusters,
    output reg [127:0] bmp_sizes, output reg wav_found,
    output reg [31:0] wav_cluster, output reg [31:0] wav_size,
    output reg video_found, output reg [31:0] video_cluster, video_size
);
localparam S_WAIT_INIT=0, S_REQ_BOOT=1, S_READ_BOOT=2, S_GAP_BOOT=3,
           S_REQ_FAT=4, S_READ_FAT=5, S_GAP_FAT=6,
           S_REQ_ROOT=7, S_READ_ROOT=8, S_GAP_ROOT=9,
           S_DONE=10, S_FAIL=11, S_BPB_PREP0=12, S_BPB_PREP1=13,
           S_BPB_PREP2=14, S_BPB_CHECK=15;
localparam E_SECTOR=8'h01, E_BPB=8'h02, E_PARTITION=8'h03,
           E_RANGE=8'h04, E_FAT=8'h05, E_ROOT_LIMIT=8'h06,
           E_ENTRY=8'h07, E_TIMEOUT=8'h08;
reg [3:0] state;
reg [9:0] byte_index;
reg [$clog2(SECTOR_TIMEOUT_CYCLES+1)-1:0] wait_count;
reg [2:0] gap_count;
reg [7:0] spc, reserved_lo, reserved_hi, fats;
reg [7:0] total16_0,total16_1, total32_b[0:3];
reg [7:0] fatsz32_b[0:3], root_b[0:3], extflags_lo, extflags_hi;
reg [7:0] signature_lo, signature_hi;
reg bps_fixed_valid;
reg rootent_fixed_valid;
reg fat16_fixed_valid;
reg version_fixed_valid;
// The first FAT32 partition wins. Capture it as bytes arrive; later
// partitions cannot affect selection, including when the first is invalid.
reg partition_found;
reg [1:0] selected_partition;
reg [31:0] selected_start, selected_size;
reg is_mbr;
reg [31:0] fat_entry_value;
reg [8:0] fat_offset;
reg [31:0] current_root_cluster;
reg [$clog2(MAX_ROOT_CLUSTERS+2)-1:0] root_clusters_read;
reg [7:0] root_sector_in_cluster;
reg root_end_marker;
// Match the 8.3 names while consuming each entry. Only match/skip flags
// are used at byte 31; retaining eleven raw name bytes is unnecessary.
reg dir_first_zero, dir_deleted, dir_skip, bmp_name_match, wav_name_match;
reg video_name_match;
// Select one audio file per mount. Mode changes take effect after media reset.
reg audio_video_latched;
reg [7:0] dir_clhi_b[0:1], dir_cllo_b[0:1], dir_size_b[0:3];
wire [31:0] total32 = {total32_b[3],total32_b[2],total32_b[1],total32_b[0]};
wire [31:0] fatsz32 = {fatsz32_b[3],fatsz32_b[2],fatsz32_b[1],fatsz32_b[0]};
wire [31:0] root32 = {root_b[3],root_b[2],root_b[1],root_b[0]};
wire [15:0] extflags = {extflags_hi,extflags_lo};
wire [31:0] reserved32 = {16'd0,reserved_hi,reserved_lo};
reg [2:0] spc_shift_calc;
always @* begin
  case (spc)
    1:spc_shift_calc=0; 2:spc_shift_calc=1; 4:spc_shift_calc=2;
    8:spc_shift_calc=3; 16:spc_shift_calc=4; 32:spc_shift_calc=5;
    64:spc_shift_calc=6; 128:spc_shift_calc=7; default:spc_shift_calc=0;
  endcase
end
wire [31:0] root_cluster_masked = root32 & 32'h0fffffff;
// Exact bounds of sums from raw BPB bytes (including malformed BPBs).
reg [33:0] fat_area_end_p0;
wire [38:0] fat_capacity_p0 = {fatsz32,7'd0};
wire [32:0] volume_end_p0 = {1'b0,(is_mbr?selected_start:32'd0)}+{1'b0,total32};
wire [32:0] partition_end_p0 = {1'b0,selected_start}+{1'b0,selected_size};
wire [31:0] active_fat_offset_p0 =
    ((extflags&16'h0080)!=0 && (extflags&16'h000f)==1)?fatsz32:32'd0;
wire [33:0] data_sector_count_p1 = {2'b0,total32}-fat_area_end_p0;
wire [32:0] fat_lba_base_p1 = {1'b0,(is_mbr?selected_start:32'd0)}+{17'd0,reserved_hi,reserved_lo};
reg [33:0] data_lba_p1, cluster_count_p2, fat_lba_p2;
reg [35:0] root_lba_p2;
wire [32:0] fat_span = (fats==2) ? {fatsz32,1'b0} : {1'b0,fatsz32};
// Invalid subtraction inputs are rejected by fat_area_end_p0>=total32 or
// root_cluster_masked<2 before any truncated value reaches an output.
wire [27:0] root_cluster_minus_two = root_cluster_masked[27:0]-28'd2;
wire [34:0] root_sector_offset = {7'd0,root_cluster_minus_two} << spc_shift_calc;
// MBR bytes 446..509: two partition-index bits and two byte-lane bits.
wire [5:0] partition_byte = byte_index[5:0]-6'd62;
wire bpb_header_candidate = (bps_fixed_valid) && spc!=0 &&
    ((spc & (spc-1'b1))==0) && spc<=128 && reserved32!=0 &&
    (fats==1 || fats==2) && rootent_fixed_valid &&
    fat16_fixed_valid && version_fixed_valid &&
    total32!=0 && fatsz32!=0 && root_cluster_masked>=2 &&
    fat_area_end_p0<total32 && cluster_count_p2>=65525 &&
    cluster_count_p2<=32'h0ffffff5 &&
    root_cluster_masked<=cluster_count_p2+1 &&
    fat_capacity_p0>=cluster_count_p2+2 &&
    (extflags&16'h0070)==0 &&
    (((extflags&16'h0080)==0) || ((extflags&16'h000f)<fats));
integer i;

task fail;
 input [7:0] code;
 begin error<=1'b1; error_code<=code; ready<=1'b0; sd_read<=1'b0; state<=S_FAIL; end
endtask

task issue_sector;
 input [3:0] next_state;
 input [31:0] lba;
 begin
   sd_addr<=lba; sd_read<=1'b1; byte_index<=0;
   wait_count<=0; state<=next_state;
 end
endtask

function [31:0] le32;
 input [7:0] b0,b1,b2,b3;
 begin le32={b3,b2,b1,b0}; end
endfunction

always @(posedge clk) begin
 if (rst) begin
   state<=S_WAIT_INIT; sd_read<=0; sd_addr<=0; ready<=0; error<=0; error_code<=0;
   audio_video_latched<=0;
   fat_lba<=0; data_lba<=0; cluster_count<=0; sectors_per_cluster_shift<=0;
   fat_area_end_p0<=0;
   data_lba_p1<=0; cluster_count_p2<=0; fat_lba_p2<=0; root_lba_p2<=0;
   bmp_count<=0; bmp_clusters<=0; bmp_sizes<=0; wav_found<=0; wav_cluster<=0; wav_size<=0;
   video_found<=0;video_cluster<=0;video_size<=0;video_name_match<=0;
   byte_index<=0; wait_count<=0; gap_count<=0;
   is_mbr<=0;
   partition_found<=0; selected_partition<=0; selected_start<=0; selected_size<=0;
    fat_entry_value<=0; fat_offset<=0;
    current_root_cluster<=0; root_clusters_read<=0; root_sector_in_cluster<=0; root_end_marker<=0;
   bps_fixed_valid<=0;  spc<=0; reserved_lo<=0; reserved_hi<=0; fats<=0;
   rootent_fixed_valid<=0;fat16_fixed_valid<=0;total16_0<=0;total16_1<=0;
   extflags_lo<=0;extflags_hi<=0;version_fixed_valid<=0;signature_lo<=0;signature_hi<=0;
   for(i=0;i<4;i=i+1) begin total32_b[i]<=0; fatsz32_b[i]<=0;root_b[i]<=0; end
   dir_first_zero<=1; dir_deleted<=0; dir_skip<=0; bmp_name_match<=0; wav_name_match<=0;
   for(i=0;i<2;i=i+1) begin dir_clhi_b[i]<=0;dir_cllo_b[i]<=0; end
   for(i=0;i<4;i=i+1) dir_size_b[i]<=0;
 end else begin
   case(state)
   S_WAIT_INIT: if(sd_init_done) begin
     audio_video_latched<=audio_video_mode;
     issue_sector(S_READ_BOOT,0);
   end
   S_REQ_BOOT: begin end
   S_READ_BOOT, S_READ_FAT, S_READ_ROOT: begin
     if(wait_count>=SECTOR_TIMEOUT_CYCLES) fail(E_TIMEOUT);
     else begin
      wait_count<=wait_count+1'b1;
      if(sd_valid) begin
       if(byte_index<512) begin
         if(state==S_READ_BOOT) begin
           case(byte_index)
             11: bps_fixed_valid<=(sd_data==0); 12: bps_fixed_valid<=bps_fixed_valid && (sd_data==2); 13: spc<=sd_data;
             14: reserved_lo<=sd_data; 15: reserved_hi<=sd_data; 16: fats<=sd_data;
             17: rootent_fixed_valid<=(sd_data==0); 18: rootent_fixed_valid<=rootent_fixed_valid && (sd_data==0); 22: fat16_fixed_valid<=(sd_data==0); 23: fat16_fixed_valid<=fat16_fixed_valid && (sd_data==0);
             19: total16_0<=sd_data; 20: total16_1<=sd_data;
             32,33,34,35: total32_b[byte_index-32]<=sd_data;
             36,37,38,39: fatsz32_b[byte_index-36]<=sd_data;
             40: extflags_lo<=sd_data; 41: extflags_hi<=sd_data; 42: version_fixed_valid<=(sd_data==0); 43: version_fixed_valid<=version_fixed_valid && (sd_data==0);
             44,45,46,47: root_b[byte_index-44]<=sd_data;
             510: signature_lo<=sd_data; 511: signature_hi<=sd_data;
             default: begin
               if(!is_mbr && byte_index>=446 && byte_index<510) begin
                 if(partition_byte==0) begin
                   partition_found<=0; selected_start<=0; selected_size<=0;
                 end
                 if(partition_byte[3:0]==4 && !partition_found &&
                    (sd_data==8'h0b || sd_data==8'h0c)) begin
                   partition_found<=1; selected_partition<=partition_byte[5:4];
                 end
                 if(partition_found && selected_partition==partition_byte[5:4]) begin
                   if(partition_byte[3:2]==2) selected_start[{partition_byte[1:0],3'b000} +: 8]<=sd_data;
                   if(partition_byte[3:2]==3) selected_size[{partition_byte[1:0],3'b000} +: 8]<=sd_data;
                 end
               end
             end
           endcase
         end else if(state==S_READ_FAT) begin
            if(byte_index[9:2]=={1'b0,fat_offset[8:2]})
              fat_entry_value[{byte_index[1:0],3'b000} +: 8]<=sd_data;
         end else begin
           case(byte_index[4:0])
             0: begin
               dir_first_zero<=(sd_data==0); dir_deleted<=(sd_data==8'he5);
               wav_name_match<=(sd_data==(audio_video_latched ? "T" : "B"));
               video_name_match<=(sd_data=="V");
             end
             1: begin wav_name_match<=wav_name_match && sd_data==(audio_video_latched ? "E" : "G");video_name_match<=video_name_match && sd_data=="I";end
             2: begin wav_name_match<=wav_name_match && sd_data==(audio_video_latched ? "S" : "M");video_name_match<=video_name_match && sd_data=="D";end
             3: begin wav_name_match<=wav_name_match && sd_data==(audio_video_latched ? "T" : " ");video_name_match<=video_name_match && sd_data=="E";end
             4: begin wav_name_match<=wav_name_match && sd_data==" ";video_name_match<=video_name_match && sd_data=="O";end
             5,6,7: begin wav_name_match<=wav_name_match && sd_data==" ";video_name_match<=video_name_match && sd_data==" ";end
             8: begin bmp_name_match<=sd_data=="B"; wav_name_match<=wav_name_match && sd_data=="W";video_name_match<=video_name_match && sd_data=="M";end
             9: begin bmp_name_match<=bmp_name_match && sd_data=="M"; wav_name_match<=wav_name_match && sd_data=="A";video_name_match<=video_name_match && sd_data=="J";end
             10: begin bmp_name_match<=bmp_name_match && sd_data=="P"; wav_name_match<=wav_name_match && sd_data=="V";video_name_match<=video_name_match && sd_data=="P";end
             11: dir_skip<=sd_data==8'h0f || sd_data[3] || sd_data[4];
             20: dir_clhi_b[0]<=sd_data; 21: dir_clhi_b[1]<=sd_data;
             26: dir_cllo_b[0]<=sd_data; 27: dir_cllo_b[1]<=sd_data;
             28: dir_size_b[0]<=sd_data; 29: dir_size_b[1]<=sd_data; 30: dir_size_b[2]<=sd_data; 31: dir_size_b[3]<=sd_data;
             default: begin end
           endcase
           if(byte_index[4:0]==31) begin
              if(dir_first_zero) root_end_marker<=1'b1;
              else if(!root_end_marker && !dir_deleted && !dir_skip) begin
               if(bmp_name_match) begin
                 if(bmp_count<4) begin
                   if(({dir_clhi_b[1],dir_clhi_b[0],dir_cllo_b[1],dir_cllo_b[0]}<2) || {sd_data,dir_size_b[2],dir_size_b[1],dir_size_b[0]}==0 || {dir_clhi_b[1],dir_clhi_b[0],dir_cllo_b[1],dir_cllo_b[0]}>cluster_count+1) fail(E_ENTRY);
                   else begin bmp_clusters[bmp_count*32 +:32]<={dir_clhi_b[1],dir_clhi_b[0],dir_cllo_b[1],dir_cllo_b[0]}; bmp_sizes[bmp_count*32 +:32]<={sd_data,dir_size_b[2],dir_size_b[1],dir_size_b[0]}; bmp_count<=bmp_count+1'b1; end
                 end
               end
               if(wav_name_match) begin
                 if(({dir_clhi_b[1],dir_clhi_b[0],dir_cllo_b[1],dir_cllo_b[0]}<2) || {sd_data,dir_size_b[2],dir_size_b[1],dir_size_b[0]}==0 || {dir_clhi_b[1],dir_clhi_b[0],dir_cllo_b[1],dir_cllo_b[0]}>cluster_count+1) fail(E_ENTRY);
                 else begin wav_found<=1; wav_cluster<={dir_clhi_b[1],dir_clhi_b[0],dir_cllo_b[1],dir_cllo_b[0]}; wav_size<={sd_data,dir_size_b[2],dir_size_b[1],dir_size_b[0]}; end
               end
               if(video_name_match) begin
                   video_found<=1;
                   video_cluster<={dir_clhi_b[1],dir_clhi_b[0],dir_cllo_b[1],dir_cllo_b[0]};
                   video_size<={sd_data,dir_size_b[2],dir_size_b[1],dir_size_b[0]};
               end
             end
           end
         end
         byte_index<=byte_index+1'b1;
       end else fail(E_SECTOR);
     end
      if(sd_end) begin
       sd_read<=0;
       // Require an exact, separate end marker. Fatal length/end conditions
       // take priority over the normal transition into a sector gap.
       if(sd_valid || byte_index!=512) fail(E_SECTOR);
       else if(state==S_READ_BOOT) begin gap_count<=3; state<=S_GAP_BOOT; end
       else if(state==S_READ_FAT) begin
         gap_count<=3; state<=S_GAP_FAT;
       end else begin gap_count<=3; state<=S_GAP_ROOT; end
      end
     end
   end
   S_GAP_BOOT: if(gap_count!=0) gap_count<=gap_count-1'b1; else if(signature_lo!=8'h55 || signature_hi!=8'haa) fail(E_SECTOR); else state<=S_BPB_PREP0;
   // Spread BPB geometry over several clocks. This keeps wide adds and the
   // cluster-count comparison out of the sector-end control path.
   S_BPB_PREP0: begin
     fat_area_end_p0<={18'd0,reserved_hi,reserved_lo}+{1'b0,fat_span};
     state<=S_BPB_PREP1;
   end
   S_BPB_PREP1: begin
     data_lba_p1<={2'b0,(is_mbr?selected_start:32'd0)}+fat_area_end_p0;
     state<=S_BPB_PREP2;
   end
   S_BPB_PREP2: begin
     cluster_count_p2<=data_sector_count_p1>>spc_shift_calc;
     fat_lba_p2<=fat_lba_base_p1+active_fat_offset_p0;
     root_lba_p2<={2'b0,data_lba_p1}+{1'b0,root_sector_offset};
     state<=S_BPB_CHECK;
   end
   S_BPB_CHECK: begin
     // A valid superfloppy BPB at LBA0 wins over incidental partition-table bytes.
     // MBR partition parsing is allowed only at LBA0 and after the BPB candidate fails.
     if(!is_mbr && !bpb_header_candidate && partition_found) begin
       if(selected_start==0 || selected_size==0 ||
          ({1'b0,selected_start}+{1'b0,selected_size})>33'h100000000) fail(E_RANGE);
       else begin
         is_mbr<=1;
         issue_sector(S_READ_BOOT,selected_start);
       end
     end else if(!bps_fixed_valid || spc==0 || (spc & (spc-1'b1))!=0 || spc>128 || reserved32==0 ||
                 (fats!=1 && fats!=2) || !rootent_fixed_valid || !fat16_fixed_valid ||
                 !version_fixed_valid || total32==0) fail(E_BPB);
     else if(volume_end_p0>64'h0000000100000000 || (is_mbr && partition_end_p0>64'h0000000100000000)) fail(E_RANGE);
     else if(fatsz32==0 || root_cluster_masked<2 || fat_area_end_p0>=total32 ||
             cluster_count_p2<65525 || cluster_count_p2>32'h0ffffff5 ||
             root_cluster_masked>cluster_count_p2+1 || fat_capacity_p0<cluster_count_p2+2 ||
             (is_mbr && total32>selected_size) || (extflags&16'h0070)!=0 ||
             ((extflags&16'h0080)!=0 && (extflags&16'h000f)>=fats) ||
             fat_lba_p2>64'h00000000ffffffff || data_lba_p1>64'h00000000ffffffff ||
             root_lba_p2>64'h00000000ffffffff) fail(E_BPB);
     else begin
       sectors_per_cluster_shift<=spc_shift_calc;
       cluster_count<=cluster_count_p2[31:0]; fat_lba<=fat_lba_p2[31:0]; data_lba<=data_lba_p1[31:0];
       current_root_cluster<=root_cluster_masked; root_clusters_read<=1;
       root_sector_in_cluster<=0; root_end_marker<=0;
       issue_sector(S_READ_ROOT,root_lba_p2[31:0]);
     end
   end
    S_GAP_FAT: if(gap_count!=0) gap_count<=gap_count-1'b1; else begin
      if((fat_entry_value & 32'h0fffffff)>=32'h0ffffff8) begin state<=S_DONE; ready<=1; end
      else if((fat_entry_value & 32'h0fffffff)<2 || (fat_entry_value & 32'h0fffffff)==32'h0ffffff7 || (fat_entry_value & 32'h0fffffff)>=32'h0ffffff0 || (fat_entry_value & 32'h0fffffff)>cluster_count+1 || root_clusters_read>=MAX_ROOT_CLUSTERS) fail(root_clusters_read>=MAX_ROOT_CLUSTERS?E_ROOT_LIMIT:E_FAT);
      else begin
        current_root_cluster<=fat_entry_value & 32'h0fffffff; root_clusters_read<=root_clusters_read+1'b1;
        root_sector_in_cluster<=0; root_end_marker<=0;
        issue_sector(S_READ_ROOT,data_lba+(((fat_entry_value & 32'h0fffffff)-2)<<sectors_per_cluster_shift));
      end
    end
    S_GAP_ROOT: if(gap_count!=0) gap_count<=gap_count-1'b1; else if(root_end_marker) begin state<=S_DONE; ready<=1; end
    else if(root_sector_in_cluster+1 < (1<<sectors_per_cluster_shift)) begin
      root_sector_in_cluster<=root_sector_in_cluster+1'b1;
      issue_sector(S_READ_ROOT,sd_addr+1'b1);
    end else begin
      fat_entry_value<=0;
      fat_offset<={current_root_cluster[6:0],2'b00};
      issue_sector(S_READ_FAT,fat_lba+((current_root_cluster*4)>>9));
    end
   S_DONE: begin sd_read<=0; ready<=1; end
   S_FAIL: begin sd_read<=0; error<=1; end
   default: fail(E_BPB);
   endcase
 end
end
endmodule
