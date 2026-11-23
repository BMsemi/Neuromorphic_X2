`timescale 1ns/1ps
module tb_pe512_axi;
 reg clk=0; always #5 clk=~clk;
 reg rstn=0;
 reg [15:0] awaddr=0,araddr=0;
 reg [31:0] wdata=0;
 reg [3:0] wstrb=15;
 reg awvalid=0,wvalid=0,bready=0,arvalid=0,rready=0;
 wire awready,wready,bvalid,arready,rvalid;
 wire [1:0] bresp,rresp;
 wire [31:0] rdata;
 pe512_axi dut(.aclk(clk),.aresetn(rstn),
  .s_axi_awaddr(awaddr),.s_axi_awprot(3'b0),.s_axi_awvalid(awvalid),.s_axi_awready(awready),
  .s_axi_wdata(wdata),.s_axi_wstrb(wstrb),.s_axi_wvalid(wvalid),.s_axi_wready(wready),
  .s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(bready),
  .s_axi_araddr(araddr),.s_axi_arprot(3'b0),.s_axi_arvalid(arvalid),.s_axi_arready(arready),
  .s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rvalid(rvalid),.s_axi_rready(rready));
 task send_aw(input [15:0] addr);
 begin @(negedge clk);awaddr=addr;awvalid=1;
  do @(posedge clk); while(!awready);
  @(negedge clk);awvalid=0;
 end endtask
 task send_w(input [31:0] data,input [3:0] strobe);
 begin @(negedge clk);wdata=data;wstrb=strobe;wvalid=1;
  do @(posedge clk); while(!wready);
  @(negedge clk);wvalid=0;
 end endtask
 task write_reg(input [15:0] addr,input [31:0] data,input integer order,input [3:0] strobe,input [1:0] response);
 begin
  if(order==0) begin send_aw(addr);repeat(3) @(posedge clk);send_w(data,strobe);end
  else begin send_w(data,strobe);repeat(3) @(posedge clk);send_aw(addr);end
  wait(bvalid); #1;
  repeat(4) begin @(negedge clk);if(!bvalid || bresp!==response) $fatal(1,"B response unstable/incorrect %h",addr);end
  bready=1;@(negedge clk);bready=0;
 end endtask
 task read_reg(input [15:0] addr,output [31:0] data,input [1:0] response);
 begin
  @(negedge clk);araddr=addr;arvalid=1;
  do @(posedge clk); while(!arready);
  @(negedge clk);arvalid=0;wait(rvalid);#1;data=rdata;
  repeat(4) begin @(negedge clk);if(!rvalid || rdata!==data || rresp!==response) $fatal(1,"R response unstable/incorrect");end
  rready=1;@(negedge clk);rready=0;
 end endtask
 reg [31:0] value;
 integer i;
 initial begin
  repeat(4) @(negedge clk);rstn=1;
  read_reg(56,value,0);if(value!==32'h53503531) $fatal(1,"magic");
  write_reg(32,99,0,15,0);read_reg(32,value,0);if(value!=99) $fatal;
  write_reg(32,123,1,15,0);read_reg(32,value,0);if(value!=123) $fatal;
  write_reg(32,7,0,1,2);read_reg(32,value,0);if(value!=123) $fatal(1,"partial write changed register");
  write_reg(33,7,1,15,2);read_reg(16'hfffc,value,2);
  repeat(8200) @(posedge clk);
  write_reg(16,32'ha203c40f,0,15,0);
  write_reg(16,32'h0f030d43,1,15,0);
  write_reg(16,32'h42000c03,0,15,0);
  write_reg(20,0,1,15,0);
  write_reg(24,32'hffffffff,0,15,0);
  write_reg(16,32'h80000601,1,15,0); // one active row, final/full bank
  repeat(150) @(posedge clk);
  read_reg(8,value,0);if(value!=8192) $fatal(1,"response bank not full");
  for(i=0;i<32;i=i+1) write_reg(16,32'h80000400 | (i<<21),i%2,15,0);
  read_reg(8,value,0);if(value!=8224) $fatal(1,"command queue not full");
  write_reg(16,32'h80000601,0,15,2); // full command queue must reject
  write_reg(24,0,0,15,2); // programming while outputs pending must reject
  for(i=0;i<31;i=i+1) begin
   write_reg(0,8,i%2,15,0);read_reg(64,value,0);
   if(value!==(32'h01000001 | (i<<14))) $fatal(1,"raw response mismatch");
  end
  read_reg(40,value,0);if(value!=1) $fatal(1,"premature tile launch");
  read_reg(8,value,0);if(value!=288) $fatal(1,"lost queued command / last response");
  write_reg(0,8,1,15,0);
  repeat(200) @(posedge clk);
  read_reg(40,value,0);if(value!=2) $fatal(1,"next tile never launched");
  write_reg(0,2,0,15,0);repeat(60) @(posedge clk);
  read_reg(44,value,0);if(value!=64) $fatal(1,"automatic drain");
  write_reg(32,0,0,15,0);read_reg(36,value,0);if(value!=1) $fatal(1,"L2 sum");
  read_reg(48,value,0);if(value!=0) $fatal(1,"discarded responses");
  $display("ALL_AXI_SHARED_PE_TESTS_PASSED");$finish;
 end
 initial begin #2000000;$fatal(1,"timeout");end
endmodule
