library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.MATH_REAL.ALL;

entity chsel_pfb is
	Generic
	(
		-- Number of bits.
		B	: Integer := 16;
		-- Number of Lanes.
		L	: Integer := 4
	);
	Port
	(
		-- AXIS Master I/F.
		m_axis_aclk		: in std_logic;
		m_axis_aresetn	: in std_logic;
		m_axis_tdata	: out std_logic_vector(2*B-1 downto 0);
		m_axis_tstrb	: out std_logic_vector(2*B/8-1 downto 0);
		m_axis_tlast	: out std_logic;
		m_axis_tvalid	: out std_logic;
		m_axis_tready	: in std_logic;

		-- AXIS Slave I/F.
		s_axis_aclk		: in std_logic;
		s_axis_aresetn	: in std_logic;
		s_axis_tdata	: in std_logic_vector(2*B*L-1 downto 0);
		s_axis_tstrb	: in std_logic_vector(2*B*L/8-1 downto 0);
		s_axis_tlast	: in std_logic;
		s_axis_tvalid	: in std_logic;
		s_axis_tready	: out std_logic;

		-- Registers.
		START_REG		: in std_logic;
		CHID_REG		: in std_logic_vector (31 downto 0)
	);
end chsel_pfb;

architecture rtl of chsel_pfb is

-- Number of bits of L.
constant L_LOG2 	: Integer := Integer(ceil(log2(real(L))));

-- Number of input bits.
constant NBIT_IN	: Integer := 2*B*L;

-- Synchronizer.
component synchronizer_n is 
	generic (
		N : Integer := 2
	);
	port (
		rstn	    : in std_logic;
		clk 		: in std_logic;
		data_in		: in std_logic;
		data_out	: out std_logic
	);
end component;

-- Single-clock AXI compatible FIFO.
component fifo_axi is
    Generic
    (
        -- Data width.
        B : Integer := 16;
        
        -- Fifo depth.
        N : Integer := 4
    );
    Port
    ( 
        rstn	: in std_logic;
        clk 	: in std_logic;

        -- Write I/F.
        wr_en  	: in std_logic;
        din     : in std_logic_vector (B-1 downto 0);
        
        -- Read I/F.
        rd_en  	: in std_logic;
        dout   	: out std_logic_vector (B-1 downto 0);
        
        -- Flags.
        full    : out std_logic;        
        empty   : out std_logic
    );
end component;

-- Double-clock AXI compatible FIFO.
component fifo_dc_axi is
    Generic
    (
        -- Data width.
        B : Integer := 16;
        
        -- Fifo depth.
        N : Integer := 4
    );
    Port
    ( 
        wr_rstn	: in std_logic;
        wr_clk 	: in std_logic;

        rd_rstn	: in std_logic;
        rd_clk 	: in std_logic;
        
        -- Write I/F.
        wr_en  	: in std_logic;
        din     : in std_logic_vector (B-1 downto 0);
        
        -- Read I/F.
        rd_en  	: in std_logic;
        dout   	: out std_logic_vector (B-1 downto 0);
        
        -- Flags.
        full    : out std_logic;        
        empty   : out std_logic
    );
end component;

type fsm_state is (	INIT_ST	,
					START_ST,
					S0_ST	,
					S1_ST	,
					S2_ST	,
					S3_ST	,
					S4_ST	);
signal current_state, next_state : fsm_state;

signal start_state		: std_logic;
signal s0_state			: std_logic;
signal s1_state			: std_logic;
signal s3_state			: std_logic;
signal s4_state			: std_logic;

-- Re-synced signals.
signal start_reg_resync	: std_logic;

-- Registers.
signal chid_reg_r		: std_logic_vector (31 downto 0);

-- Input FIFO.
signal fifo_in_din		: std_logic_vector (NBIT_IN downto 0);
signal fifo_in_rd_en	: std_logic;
signal fifo_in_dout		: std_logic_vector (NBIT_IN downto 0);
signal fifo_in_full		: std_logic;
signal fifo_in_empty	: std_logic;

-- Output FIFO.
signal fifo_out_wr_en	: std_logic;
signal fifo_out_din		: std_logic_vector (2*B-1 downto 0);
signal fifo_out_full	: std_logic;
signal fifo_out_empty	: std_logic;

