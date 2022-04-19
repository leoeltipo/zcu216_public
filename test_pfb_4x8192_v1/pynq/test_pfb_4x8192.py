from qick.qick import *

class AxisConstantIQ(SocIp):
    # AXIS Constant IQ registers:
    # REAL_REG : 16-bit.
    # IMAG_REG : 16-bit.
    # WE_REG   : 1-bit. Update registers.
    bindto = ['user.org:user:axis_constant_iq:1.0']
    REGISTERS = {'real_reg':0, 'imag_reg':1, 'we_reg':2}
        
    def __init__(self, description):
        # Initialize ip
        super().__init__(description)
        
        # Default registers.
        self.real_reg = 30000
        self.imag_reg = 30000
        
        # Generics
        self.B = int(description['parameters']['B'])
        self.N = int(description['parameters']['N'])
        self.MAX_V = 2**(self.B-1)-1
        
        # Register update.
        self.update()
        
    def config(self, tile, block, fs):
        self.tile = tile
        self.dac = block
        self.fs = fs

    def update(self):
        self.we_reg = 1        
        self.we_reg = 0
        
    def set_iq(self,i=1,q=1):
        # Set registers.
        self.real_reg = int(i*self.MAX_V)
        self.imag_reg = int(q*self.MAX_V)
        
        # Register update.
        self.update()
        
class AxisChSelPfbV1(SocIp):
    # AXIS Channel Selection PFB V1 Registers
    # START_REG
    # * 0 : stop.
    # * 1 : start.
    #
    # CHID_REG
    bindto = ['user.org:user:axis_chsel_pfb_v1:1.0']
    REGISTERS = {'start_reg' : 0, 'chid_reg' : 1}
    
    def __init__(self, description):
        # Initialize ip
        super().__init__(description)
        
        # Default registers.
        self.start_reg = 0
        self.chid_reg = 0
        
        # Generics.
        self.B = int(description['parameters']['B'])
        self.L = int(description['parameters']['L'])        
        
    def configure(self, buffer):
        self.buffer = buffer
        
    def transfer(self,ch):
        # Select channel
        self.chsel(ch)
        
        # Capture data with buffer
        self.buffer.capture()
        
        # Transfer data
        return self.buffer.transfer()

    def chsel(self,ch):
        # Stop to allow register update
        self.start_reg = 0
        
        # Change channel
        self.chid_reg = ch
        
        # Start
        self.start_reg = 1
        
class AxisBuffer(SocIp):
    # AXIS_buffer registers.
    # DW_CAPTURE_REG
    # * 0 : disable capture.
    # * 1 : enable capture.
    #
    # DR_START_REG
    # * 0 : start reader.
    # * 1 : stop reader.
    bindto = ['user.org:user:axis_buffer:1.0']
    REGISTERS = {'dw_capture' : 0, 'dr_start' : 1}
    
    def __init__(self, description):
        # Initialize ip
        super().__init__(description)
        
        # Default registers.
        self.dw_capture = 0
        self.dr_start = 0
        
        # Generics.
        self.B = int(description['parameters']['B'])
        self.N = int(description['parameters']['N'])
        self.BUFFER_LENGTH = (1 << self.N)
        
    def configure(self,axi_dma):
        self.dma = axi_dma
    
    def capture(self):
        # Enable capture
        self.dw_capture = 1
        
        # Wait for capture
        #time.sleep(0.1)
        
        # Stop capture
        self.dw_capture = 0
        
    def transfer(self):
        self.dr_start = 0
        
        buff = allocate(shape=(self.BUFFER_LENGTH,), dtype=np.uint32)

        # Start transfer.
        self.dr_start = 1

        # DMA data.
        self.dma.recvchannel.transfer(buff)
        self.dma.recvchannel.wait()

        # Stop transfer.
        self.dr_start = 0
        
        # Return data
        # Format:
        # -> lower 16 bits: I value.
        # -> higher 16 bits: Q value.
        data = buff
        dataI = data & 0xFFFF
        dataQ = data >> 16

        return np.stack((dataI, dataQ)).astype(np.int16)        
    
    def length(self):
        return (1 << self.N)
    
class AxisPfb4x8192V1(SocIp):
    bindto = ['user.org:user:axis_pfb_4x8192_v1:1.0']
    REGISTERS = {'qout_reg' : 0}
    
    # Generic parameters.
    N = 8192
    
    def __init__(self, description):
        # Initialize ip
        super().__init__(description)
        
        # Default registers.
        self.qout_reg = 0
        
    def qout(self, qout):
        self.qout_reg = qout
        
class Mixer:    
    # rf
    rf = 0
    
    def __init__(self, ip):        
        # Get Mixer Object.
        self.rf = ip
    
    def set_freq(self,f,tile,dac):
        # Make a copy of mixer settings.
        dac_mixer = self.rf.dac_tiles[tile].blocks[dac].MixerSettings        
        new_mixcfg = dac_mixer.copy()

        # Update the copy
        new_mixcfg.update({
            'EventSource': xrfdc.EVNT_SRC_IMMEDIATE,
            'Freq' : f,
            'MixerType': xrfdc.MIXER_TYPE_FINE,
            'PhaseOffset' : 0})

        # Update settings.                
        self.rf.dac_tiles[tile].blocks[dac].MixerSettings = new_mixcfg
        self.rf.dac_tiles[tile].blocks[dac].UpdateEvent(xrfdc.EVENT_MIXER)
       
    def set_nyquist(self,nz,tile,dac):
        dac_tile = self.rf.dac_tiles[tile]
        dac_block = dac_tile.blocks[dac]
        dac_block.NyquistZone = nz          

