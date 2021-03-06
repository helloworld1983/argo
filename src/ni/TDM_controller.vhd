--
-- Copyright Technical University of Denmark. All rights reserved.
-- This file is part of the T-CREST project.
--
-- Redistribution and use in source and binary forms, with or without
-- modification, are permitted provided that the following conditions are met:
--
--    1. Redistributions of source code must retain the above copyright notice,
--       this list of conditions and the following disclaimer.
--
--    2. Redistributions in binary form must reproduce the above copyright
--       notice, this list of conditions and the following disclaimer in the
--       documentation and/or other materials provided with the distribution.
--
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDER ``AS IS'' AND ANY EXPRESS
-- OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
-- OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN
-- NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY
-- DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
-- (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
-- LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
-- ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
-- (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
-- THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
--
-- The views and conclusions contained in the software and documentation are
-- those of the authors and should not be interpreted as representing official
-- policies, either expressed or implied, of the copyright holder.
--


--------------------------------------------------------------------------------
-- Argo 2.0 Network Interface: The TDM controller of the NI
--
-- Author: Rasmus Bo Soerensen (rasmus@rbscloud.dk)
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.argo_types.all;
use work.math_util.all;
use work.ocp.all;

entity TDM_controller is
  generic (
    MASTER : boolean := true
  );
  port (
    -- Clock reset and run
    clk   : in std_logic;
    reset   : in std_logic;
    run     : in std_logic;
    master_run : out std_logic;
    -- Read write interface from config bus
    config  : in conf_if_master;
    sel   : in std_logic;
    config_slv : out conf_if_slave;
    -- Interface to schedule table
    stbl_idx  : out stbl_idx_t;
    stbl_idx_en  : out std_logic;
    t2n   : in stbl_t2n_t;
    -- Interface towards mode change controller
    period_boundary : out std_logic;
    mc_p_cnt : out unsigned(1 downto 0);
    stbl_min : in unsigned(STBL_IDX_WIDTH-1 downto 0);
    stbl_maxp1 : in unsigned(STBL_IDX_WIDTH-1 downto 0)
  );
end TDM_controller;

architecture rtl of TDM_controller is
--------------------------------------------------------------------------------
-- Addresses of readable/writable registers (Word based addresses inside the NI)
-- Address  | Access  | Name
--------------------------------------------------------------------------------
-- 0x00     | R       | TDM_S_CNT
-- 0x01     | R       | TDM_P_CNT
-- 0x02     | R       | CLOCK_CNT_HIGH
-- 0x03     | R       | CLOCK_CNT_LOW
-- 0x04     | WR      | Master run
-- ...      |         | ...
--------------------------------------------------------------------------------
  
  signal TDM_S_CNT_reg : unsigned(TDM_S_CNT_WIDTH-1 downto 0);
  signal TDM_P_CNT_reg : word_t;
    
  signal STBL_IDX_reg : unsigned(STBL_IDX_WIDTH-1 downto 0);
  signal STBL_IDX_next : unsigned(STBL_IDX_WIDTH-1 downto 0);
  signal TIME2NEXT_reg : unsigned(STBL_T2N_WIDTH-1 downto 0);
  signal CLOCK_CNT_HI_reg : word_t;
  signal CLOCK_CNT_LO_reg : word_t;

  signal MASTER_RUN_NEXT : std_logic_vector(0 downto 0);

  signal mc_p_cnt_reg : unsigned(1 downto 0);

--  signal MODE_CHANGE_IDX_reg, MODE_CHANGE_IDX_next : unsigned(log2up(MAX_MODE_CHANGE)-1 downto 0);
--  type mode_change_t is record 
--    min : unsigned(STBL_IDX_WIDTH-1 downto 0);
--    max : unsigned(STBL_IDX_WIDTH-1 downto 0);
--  end record;
--  type mc_array is array (log2up(MAX_MODE_CHANGE)-1 downto 0) of mode_change_t;
--  signal MODE_CHANGES_reg, MODE_CHANGES_next : mc_array;

  signal read_reg, read_next : word_t;
  signal clock_delay_reg : word_t;

  signal period_boundary_sig, latch_hi_clock : std_logic;
  signal STBL_IDX_RESET, STBL_IDX_EN_sig, T2N_ld_reg : std_logic;
  signal STBL_IDX_INC : unsigned(STBL_IDX_WIDTH-1 downto 0);

  signal config_slv_error_next : std_logic;

  constant MASTER_RUN_PIPE_DEPTH : natural := 3;
  signal master_run_reg : std_logic_vector(MASTER_RUN_PIPE_DEPTH-1 downto 0);

  signal run_reg : std_logic;
begin

--------------------------------------------------------------------------------
-- Master/Slave run signals
--------------------------------------------------------------------------------
  master_config : if MASTER generate
    master_run <= master_run_reg(master_run_reg'high);
    process(clk)
    begin
      if rising_edge(clk) then
        if reset = '1' then
          master_run_reg <= (others => '0');
        else
          master_run_reg <= master_run_reg(master_run_reg'high-1 downto 0) & MASTER_RUN_NEXT;
        end if ;
      end if ;
    end process ;
  end generate ;

  slave_config : if not MASTER generate
    master_run <= '0';
  end generate ;

--------------------------------------------------------------------------------
-- Configuration access to the registers
--------------------------------------------------------------------------------

  
  process (read_reg, CLOCK_CNT_LO_reg, TDM_P_CNT_reg, TDM_S_CNT_reg, clock_delay_reg, config.addr, config.en, config.wdata(0 downto 0), config.wr, master_run_reg(0), run, sel)
  begin
    config_slv.rdata <= (others=> '0');
    config_slv.rdata(WORD_WIDTH-1 downto 0) <= read_reg;
    config_slv_error_next <= '0';
    read_next <= TDM_P_CNT_reg;
    latch_hi_clock <= '0';
    MASTER_RUN_NEXT(0) <= master_run_reg(0);
    if (sel = '1' and config.en = '1') then
      -- Read registers
      if config.wr = '0' then
        case( to_integer(config.addr(CPKT_ADDR_WIDTH-1 downto 0)) ) is
          when 0 =>
            read_next(TDM_S_CNT_WIDTH-1 downto 0) <= TDM_S_CNT_reg;
          when 1 =>
            read_next <= TDM_P_CNT_reg;
          when 2 =>
            read_next <= clock_delay_reg;
          when 3 =>
            read_next <= CLOCK_CNT_LO_reg(WORD_WIDTH-1 downto 0);
            latch_hi_clock <= '1';
          when 4 =>
            read_next <= (others => '0');
            read_next(0) <= run;
          when others =>
            config_slv_error_next <= '1';
        end case ;
      else -- Write register
        case( to_integer(config.addr(CPKT_ADDR_WIDTH-1 downto 0)) ) is
          when 4 =>
            if MASTER then
              MASTER_RUN_NEXT <= std_logic_vector(config.wdata(0 downto 0));
            end if ;
          when others =>
            config_slv_error_next <= '1';
        end case ;

      end if ;
    end if ;
  end process;

--------------------------------------------------------------------------------
-- Circuitry to control the index into the schedule table
--------------------------------------------------------------------------------
  -- In case the NI is in run state, load the t2n val from the schedule table
  -- otherwise load the defined constant RUN_LOAD_VAL
  --t2n_run <= t2n when run = '1' else RUN_LOAD_VAL;
  -- The adder to increment the schedule table index  
  STBL_IDX_INC <= STBL_IDX_reg + 1;
  -- The schedule table index registers shall be enabled,
  -- when time2next (read directly from the SBTL) is one or
  -- when time2next (decremented in the counter) becomes one
  STBL_IDX_EN_sig <= '1' when ((((TIME2NEXT_reg = 1) or (((TIME2NEXT_reg = 0) or (TIME2NEXT_reg = "11111")) and (t2n = 0))) or ( run /= run_reg)) and (run = '1') )  else '0';
  -- When index reaches the end of the schedule in the current mode
  -- reset the index
  STBL_IDX_RESET <= '1' when (((STBL_IDX_INC = stbl_maxp1) or ( run /= run_reg)) and (run = '1')) else '0';
  -- Detect period boundary
  -- period_boundary is high in the last clock cycle of a TDM period
  -- This is when the STBL index wrapps around and the STBL index is enabled
  period_boundary_sig <= STBL_IDX_RESET and STBL_IDX_EN_sig;
  period_boundary <= period_boundary_sig;
  -- Schedule table index increment
  STBL_IDX_next <= STBL_IDX_INC when STBL_IDX_RESET = '0' else 
                   stbl_min;
  stbl_idx <= STBL_IDX_next;
  stbl_idx_en <= STBL_IDX_EN_sig;

--------------------------------------------------------------------------------
-- Registers
--------------------------------------------------------------------------------

  regs : process( clk )
  begin
    if rising_edge(clk) then
      if reset = '1' then
        read_reg <= (others => '0');  
        config_slv.error <= '0';
        -- T2N_ld_reg should be initialized such that the TIME2NEXT register
        -- will load a zero. Zero will give the longest time to STBL_IDX_EN
        -- goes high.
        T2N_ld_reg <= '1';
      else
        run_reg <= run;
        read_reg <= read_next;
        T2N_ld_reg <= STBL_IDX_EN_sig;
        config_slv.error <= config_slv_error_next;
      end if ;
    end if ;
    
  end process ; -- regs

clock_counter : if GENERATE_CLK_COUNTER generate
  -- Clock counter, incremented every clock cycle
  -- A single 64 bit counter is to slow
  CLOCK_CNT_reg_PROC : process( clk )
  begin
    if rising_edge(clk) then
      if reset = '1' then
        CLOCK_CNT_LO_reg <= (others => '0');
        CLOCK_CNT_HI_reg <= (others => '0');
      else
        CLOCK_CNT_LO_reg <= CLOCK_CNT_LO_reg + 1;
        if CLOCK_CNT_LO_reg = x"FFFFFFFF" then
          CLOCK_CNT_HI_reg <= CLOCK_CNT_HI_reg + 1;  
        end if ;
      end if ;
  end if ;

end process ; -- CLOCK_CNT_reg_PROC


  -- Register for storing the high word of the 64-bit clock counter.
  -- The register is loaded when the low word of the clock counter is accessed.
  CLOCK_DELAY_reg_PROC : process( clk )
  begin
    if rising_edge(clk) then
      if reset = '1' then
        clock_delay_reg <= (others => '0');
      else
        if latch_hi_clock = '1' then
          clock_delay_reg <= CLOCK_CNT_HI_reg;  
        end if ;
      end if ;
    end if ;
    
  end process ; -- CLOCK_DELAY_reg_PROC

end generate;

no_clock_counter : if not GENERATE_CLK_COUNTER generate
  CLOCK_CNT_LO_reg <= (others => '0');
  CLOCK_CNT_HI_reg <= (others => '0');
  clock_delay_reg <= (others => '0');
end generate;
 
slot_counter : if GENERATE_SLOT_COUNTER generate 
  -- TDM slot counter, incremented every clock cycle and
  -- reset on a period boundary
  TDM_S_CNT_reg_PROC : process( clk )
  begin
    if rising_edge(clk) then
      if reset = '1' then
        TDM_S_CNT_reg <= (others => '0');
      else
        -- TDM slot counter
        if period_boundary_sig = '1' then
          TDM_S_CNT_reg <= (others => '0');
        else
          TDM_S_CNT_reg <= TDM_S_CNT_reg + 1;
        end if ;
      end if ;
    end if ;
    
  end process ; -- TDM_S_CNT_reg_PROC

end generate;

no_slot_counter : if not GENERATE_SLOT_COUNTER generate 
	TDM_S_CNT_reg <= (others => '0');
end generate;

period_counter : if GENERATE_PERIOD_COUNTER generate 
  -- TDM period counter incremented on a period boundary
  TDM_P_CNT_reg_PROC : process( clk )
  begin
    if rising_edge(clk) then
      if reset = '1' then
        TDM_P_CNT_reg <= (others => '0');
      else -- TDM_period_counters
        if period_boundary_sig = '1' then
          TDM_P_CNT_reg <= TDM_P_CNT_reg + 1;
        end if ;
      end if ;
    end if ;
  end process ; -- TDM_P_CNT_reg_PROC
end generate;

no_period_counter : if not GENERATE_PERIOD_COUNTER generate 
	TDM_P_CNT_reg <= (others => '0');
end generate;

  -- Period counter not accessible from the processor, only counts to 3
  -- Used for doing a mode change or synchronizing to a new schedule at boot up
  mc_p_cnt_reg_PROC : process( clk )
  begin
    if rising_edge(clk) then
      if reset = '1' then
        mc_p_cnt_reg <= (others => '0');
      else -- TDM_period_counters
        if period_boundary_sig = '1' then
          mc_p_cnt_reg <= mc_p_cnt_reg + 1;
        end if ;
      end if ;
    end if ;
  end process ; -- P_CNT_reg_PROC
  mc_p_cnt <= mc_p_cnt_reg;

  -- The time until the next entry in the schedule table
  -- Is decremented in every clock cycle and loaded when it reaches 0
  TIME2NEXT_reg_PROC : process( clk )
  begin
    if rising_edge(clk) then
      if reset = '1' then
        TIME2NEXT_reg <= (others => '0');
      else -- TIME2NEXT counter
        if T2N_ld_reg = '1' then
          TIME2NEXT_reg <= t2n;
        else
          TIME2NEXT_reg <= TIME2NEXT_reg - 1; 
        end if ;
      end if ;
    end if ;
  end process ; -- TIME2NEXT_reg_PROC


  -- The schedule table index register only loaded when time2next is 1
  STBL_IDX_reg_PROC : process( clk )
  begin
    if rising_edge(clk) then
      if reset = '1' then
        STBL_IDX_reg <= (others => '0');
      else
        -- Schedule table index
        if STBL_IDX_EN_sig = '1' then
          STBL_IDX_reg <= STBL_IDX_next;
        else
        end if ;
      end if ;
    end if ;
    
  end process ; -- STBL_IDX_reg_PROC

end rtl;