-- Slice data/last.
signal d_i				: std_logic_vector (NBIT_IN-1 downto 0);
signal last_i			: std_logic;

-- Pipeline registers.
signal d_r				: std_logic_vector (NBIT_IN-1 downto 0);
signal d_rr				: std_logic_vector (2*B-1 downto 0);
signal empty_r			: std_logic;
signal last_r			: std_logic;
signal wr_en_r			: std_logic;

-- Read and write signals.
signal rd_en			: std_logic;
signal wr_en			: std_logic;

-- Array of input samples.
type vect_t is array (L-1 downto 0) of std_logic_vector (B-1 downto 0);
signal di_v_i 			: vect_t;
signal di_v_q 			: vect_t;

-- Mux for data.
signal d_mux			: std_logic_vector (2*B-1 downto 0);

-- Registers for index and packet.
signal chid_off_r		: unsigned (31 downto 0);
signal chid_idx_r		: unsigned (31 downto 0);
signal idx_r			: unsigned (L_LOG2-1 downto 0);

-- Counter for packet.
signal cnt				: unsigned (31 downto 0);

begin

-- start_reg_resync.
start_reg_resync_i : synchronizer_n
	generic map (
		N => 2
	)
	port map (
		rstn	    => s_axis_aresetn	,
		clk 		=> s_axis_aclk		,
		data_in		=> START_REG		,
		data_out	=> start_reg_resync
	);

-- Input FIFO (NBIT_IN + 1 bits: data + tlast).
fifo_in: fifo_axi
    Generic map
    (
        -- Data width.
        B => NBIT_IN + 1	,
        
        -- Fifo depth.
        N => 8
    )
    Port map
    ( 
        rstn	=> s_axis_aresetn	,
        clk 	=> s_axis_aclk		,

        -- Write I/F.
        wr_en  	=> s_axis_tvalid	,
        din     => fifo_in_din		,
        
        -- Read I/F.
        rd_en  	=> fifo_in_rd_en	,
        dout   	=> fifo_in_dout		,
        
        -- Flags.
        full    => fifo_in_full		,
        empty   => fifo_in_empty
    );

-- Fifo connections.
fifo_in_din		<= s_axis_tlast & s_axis_tdata;
fifo_in_rd_en	<= rd_en;

-- FIFO out (2*B bits).
fifo_out : fifo_dc_axi
    Generic map
    (
        -- Data width.
        B => 2*B	,
        
        -- Fifo depth.
        N => 8
    )
    Port map
    ( 
        wr_rstn	=> s_axis_aresetn	,
        wr_clk 	=> s_axis_aclk		,

        rd_rstn	=> m_axis_aresetn	,
        rd_clk 	=> m_axis_aclk		,
        
        -- Write I/F.
        wr_en  	=> fifo_out_wr_en	,
        din     => fifo_out_din		,
        
        -- Read I/F.
        rd_en  	=> m_axis_tready	,
        dout   	=> m_axis_tdata		,
        
        -- Flags.
        full    => fifo_out_full	,
        empty   => fifo_out_empty
    );

-- Fifo connections.
fifo_out_wr_en	<= wr_en_r;
fifo_out_din	<= d_rr;

