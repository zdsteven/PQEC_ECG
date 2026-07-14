
LA32R_GCC     := loongarch32r-linux-gnusf-gcc
LA32R_AS      := loongarch32r-linux-gnusf-as
LA32R_GXX     := loongarch32r-linux-gnusf-g++
LA32R_OBJDUMP := loongarch32r-linux-gnusf-objdump
LA32R_GDB     := loongarch32r-linux-gnusf-gdb
LA32R_AR      := loongarch32r-linux-gnusf-ar
LA32R_OBJCOPY := loongarch32r-linux-gnusf-objcopy
LA32R_READELF := loongarch32r-linux-gnusf-readelf
COPY_OUTPUT ?= 1
# Set to 1 for software-controlled UART FIFO/divisor initialization in start.S.
# Keep 0 when the UART autonomous reporter must preserve its reset-time output.
UART_INIT_ON_START ?= 1

.PHONY: all
all: $(TARGET)

#TODO: 根据Cache实际情况调整has_cache宏，以在start.S中生成正确的Cache初始化代码
CFLAGS += -Dhas_cache=1
CFLAGS += -Dcache_index_depth=0x100 -Dcache_offset_width=0x4 -Dcache_way=2
CFLAGS += -ffunction-sections -fdata-sections
CFLAGS += -nostartfiles -nostdlib -nostdinc -static -fno-builtin 
CFLAGS += -DCLOCKS_PER_SEC=CORE_CLOCKS_PER_SEC -D_CLOCKS_PER_SEC_=CORE_CLOCKS_PER_SEC
CFLAGS += -DUSE_CPU_CLOCK_COUNT
CFLAGS += -DUART_INIT_ON_START=$(UART_INIT_ON_START)

#若使用 newlib , 将下面的 -lsemihost 替换为 -lgloss
LDFLAGS +=  	-T $(LINKER_SCRIPT) \
				-Wl,--gc-sections -Wl,--check-sections \
				-lc -lm -lg -lsemihost -lgcc -L$(PICOLIBC_DIR)/lib

LINKER_SCRIPT := $(COMMON_DIR)/env/script.lds

ASM_SRCS += $(COMMON_DIR)/env/start.S 

ifeq ($(TARGET), RTThread_Nano)

else
ASM_SRCS += $(COMMON_DIR)/env/trap_handler.S 
endif

C_SRCS   += $(COMMON_DIR)/drivers/confreg_time.c
C_SRCS   += $(COMMON_DIR)/drivers/core_time.c
C_SRCS   += $(COMMON_DIR)/drivers/common_func.c
C_SRCS   += $(COMMON_DIR)/drivers/aes/aes_hardware.c \
			$(COMMON_DIR)/drivers/aes/aes_software.c \
			$(COMMON_DIR)/drivers/dvi.c \
			$(COMMON_DIR)/drivers/dma.c \
			$(COMMON_DIR)/drivers/ecg.c \
			$(COMMON_DIR)/drivers/led.c \
			$(COMMON_DIR)/drivers/seg7.c \
			$(COMMON_DIR)/drivers/random_api.c \
			$(COMMON_DIR)/drivers/uart_api.c\
			$(COMMON_DIR)/drivers/matmul.c\
			$(COMMON_DIR)/drivers/matmul_dma.c \

ifneq ($(EXCLUDE_KYBER_DRIVER),1)
C_SRCS   += $(COMMON_DIR)/drivers/kem/Kem_api.c \
			$(COMMON_DIR)/drivers/kem/Kem_hw_accelerator.c \
			$(COMMON_DIR)/drivers/kem/Kem_sw.c
endif

INCLUDES += -I./ \
			-I$(COMMON_DIR)/include \
			-I$(COMMON_DIR)/include/kem \
			-I$(PICOLIBC_DIR)/include \
			-I$(GCC_DIR)/lib/gcc/loongarch32r-linux-gnusf/8.3.0/include \
			-I$(GCC_DIR)/lib/gcc/loongarch32r-linux-gnusf/8.3.0/include-fixed

ASM_OBJS := $(ASM_SRCS:.S=.o)
C_OBJS := $(C_SRCS:.c=.o)

LINK_OBJS += $(ASM_OBJS) $(C_OBJS)
LINK_DEPS += $(LINKER_SCRIPT)

CLEAN_OBJS += $(OBJDIR)/$(TARGET).elf $(LINK_OBJS) $(OBJDIR)/$(TARGET).s $(OBJDIR)/$(TARGET).bin $(OBJDIR)/convert $(OBJDIR)/axi_ram.coe $(OBJDIR)/axi_ram.mif $(OBJDIR)/rom.vlog

$(TARGET): $(LINK_OBJS) $(LINK_DEPS) convert Makefile
	$(LA32R_GCC) $(CFLAGS) $(INCLUDES) $(LINK_OBJS) -o $(OBJDIR)/$@.elf $(LDFLAGS)
	$(LA32R_OBJCOPY) -O binary $(OBJDIR)/$@.elf $(OBJDIR)/$@.bin
	$(LA32R_OBJDUMP) --disassemble-all -S $(OBJDIR)/$@.elf > $(OBJDIR)/$@.s
	$(OBJDIR)/convert $@.bin $(OBJDIR)/
ifeq ($(COPY_OUTPUT),1)
	cp ./$(OBJDIR)/axi_ram.mif $(COMMON_DIR)/../../
ifdef LA32RSOC_WINDOWS_HOME
	cp ./$(OBJDIR)/axi_ram.mif $(LA32RSOC_WINDOWS_HOME)/sdk
	cp ./$(OBJDIR)/$(TARGET).bin $(LA32RSOC_WINDOWS_HOME)/sdk
endif
endif
	rm -f $(LINK_OBJS)
	rm -f $(OBJDIR)/convert

$(ASM_OBJS): %.o: %.S
	$(LA32R_GCC) $(CFLAGS) $(INCLUDES) -c -o $@ $< 

$(C_OBJS): %.o: %.c
	$(LA32R_GCC) $(CFLAGS) $(INCLUDES) -c -o $@ $< 

convert: $(COMMON_DIR)/env/convert.c
	mkdir -p $(OBJDIR)/
	gcc -o $(OBJDIR)/convert $(COMMON_DIR)/env/convert.c

.PHONY: clean
clean:
	rm -f $(CLEAN_OBJS)
