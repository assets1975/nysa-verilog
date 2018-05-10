/*
Distributed under the MIT license.
Copyright (c) 2017 Dave McCoy (dave.mccoy@cospandesign.com)

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

/*
 * Author:
 * Description: AXI Master with BRAM interface
 *
 * Changes:     Who?    What?
 *  3/18/2018   DFM     Initial Commit
 */

`timescale 1ps / 1ps

`include "axi_defines.v"

`define BIT_STATUS_BUSY           0
`define BIT_STATUS_BAD_COMMAND    4
`define BIT_STATUS_BAD_TXRX_WIDTH 5
`define BIT_BUS_STATUS_RANGE      9:8

`define CLOG2(x) \
   (x <= 2)     ? 1 :  \
   (x <= 4)     ? 2 :  \
   (x <= 8)     ? 3 :  \
   (x <= 16)    ? 4 :  \
   (x <= 32)    ? 5 :  \
   (x <= 64)    ? 6 :  \
   (x <= 128)   ? 7 :  \
   (x <= 256)   ? 8 :  \
   (x <= 512)   ? 9 :  \
   (x <= 1024)  ? 10 : \
   (x <= 2048)  ? 11 : \
   (x <= 4096)  ? 12 : \
   -1

module axi_master_bram #(
  //Parameters
  parameter           INVERT_AXI_RESET        = 1,
  parameter           INTERNAL_BRAM           = 1,
  parameter           AXI_MAX_BURST_LENGTH    = 4096,
  parameter           AXI_DATA_COUNT          = `CLOG2(AXI_MAX_BURST_LENGTH),
  parameter           AXI_DATA_WIDTH          = 32,
  parameter           AXI_STROBE_WIDTH        = (AXI_DATA_WIDTH >> 3),
  parameter           AXI_ADDR_WIDTH          = 32,
  parameter           BRAM_ADDR_WIDTH         = 10,
  parameter           BRAM_DATA_WIDTH         = 32,
  parameter           DEFAULT_TIMEOUT         = 32'd100000000,  //1 Second at 100MHz
  parameter           ENABLE_NACK             = 0, //Enable timeout