process ( s_axis_aclk )
begin
	if ( rising_edge( s_axis_aclk ) ) then
		if ( s_axis_aresetn = '0' ) then
			-- State register.
			current_state	<= INIT_ST;

			-- Registers.
			chid_reg_r		<= (others => '0');

			-- Pipeline registers.
			d_r				<= (others => '0');
			d_rr			<= (others => '0');
			empty_r			<= '1';
			last_r			<= '0';
			wr_en_r			<= '0';

			-- Registers for index and packet.
			chid_off_r		<= (others => '0');
			chid_idx_r		<= (others => '0');
			idx_r			<= (others => '0');

			-- Counter for packet.
			cnt				<= (others => '0');

		else
			-- State register.
			current_state	<= next_state;

			-- Registers.
			if ( start_state = '1' ) then
				chid_reg_r	<= CHID_REG;
			end if;

			-- Pipeline registers.
			if ( rd_en = '1' ) then
				d_r			<= d_i;
				d_rr		<= d_mux;
				empty_r		<= fifo_in_empty;
				last_r		<= last_i;
				wr_en_r		<= wr_en;
			end if;

			-- Registers for index and packet.
			if ( start_state = '1' ) then
				chid_off_r		<= (others => '0');
				chid_idx_r		<= unsigned(chid_reg_r);
			elsif ( s0_state = '1' ) then
				chid_off_r <= chid_off_r + 1;
				chid_idx_r <= chid_idx_r - to_unsigned(L,chid_idx_r'length);
			end if;
			if ( s1_state = '1' ) then
				idx_r <= chid_idx_r(L_LOG2-1 downto 0);
			end if;

			-- Counter for packet.
			if ( start_state = '1' ) then
				cnt <= (others => '0');
			elsif ( s3_state = '1' or s4_state = '1' ) then
				if ( empty_r = '0' ) then
					if ( cnt < chid_off_r ) then
						cnt <= cnt + 1;
					else
						cnt <= (others => '0');
					end if;
				end if;
			end if;

		end if;
	end if;	
end process;

-- Slice data/last.
d_i 	<= fifo_in_dout(NBIT_IN-1 downto 0);
last_i	<= fifo_in_dout(NBIT_IN);

-- Read and write signals.
rd_en	<= 	not(fifo_out_full) when s4_state = '1' else
			'1';
wr_en	<=	not(empty_r) when s4_state = '1' else
			'0';

-- Array of input samples.
GEN_SLICE: for I in 0 to L-1 generate
	di_v_i(I) <= d_r (2*I*B+B-1 	downto 	2*I*B	);
	di_v_q(I) <= d_r (2*I*B+2*B-1 	downto 	2*I*B+B	);
end generate GEN_SLICE;

-- Mux for data.
d_mux <= di_v_q(to_integer(idx_r)) & di_v_i(to_integer(idx_r));

-- Next state logic.
process (current_state, start_reg_resync, chid_idx_r, last_r, empty_r, chid_off_r, cnt, fifo_out_full)
begin
	case (current_state) is
		when INIT_ST =>
			next_state <= START_ST;

		when START_ST =>
			if ( start_reg_resync = '0' ) then
				next_state <= START_ST;
			else
				if ( chid_idx_r < to_unsigned(L,chid_idx_r'length) ) then
					next_state <= S1_ST;
				else
					next_state <= S0_ST;
				end if;
			end if;

		when S0_ST =>
			if ( chid_idx_r < to_unsigned(2*L,chid_idx_r'length) ) then
				next_state <= S1_ST;
			else
				next_state <= S0_ST;
			end if;

		when S1_ST =>
			next_state <= S2_ST;

		when S2_ST =>
			if ( last_r = '1' and empty_r = '0' ) then
				if ( chid_off_r = to_unsigned(0,chid_off_r'length) ) then
					next_state <= S4_ST;
				else
					next_state <= S3_ST;
				end if;
			else
				next_state <= S2_ST;
			end if;

		when S3_ST =>
			if ( cnt = chid_off_r-1 and empty_r = '0' ) then
				next_state <= S4_ST;
			else
				next_state <= S3_ST;
			end if;

		when S4_ST =>
			if ( start_reg_resync = '1' ) then
				if ( empty_r = '0' and fifo_out_full = '0' ) then
					if ( chid_off_r = to_unsigned(0,chid_off_r'length) ) then
						next_state <= S2_ST;
					else
						if ( last_r = '1' ) then
							next_state <= S3_ST;
						else
							next_state <= S2_ST;
						end if;
					end if;
				else
					next_state <= S4_ST;
				end if;
			else
				next_state <= START_ST;
			end if;

	end case;
end process;

-- Output logic.
process (current_state)
begin
start_state	<= '0';
s0_state	<= '0';
s1_state	<= '0';
s3_state	<= '0';
s4_state	<= '0';
	case (current_state) is
		when INIT_ST =>

		when START_ST =>
			start_state	<= '1';

		when S0_ST =>
			s0_state	<= '1';

		when S1_ST =>
			s1_state	<= '1';

		when S2_ST =>

		when S3_ST =>
			s3_state	<= '1';

		when S4_ST =>
			s4_state	<= '1';

	end case;
end process;

-- Assign outputs.
s_axis_tready	<= not(fifo_in_full);

m_axis_tstrb	<= (others => '1');
m_axis_tlast	<= '0';
m_axis_tvalid	<= not(fifo_out_empty);

end rtl;