class TopSoc(Overlay):    
    # Constructor.
    def __init__(self, bitfile=None, force_init_clks=False,ignore_version=True, **kwargs):
        # Load overlay (don't download to PL).
        Overlay.__init__(self, bitfile, ignore_version=ignore_version, download=False, **kwargs)
        
        # Configuration dictionary.
        self.cfg = {}
        self.cfg['board'] = os.environ["BOARD"]
        self.cfg['refclk_freq'] = 245.76        

        # Read the config to get a list of enabled ADCs and DACs, and the sampling frequencies.
        self.list_rf_blocks(self.ip_dict['usp_rf_data_converter_0']['parameters'])
        
        # Configure PLLs if requested, or if any ADC/DAC is not locked.
        if force_init_clks:
            self.set_all_clks()
            self.download()
        else:
            self.download()        
        
        # PFB.
        self.pfb = self.axis_pfb_4x8192_v1_0        
        
        # Buffer.
        self.buff = self.axis_buffer_0
        self.buff.configure(self.axi_dma_0)
        
        # Channel selection.
        self.chsel = self.axis_chsel_pfb_v1_0
        self.chsel.configure(self.buff)
        
        # RF data converter (for configuring ADCs and DACs)
        self.rf = self.usp_rf_data_converter_0
        
        # Mixer.
        self.mixer = Mixer(self.usp_rf_data_converter_0)
        
        # Constant.
        self.iq = self.axis_constant_iq_0
        
    def freq2reg(self, fs, f, nbits=32):    
        k_i = np.int64(2**nbits*f/fs)
        return k_i          

    def list_rf_blocks(self, rf_config):
        """
        Lists the enabled ADCs and DACs and get the sampling frequencies.
        XRFdc_CheckBlockEnabled in xrfdc_ap.c is not accessible from the Python interface to the XRFdc driver.
        This re-implements that functionality.
        """

        hs_adc = rf_config['C_High_Speed_ADC']=='1'

        self.dac_tiles = []
        self.adc_tiles = []
        dac_fabric_freqs = []
        adc_fabric_freqs = []
        refclk_freqs = []
        self.dacs = {}
        self.adcs = {}

        for iTile in range(4):
            if rf_config['C_DAC%d_Enable'%(iTile)]!='1':
                continue
            self.dac_tiles.append(iTile)
            f_fabric = float(rf_config['C_DAC%d_Fabric_Freq'%(iTile)])
            f_refclk = float(rf_config['C_DAC%d_Refclk_Freq'%(iTile)])
            dac_fabric_freqs.append(f_fabric)
            refclk_freqs.append(f_refclk)
            fs = float(rf_config['C_DAC%d_Sampling_Rate'%(iTile)])*1000
            for iBlock in range(4):
                if rf_config['C_DAC_Slice%d%d_Enable'%(iTile,iBlock)]!='true':
                    continue
                self.dacs["%d%d"%(iTile,iBlock)] = {'fs':fs,
                                                    'f_fabric':f_fabric,
                                                    'tile':iTile,
                                                    'block':iBlock}

        for iTile in range(4):
            if rf_config['C_ADC%d_Enable'%(iTile)]!='1':
                continue
            self.adc_tiles.append(iTile)
            f_fabric = float(rf_config['C_ADC%d_Fabric_Freq'%(iTile)])
            f_refclk = float(rf_config['C_ADC%d_Refclk_Freq'%(iTile)])
            adc_fabric_freqs.append(f_fabric)
            refclk_freqs.append(f_refclk)
            fs = float(rf_config['C_ADC%d_Sampling_Rate'%(iTile)])*1000
            #for iBlock,block in enumerate(tile.blocks):
            for iBlock in range(4):
                if hs_adc:
                    if iBlock>=2 or rf_config['C_ADC_Slice%d%d_Enable'%(iTile,2*iBlock)]!='true':
                        continue
                else:
                    if rf_config['C_ADC_Slice%d%d_Enable'%(iTile,iBlock)]!='true':
                        continue
                self.adcs["%d%d"%(iTile,iBlock)] = {'fs':fs,
                                                    'f_fabric':f_fabric,
                                                    'tile':iTile,
                                                    'block':iBlock}

    def set_all_clks(self):
        """
        Resets all the board clocks
        """
        if self.cfg['board']=='ZCU111':
            print("resetting clocks:",self.cfg['refclk_freq'])
            xrfclk.set_all_ref_clks(self.cfg['refclk_freq'])
        elif self.cfg['board']=='ZCU216':
            lmk_freq = self.cfg['refclk_freq']
            lmx_freq = self.cfg['refclk_freq']*2
            print("resetting clocks:",lmk_freq, lmx_freq)
            xrfclk.set_ref_clks(lmk_freq=lmk_freq, lmx_freq=lmx_freq)