//  parameter           USE_IDS               = 0,
  parameter           INTERRUPT_WIDTH         = 32
)(
input                                     i_axi_clk,
input                                     i_axi_rst,

//************* User Facing Side *******************************************
//User Facing Interface end
//indicate to the input that we are ready
output      [31:0]                        o_cmd_status,
output  reg [INTERRUPT_WIDTH - 1: 0]      o_cmd_interrupts,

input                                     i_cmd_en,
output  reg                               o_cmd_error,
output  reg                               o_cmd_ack,

//Modifier flags, these will be used to change the way address are modified when reading/writing
input       [AXI_ADDR_WIDTH - 1:0]        i_cmd_addr,
input                                     i_cmd_wr_rd,        //1 = Write, 0 = Read
input       [AXI_DATA_COUNT - 1: 0]       i_cmd_data_byte_count,

//BRAM Interface
input                                     i_int_bram_ingress_clk,
input                                     i_int_bram_ingress_wea,
input       [BRAM_ADDR_WIDTH - 1: 0]      i_int_bram_ingress_addr,
input       [BRAM_DATA_WIDTH - 1: 0]      i_int_bram_ingress_data,

input                                     i_int_bram_egress_clk,
input       [BRAM_ADDR_WIDTH - 1: 0]      i_int_bram_egress_addr,
output      [BRAM_DATA_WIDTH - 1: 0]      o_int_bram_egress_data,


output      [BRAM_ADDR_WIDTH - 1: 0]      o_ext_bram_ingress_addr,
input       [BRAM_DATA_WIDTH - 1: 0]      i_ext_bram_ingress_data,

output                                    o_ext_bram_egress_wea,
output      [BRAM_ADDR_WIDTH - 1: 0]      o_ext_bram_egress_addr,
output      [BRAM_DATA_WIDTH - 1: 0]      o_ext_bram_egress_data,




  //NOT IMPLEMENTED YET
/*
  input       [2:0]                   i_cmd_txrx_width, //0 = 8-bit, 1 = 16-bit, 16-bit, 2 = 32-bit...
  input       [3:0]                   i_cmd_aw_id,  //Add an ide to the write/command paths
  input       [3:0]                   i_cmd_w_id,
  input       [3:0]                   i_cmd_ar_id,
  output  reg [3:0]                   o_cmd_r_id,
  output  reg [3:0]                   o_cmd_b_id,
*/


//***************** AXI Bus ************************************************
//bus write addr path
output  reg [3:0]                   o_awid,         //Write ID
output      [AXI_ADDR_WIDTH - 1:0]  o_awaddr,       //Write Addr Path Address
output      [7:0]                   o_awlen,        //Write Addr Path Burst Length
output      [2:0]                   o_awsize,       //Write Addr Path Burst Size (Byte with (00 = 8 bits wide, 01 = 16 bits wide)
output      [1:0]                   o_awburst,      //Write Addr Path Burst Type
                                                        //  0 = Fixed
                                                        //  1 = Incrementing
                                                        //  2 = wrap
output      [1:0]                   o_awlock,       //Write Addr Path Lock (atomic) information
                                                        //  0 = Normal
                                                        //  1 = Exclusive
                                                        //  2 = Locked
output      [3:0]                   o_awcache,      //Write Addr Path Cache Type
output      [2:0]                   o_awprot,       //Write Addr Path Protection Type
output  reg                         o_awvalid,      //Write Addr Path Address Valid
input                               i_awready,      //Write Addr Path Slave Ready
                                                        //  1 = Slave Ready
                                                        //  0 = Slave Not Ready

//bus write data
output  reg [3:0]                   o_wid,          //Write ID
output      [AXI_DATA_WIDTH - 1: 0] o_wdata,        //Write Data (this size is set with the AXI_DATA_WIDTH Parameter
                                                      //Valid values are: 8, 16, 32, 64, 128, 256, 512, 1024
output      [AXI_STROBE_WIDTH - 1:0]o_wstrobe,      //Write Strobe (a 1 in the write is associated with the byte to write)
output                              o_wlast,        //Write Last transfer in a write burst
output                              o_wvalid,       //Data through this bus is valid
input                               i_wready,       //Slave is ready for data

//Write Response Channel
input       [3:0]                   i_bid,          //Response ID (this must match awid)
input       [1:0]                   i_bresp,        //Write Response
                                                        //  0 = OKAY
                                                        //  1 = EXOKAY
                                                        //  2 = SLVERR
                                                        //  3 = DECERR
input                               i_bvalid,       //Write Response is:
                                                        //  1 = Available
                                                        //  0 = Not Available
output  reg                         o_bready,       //WBM Ready

//bus read addr path
output  reg  [3:0]                  o_arid,         //Read ID
output       [AXI_ADDR_WIDTH - 1:0] o_araddr,       //Read Addr Path Address
output       [7:0]                  o_arlen,        //Read Addr Path Burst Length
output  reg  [2:0]                  o_arsize,       //Read Addr Path Burst Size (Byte with (00 = 8 bits wide, 01 = 16 bits wide)
output       [1:0]                  o_arburst,      //Read Addr Path Burst Type
output       [1:0]                  o_arlock,       //Read Addr Path Lock (atomic) information
output       [3:0]                  o_arcache,      //Read Addr Path Cache Type
output       [2:0]                  o_arprot,       //Read Addr Path Protection Type
output  reg                         o_arvalid,      //Read Addr Path Address Valid
input                               i_arready,      //Read Addr Path Slave Ready
                                                        //  1 = Slave Ready
                                                        //  0 = Slave Not Ready
//bus read data
input       [3:0]                   i_rid,          //Write ID
input       [AXI_DATA_WIDTH - 1: 0] i_rdata,        //Read Data (this size is set with the AXI_DATA_WIDTH Parameter
                                                    //Valid values are: 8, 16, 32, 64, 128, 256, 512, 1024
input       [1:0]                   i_rresp,        //Read Response
                                                        //  0 = OKAY
                                                        //  1 = EXOKAY
                                                        //  2 = SLVERR
                                                        //  3 = DECERR
input       [AXI_STROBE_WIDTH - 1:0]i_rstrobe,      //Read Strobe (a 1 in the write is associated with the byte to write)
input                               i_rlast,        //Read Last transfer in a write burst
input                               i_rvalid,       //Data through this bus is valid
//output  reg                         o_rready,       //WBM is ready for data
output                              o_rready,       //WBM is ready for data
                                                        //  1 = WBM Ready
                                                        //  0 = Slave Ready

input     [INTERRUPT_WIDTH - 1:0]   i_interrupts

);
//local parameters

