TARGET = ecg_demo

CFLAGS += -O3 -g

C_SRCS := $(wildcard ./*.c )

OBJDIR = obj
COMMON_DIR = ../../bsp
GCC_DIR=../../../toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0
PICOLIBC_DIR=../../../toolchains/picolibc

# Keep the 10000-sample validation set outside the 512 KiB code/data regions.
LDFLAGS += -T ./ecg_data.lds

include ../../bsp/common.mk
