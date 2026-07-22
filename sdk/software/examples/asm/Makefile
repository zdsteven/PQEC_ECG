TARGET = user-sample

CFLAGS += -O3 -g
MATMUL_GROUP_NUM ?= 5000
CFLAGS += -DMATMUL_GROUP_NUM=$(MATMUL_GROUP_NUM)
# This program is the online evaluator.  One build switch owns all of its
# startup differences; the shared BSP remains generic by default.
MATMUL_EVALUATION ?= 1

C_SRCS := $(wildcard ./*.c )

OBJDIR = obj
COMMON_DIR = ../../bsp
GCC_DIR=../../../toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0
PICOLIBC_DIR=../../../toolchains/picolibc
include ../../bsp/common.mk