//States
localparam        IDLE                  = 4'h0;

localparam        WRITE_CMD             = 4'h1; //Write Command and Address to Slave
localparam        WRITE_DATA            = 4'h2; //Write Data to Slave
localparam        WRITE_RESP            = 4'h3; //Receive Response from device

localparam        READ_CMD              = 4'h4; //Send Read Command and Address to Slave
localparam        READ_DATA             = 4'h5; //Receive Read Response from Slave (including data)
localparam        READ_RESP             = 4'h6;
localparam        COMMAND_FINISHED      = 4'h7;

localparam        SEND_INTERRUPT        = 5'h8;


//registes/wires
wire                            w_axi_rst;
reg   [3:0]                     state = IDLE;
wire  [15:0]                    w_flags;
reg   [AXI_DATA_COUNT - 1: 0]   r_data_count;
reg   [AXI_ADDR_WIDTH - 1:0]    r_addr;
reg   [7:0]                     r_byte_data_len;
reg                             r_data_wr_en;
reg                             r_data_rd_en;
wire                            w_a2b_ack;
wire                            w_b2a_ack;

wire  [BRAM_DATA_WIDTH - 1:0]   w_bram_ingress_data;
wire  [BRAM_ADDR_WIDTH - 1:0]   w_bram_ingress_addr;
wire                            w_bram_ingress_wea;

wire                            w_bram_egress_wea;
wire  [BRAM_DATA_WIDTH - 1:0]   w_bram_egress_data;
wire  [BRAM_ADDR_WIDTH - 1:0]   w_bram_egress_addr;

reg   [INTERRUPT_WIDTH - 1:0]   r_prev_int = 0;
reg                             r_bad_command = 0;
reg                             r_bus_status;
reg                             r_bad_txrx_width;


//submodules
bram_to_axis #(
  .BRAM_DATA_WIDTH       (BRAM_DATA_WIDTH         ),
  .BRAM_ADDR_WIDTH       (BRAM_ADDR_WIDTH         ),
  .AXI_DATA_WIDTH        (AXI_DATA_WIDTH          ),
  .AXI_MAX_BURST_LENGTH  (AXI_MAX_BURST_LENGTH    )
) b2a (
  .clk                   (i_axi_clk               ),
  .rst                   (i_axi_rst               ),

  .i_byte_write_size     (i_cmd_data_byte_count   ),
  .i_en                  (r_data_wr_en            ),
  .o_ack                 (w_b2a_ack               ),

//  .i_bram_data_valid     (i_bram_data_valid       ),
  .i_bram_data           (w_bram_ingress_data     ),
  .o_bram_addr           (w_bram_ingress_addr     ),
//  .i_bram_size           (i_bram_size             ),

  .o_axis_valid          (o_wvalid                ),
  .i_axis_ready          (i_wready                ),
  .o_axis_data           (o_wdata                 ),
  .o_axis_strobe         (o_wstrobe               )
);

