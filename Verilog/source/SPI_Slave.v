///////////////////////////////////////////////////////////////////////////////
// Description: SPI (Serial Peripheral Interface) Slave
//              Creates slave based on input configuration.
//              Receives a byte one bit at a time on MOSI
//              Will also push out byte data one bit at a time on MISO.  
//              Any data on input byte will be shipped out on MISO.
//              Supports multiple bytes per transaction when CS_n is kept 
//              low during the transaction.
//
// Note:        i_Clk must be at least 4x faster than i_SPI_Clk
//              MISO is tri-stated when not communicating.  Allows for multiple
//              SPI Slaves on the same interface.
//
// Parameters:  SPI_MODE, can be 0, 1, 2, or 3.  See above.
//              Can be configured in one of 4 modes:
//              Mode | Clock Polarity (CPOL/CKP) | Clock Phase (CPHA)
//               0   |             0             |        0
//               1   |             0             |        1
//               2   |             1             |        0
//               3   |             1             |        1
//              More info: https://en.wikipedia.org/wiki/Serial_Peripheral_Interface_Bus#Mode_numbers
///////////////////////////////////////////////////////////////////////////////

module SPI_Slave
  #(parameter SPI_MODE = 0)
  (
   // Control/Data Signals,
   input             i_Rst_L,    // FPGA Reset
   input             i_Clk,      // FPGA Clock
   output reg        o_RX_DV,    // Data Valid pulse (1 clock cycle)
   output reg [7:0]  o_RX_Byte,  // 1 Byte received on MOSI
   input             i_TX_DV,    // Data Valid pulse to register i_TX_Byte
   input  [15:0]     i_TX_Byte,  // 2 Bytes to serialize to MISO.

   // SPI Interface
   input       i_SPI_Clk,
   output wire o_SPI_MISO,
   input       i_SPI_MOSI,
   input       i_SPI_CS_n
   );


  // SPI Interface (All Runs at SPI Clock Domain)
  wire w_CPOL;     // Clock polarity
  wire w_CPHA;     // Clock phase
  wire w_SPI_Clk;  // Inverted/non-inverted depending on settings
  wire w_SPI_MISO_Mux;
  
  reg [3:0]  r_RX_Bit_Count;
  reg [3:0]  r_TX_Bit_Count;     // 16-bit output register requires counting to 15
  reg [7:0]  r_Temp_RX_Byte;
  reg [7:0]  r_RX_Byte;
  reg        r_RX_Done;
  reg [2:0]  r_RX_Done_Clk;
  reg [15:0] r_TX_Byte;
  reg r_SPI_MISO_Bit, r_Preload_MISO;

  // CPOL: Clock Polarity
  // CPOL=0 means clock idles at 0, leading edge is rising edge.
  // CPOL=1 means clock idles at 1, leading edge is falling edge.
  assign w_CPOL  = (SPI_MODE == 2) | (SPI_MODE == 3);

  // CPHA: Clock Phase
  // CPHA=0 means the "out" side changes the data on trailing edge of clock
  //              the "in" side captures data on leading edge of clock
  // CPHA=1 means the "out" side changes the data on leading edge of clock
  //              the "in" side captures data on the trailing edge of clock
  assign w_CPHA  = (SPI_MODE == 1) | (SPI_MODE == 3);

  assign w_SPI_Clk = w_CPHA ? ~i_SPI_Clk : i_SPI_Clk;



  // Purpose: Recover SPI Byte in SPI Clock Domain
  // Samples line on correct edge of SPI Clock
  always @(posedge w_SPI_Clk or posedge i_SPI_CS_n) begin
    if (i_SPI_CS_n) begin
      r_RX_Bit_Count <= 0;
      r_RX_Done      <= 1'b0;
      r_RX_Byte      <= 8'h00;
    end
    else begin
      r_RX_Bit_Count <= r_RX_Bit_Count + 1;

      // Receive in LSB, shift up to MSB
      r_Temp_RX_Byte <= {r_Temp_RX_Byte[6:0], i_SPI_MOSI};
    
      // TODO: Either receive one byte or 2 bytes
      if (r_RX_Bit_Count == 3'b111) begin
        r_RX_Done <= 1'b1;
        r_RX_Byte <= {r_Temp_RX_Byte[6:0], i_SPI_MOSI};
      end
    end // else: !if(i_SPI_CS_n)
  end // always @(posedge w_SPI_Clk or posedge i_SPI_CS_n)


  // Purpose: Cross from SPI Clock Domain to main FPGA clock domain
  // Assert o_RX_DV for 1 clock cycle when o_RX_Byte has valid data.
  always @(posedge i_Clk or negedge i_Rst_L) begin
    if (~i_Rst_L) begin
      o_RX_DV    <= 1'b0;
      o_RX_Byte  <= 8'h00;
      r_RX_Done_Clk <= 3'b000;
    end
    else begin
      // RX_Done needs to moved to the FPGA clock domain, to do this, we will
      // shift it through two flip-flops (the 3rd is for edge detection)
      r_RX_Done_Clk <= {r_RX_Done_Clk[2:1], r_RX_Done};

      if (r_RX_Done_Clk[2:1] == 2'b01) begin // rising edge
        o_RX_DV   <= 1'b1;  // Pulse Data Valid 1 clock cycle
        o_RX_Byte <= r_RX_Byte;
      end
      else begin
        o_RX_DV <= 1'b0;
      end
    end // else: !if(~i_Rst_L)
  end // always @(posedge i_Bus_Clk or negedge i_Rst_L)


  // Control preload signal.  Should be 1 when CS is high, but as soon as
  // first clock edge is seen it goes low.
  always @(posedge w_SPI_ClK or posedge i_SPI_CS_n) begin
    if (i_SPI_CS_n) begin
      r_Preload_MISO <= 1'b1;
    end
    else begin
      r_Preload_MISO <= 1'b0;
    end
  end


  // Purpose: Transmits 1 SPI Byte whenever SPI clock is toggling
  // Will transmit read data back to SW over MISO line.
  // Want to put data on the line immediately when CS goes low.
  always @(posedge w_SPI_Clk or posedge i_SPI_CS_n) begin
    if (i_SPI_CS_n) begin
      r_TX_Bit_Count <= 5'b1111;  // Send MSB first
      r_SPI_MISO_Bit <= r_TX_Byte[5'b1111];  // Reset to MSB
    end
    else begin
      r_TX_Bit_Count <= r_TX_Bit_Count - 1;

      // Here is where data crosses clock domains from i_Clk to w_SPI_Clk
      // Can set up a timing constraint with wide margin for data path.
      r_SPI_MISO_Bit <= r_TX_Byte[r_TX_Bit_Count];
    end // else: !if(i_SPI_CS_n)
  end // always @(negedge w_SPI_Clk or posedge i_SPI_CS_n)


  // Purpose: Register TX Byte when DV pulse comes.  Keeps registered byte in
  // this module to get serialized and sent back to master.
  always @(posedge i_Clk or negedge i_Rst_L) begin
    if (~i_Rst_L) begin
      r_TX_Byte <= 16'h0000;
    end
    else begin
      if (i_TX_DV) begin
        r_TX_Byte <= i_TX_Byte; 
      end
    end // else: !if(~i_Rst_L)
  end // always @(posedge i_Clk or negedge i_Rst_L)

  // Preload MISO with top bit of send data when preload selector is high.
  // Otherwise just send the normal MISO data
  assign w_SPI_MISO_Mux = r_Preload_MISO ? r_TX_Byte[5'b1111] : r_SPI_MISO_Bit;

  // Tri-state MISO when CS is high.  Allows for multiple slaves to talk.
  assign o_SPI_MISO = i_SPI_CS_n ? 1'bZ : w_SPI_MISO_Mux;

endmodule // SPI_Slave
