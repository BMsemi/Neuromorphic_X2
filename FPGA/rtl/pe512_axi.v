`timescale 1ns/1ps
// Single-outstanding AXI-Lite adapter. The only command/response FIFOs are in pe.
module pe512_axi (
 (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK", X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET aresetn" *) input wire aclk,
 (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST", X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *) input wire aresetn,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *) input wire [15:0] s_axi_awaddr,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWPROT" *) input wire [2:0] s_axi_awprot,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *) input wire s_axi_awvalid,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *) output wire s_axi_awready,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *) input wire [31:0] s_axi_wdata,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *) input wire [3:0] s_axi_wstrb,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *) input wire s_axi_wvalid,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *) output wire s_axi_wready,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *) output reg [1:0] s_axi_bresp,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *) output reg s_axi_bvalid,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *) input wire s_axi_bready,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *) input wire [15:0] s_axi_araddr,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARPROT" *) input wire [2:0] s_axi_arprot,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *) input wire s_axi_arvalid,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *) output wire s_axi_arready,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *) output reg [31:0] s_axi_rdata,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *) output reg [1:0] s_axi_rresp,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *) output reg s_axi_rvalid,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *) input wire s_axi_rready
);
 reg aw_pending,w_pending;
 reg [15:0] awaddr;
 reg [31:0] wdata;
 reg [3:0] wstrb;
 reg soft_reset,auto_drain;
 reg [12:0] prog_addr;
 reg [8:0] l2_addr;
 reg [31:0] last_response;
 wire cmd_ready,prog_ready,rsp_valid,rsp_ready,l2_clear_ready,l2_clearing;
 wire init_done,configured,busy;
 wire [31:0] rsp_data,l2_data,launch_count,responses_read,discarded,l2_words;
 wire [5:0] cmd_count,rsp_count;
 wire [3:0] error_code;
 wire commit=aw_pending && w_pending && !s_axi_bvalid && !soft_reset;
 reg write_ok;
 always @* begin
   write_ok=0;
   if(wstrb==4'hf) case(awaddr)
     16'h00: write_ok=(wdata[31:4]==0) &&
         ((!wdata[0] && (!wdata[2] || l2_clear_ready) &&
          (!wdata[3] || (rsp_valid && !l2_clearing && !auto_drain && !wdata[1] && !wdata[2]))) || wdata==1);
     16'h10: write_ok=cmd_ready;
     16'h14: write_ok=wdata<8192;
     16'h18: write_ok=prog_ready;
     16'h20: write_ok=wdata<512;
     default: write_ok=0;
   endcase
 end
 wire wr=commit && write_ok;
 wire control=wr && awaddr==0;
 wire step=control && wdata[3];
 assign s_axi_awready=aresetn && !aw_pending && !s_axi_bvalid;
 assign s_axi_wready=aresetn && !w_pending && !s_axi_bvalid;
 assign s_axi_arready=aresetn && !s_axi_rvalid;
 pe512_system pe (
  .clk(aclk),.rst(!aresetn || soft_reset),
  // Keep these request paths independent of control-register readiness.
  // A common write_ok mux creates a structural ready/valid timing loop.
  .cmd_valid(commit && wstrb==15 && awaddr==16'h10 && cmd_ready),.cmd_ready(cmd_ready),.cmd_data(wdata),
  .prog_valid(commit && wstrb==15 && awaddr==16'h18 && prog_ready),.prog_ready(prog_ready),.prog_addr(prog_addr),.prog_data(wdata),
  .drain_enable(auto_drain || step),.response_valid(rsp_valid),.response_ready(rsp_ready),.response_data(rsp_data),
  .l2_clear_valid(control && wdata[2]),.l2_clear_ready(l2_clear_ready),
  .l2_read_addr(l2_addr),.l2_read_data(l2_data),.l2_clearing(l2_clearing),.l2_compute_words(l2_words),
  .init_done(init_done),.configured(configured),.busy(busy),.command_count(cmd_count),.response_count(rsp_count),
  .launch_count(launch_count),.responses_read(responses_read),.responses_discarded(discarded),.error_code(error_code));
 always @(posedge aclk) begin
  if(!aresetn) begin
   aw_pending<=0;w_pending<=0;awaddr<=0;wdata<=0;wstrb<=0;
   s_axi_bvalid<=0;s_axi_bresp<=0;s_axi_rvalid<=0;s_axi_rresp<=0;s_axi_rdata<=0;
   soft_reset<=0;auto_drain<=0;prog_addr<=0;l2_addr<=0;last_response<=0;
  end else begin
   soft_reset<=0;
   if(s_axi_awvalid && s_axi_awready) begin aw_pending<=1;awaddr<=s_axi_awaddr;end
   if(s_axi_wvalid && s_axi_wready) begin w_pending<=1;wdata<=s_axi_wdata;wstrb<=s_axi_wstrb;end
   if(s_axi_bvalid && s_axi_bready) s_axi_bvalid<=0;
   if(commit) begin
    aw_pending<=0;w_pending<=0;s_axi_bvalid<=1;s_axi_bresp<=write_ok ? 0:2;
    if(wr) case(awaddr)
     16'h00: begin soft_reset<=wdata[0];auto_drain<=wdata[1]; if(wdata[0]) last_response<=0;end
     16'h14: prog_addr<=wdata[12:0];
     16'h18: prog_addr<=prog_addr+1'b1;
     16'h20: l2_addr<=wdata[8:0];
    endcase
   end
   if(rsp_valid && rsp_ready) last_response<=rsp_data;
   if(s_axi_rvalid && s_axi_rready) s_axi_rvalid<=0;
   if(s_axi_arvalid && s_axi_arready) begin
    s_axi_rvalid<=1;s_axi_rresp<=0;
    case(s_axi_araddr)
     16'h00: s_axi_rdata<={30'b0,auto_drain,1'b0};
     16'h04: s_axi_rdata<={23'b0,auto_drain,l2_clear_ready,l2_clearing,rsp_valid,prog_ready,cmd_ready,busy,configured,init_done};
     16'h08: s_axi_rdata<={18'b0,rsp_count,2'b0,cmd_count};
     16'h0c: s_axi_rdata<={28'b0,error_code};
     16'h14: s_axi_rdata<={19'b0,prog_addr};
     16'h1c: s_axi_rdata<=rsp_data;
     16'h20: s_axi_rdata<={23'b0,l2_addr};
     16'h24: s_axi_rdata<=l2_data;
     16'h28: s_axi_rdata<=launch_count;
     16'h2c: s_axi_rdata<=responses_read;
     16'h30: s_axi_rdata<=discarded;
     16'h34: s_axi_rdata<=l2_words;
     16'h38: s_axi_rdata<=32'h53503531;
     16'h3c: s_axi_rdata<=32'h00010000;
     16'h40: s_axi_rdata<=last_response;
     default: begin s_axi_rdata<=0;s_axi_rresp<=2;end
    endcase
   end
  end
 end
endmodule