axis_to_bram #(
  .BRAM_DATA_WIDTH       (BRAM_DATA_WIDTH         ),
  .BRAM_ADDR_WIDTH       (BRAM_ADDR_WIDTH         ),
  .AXI_DATA_WIDTH        (AXI_DATA_WIDTH          ),
  .AXI_STROBE_WIDTH      (AXI_STROBE_WIDTH        ),
  .AXI_MAX_BURST_LENGTH  (AXI_MAX_BURST_LENGTH    )
) a2b (
  .clk                   (i_axi_clk               ),
  .rst                   (i_axi_clk               ),

  .i_byte_read_size      (i_cmd_data_byte_count   ),
  .i_en                  (r_data_rd_en            ),
  .o_ack                 (w_a2b_ack               ),

//  .i_bram_size           (i_bram_size             ),
  .o_bram_data           (w_bram_egress_data      ),
  .o_bram_addr           (w_bram_egress_addr      ),
  .o_bram_wea            (w_bram_egress_wea       ),

  .i_axis_valid          (i_rvalid                ),
  .o_axis_ready          (o_rready                ),
  .i_axis_data           (i_rdata                 ),
  .i_axis_strobe         (i_rstrobe               )

);

//asynchronous logic
assign  w_axi_rst = (INVERT_AXI_RESET) ? !i_axi_rst : i_axi_rst;

assign  o_awlock  = 0;
assign  o_awburst = `AXI_BURST_INCR; //Don't support fixed or wrapped
assign  o_arlock  = 0;
assign  o_arburst = `AXI_BURST_INCR; //Don't support fixed or wrapped
assign  o_awcache = {`AXI_CACHE_NON_WA, `AXI_CACHE_NON_RA, `AXI_CACHE_CACHE, `AXI_CACHE_BUF};
assign  o_arcache = {`AXI_CACHE_NON_WA, `AXI_CACHE_NON_RA, `AXI_CACHE_CACHE, `AXI_CACHE_BUF};

assign  o_cmd_status[`BIT_STATUS_BUSY]            = (state != IDLE);
assign  o_cmd_status[3:1]                         = 0;
assign  o_cmd_status[`BIT_STATUS_BAD_COMMAND]     = r_bad_command;
assign  o_cmd_status[`BIT_STATUS_BAD_TXRX_WIDTH]  = r_bad_txrx_width;
assign  o_cmd_status[7:6]                         = 0;
assign  o_cmd_status[`BIT_BUS_STATUS_RANGE]       = r_bus_status;
assign  o_cmd_status[9:8]                         = 0;
assign  o_cmd_status[31:6]                        = 0;

assign  o_awsize      = (AXI_DATA_WIDTH == 8    ) ? `AXI_BURST_SIZE_8BIT    :
                        (AXI_DATA_WIDTH == 16   ) ? `AXI_BURST_SIZE_16BIT   :
                        (AXI_DATA_WIDTH == 32   ) ? `AXI_BURST_SIZE_32BIT   :
                        (AXI_DATA_WIDTH == 64   ) ? `AXI_BURST_SIZE_64BIT   :
                        (AXI_DATA_WIDTH == 128  ) ? `AXI_BURST_SIZE_128BIT  :
                        (AXI_DATA_WIDTH == 256  ) ? `AXI_BURST_SIZE_256BIT  :
                        (AXI_DATA_WIDTH == 512  ) ? `AXI_BURST_SIZE_512BIT  :
                        (AXI_DATA_WIDTH == 1024 ) ? `AXI_BURST_SIZE_1024BIT :
                        3'bxxx; //Shouldn't get here


assign  o_awaddr  = r_addr;
assign  o_araddr  = r_addr;
assign  o_awlen   = r_byte_data_len;
assign  o_arlen   = r_byte_data_len;

if (INTERNAL_BRAM) begin
blk_mem #(
  .DATA_WIDTH                  (BRAM_DATA_WIDTH             ),
  .ADDRESS_WIDTH               (BRAM_ADDR_WIDTH             )
) ingress_bram (
  .clka                        (i_int_bram_ingress_clk      ),
  .addra                       (i_int_bram_ingress_addr     ),
  .dina                        (i_int_bram_ingress_data     ),
  .wea                         (i_int_bram_ingress_wea      ),

  .clkb                        (i_axi_clk                   ),
  .addrb                       (w_bram_ingress_addr         ),
  .doutb                       (w_bram_ingress_data         )
);

blk_mem #(
  .DATA_WIDTH                  (BRAM_DATA_WIDTH             ),
  .ADDRESS_WIDTH               (BRAM_ADDR_WIDTH             )
) egress_bram (
  .clka                        (i_axi_clk                   ),
  .addra                       (w_bram_egress_addr          ),
  .dina                        (w_bram_egress_data          ),
  .wea                         (w_bram_egress_wea           ),

  .clkb                        (i_int_bram_egress_clk       ),
  .addrb                       (i_int_bram_egress_addr      ),
  .doutb                       (o_int_bram_egress_data      )
);
end
else begin

assign  w_bram_ingress_data     = i_ext_bram_ingress_data;
assign  o_ext_bram_ingress_addr = w_bram_ingress_addr;

assign  o_ext_bram_egress_wea   = w_bram_egress_wea;
assign  o_ext_bram_egress_addr  = w_bram_egress_addr;
assign  o_ext_bram_egress_data  = w_bram_egress_data;

end

//synchronous logic
always @ (posedge i_axi_clk) begin
  o_cmd_ack             <=  0;
  if (w_axi_rst) begin
    r_data_count        <=  0;
    r_addr              <=  0;
    r_byte_data_len     <=  0;
    r_data_wr_en        <=  0;
    r_data_rd_en        <=  0;
    r_bad_command       <=  0;
    r_bus_status        <=  0;
    r_bad_txrx_width    <=  0;
    r_prev_int          <=  0;
    o_cmd_interrupts    <=  0;
    o_cmd_error         <=  0;
  end
  else begin
    case (state)
      IDLE: begin
        r_data_count    <=  0;
        r_addr          <=  i_cmd_addr;
        if (i_cmd_en) begin
          r_byte_data_len   <=  i_cmd_data_byte_count - 1;
          r_byte_data_len   <=  i_cmd_data_byte_count - 1;
          if (i_cmd_wr_rd) begin
            state           <=  WRITE_CMD;
          end
          else begin
            state           <=  READ_CMD;
          end
        end
        else if ((~r_prev_int & i_interrupts) > 0) begin
          state             <=  SEND_INTERRUPT;
          o_cmd_interrupts  <=  0;
        end
      end

      //Write Path
      WRITE_CMD: begin
        o_awid              <=  0;
        o_wid               <=  0;
        o_awvalid           <=  1;
        if (i_awready && o_awvalid) begin
          o_awvalid         <=  0;
          state             <=  WRITE_DATA;
        end
      end
      WRITE_DATA: begin
        r_data_wr_en        <=  1;
        if (w_b2a_ack) begin
          r_data_wr_en      <=  0;
          state             <=  WRITE_RESP;
        end
      end
      WRITE_RESP: begin
        o_bready            <=  1;
        if ((o_awid == i_bid) && i_bvalid) begin
          r_bus_status      <=  i_bresp;
          if (r_bus_status != 0) begin
            o_cmd_error     <=  1;
          end
          state             <=  COMMAND_FINISHED;
        end
      end

      //Read Path
      READ_CMD: begin
        o_arid              <=  0;
        o_arvalid           <=  1;
        if (i_arready && o_arvalid) begin
          o_arvalid         <=  0;
          state             <=  READ_DATA;
        end
      end
      READ_DATA: begin
        if (i_rid == o_arid) begin
          r_data_rd_en      <=  1;
          if (w_a2b_ack) begin
            r_data_rd_en    <=  0;
            state           <=  COMMAND_FINISHED;
          end
        end
      end

      COMMAND_FINISHED: begin
        o_cmd_ack           <=  1;
        if (!i_cmd_en) begin
          state             <=  IDLE;
        end
      end
      SEND_INTERRUPT: begin
      end
      default: begin
        state               <=  IDLE;
      end
    endcase

    r_prev_int  <=  i_interrupts;
  end
end



endmodule