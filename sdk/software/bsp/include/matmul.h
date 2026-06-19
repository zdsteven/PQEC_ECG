#ifndef MATMUL_H
#define MATMUL_H

#include "common_func.h"

// =============================================================================
//  矩阵乘法加速器 HAL 驱动
// =============================================================================
// 基地址：物理地址 0x1F50_0000，通过 DMW 映射到 CPU 虚拟地址 0xBF50_0000
// 功能：计算 C[4×4] = A[4×4] × B[4×4]，无符号 32-bit 乘法，66-bit 累加
// 架构：CPU 通过寄存器写入 A/B，启动计算，轮询状态，读取 C 结果
// =============================================================================

#define MATMUL_BASEADDR      0xbf500000

// 寄存器偏移地址
#define MATMUL_CTRL_ADDR     (MATMUL_BASEADDR + 0x00)   // 控制寄存器：bit0=start
#define MATMUL_STATUS_ADDR   (MATMUL_BASEADDR + 0x04)   // 状态寄存器：bit0=busy, bit1=done

// 矩阵数据窗口
#define MATMUL_A_DATA_BASE   (MATMUL_BASEADDR + 0x20)   // A[0..15]，偏移 0x20~0x5C
#define MATMUL_B_DATA_BASE   (MATMUL_BASEADDR + 0x60)   // B[0..15]，偏移 0x60~0x9C
#define MATMUL_C_DATA_BASE   (MATMUL_BASEADDR + 0xA0)   // C[0..15]×3 word，偏移 0xA0~0x15C

// 状态位
#define MATMUL_STATUS_BUSY  0x1
#define MATMUL_STATUS_DONE  0x2

// =============================================================================
//  函数声明
// =============================================================================

// 启动矩阵乘法计算（写 CTRL.bit0 = 1）
void MATMul_Start(void);

// 查询状态
uint32_t MATMul_Is_Busy(void);
uint32_t MATMul_Is_Done(void);

// 等待计算完成（轮询 STATUS 直到 done 位被置位）
void MATMul_Wait_Done(void);

// 写入矩阵 A（16 个 32-bit 元素）
void MATMul_Write_A(volatile uint32_t *a);

// 写入矩阵 B（16 个 32-bit 元素）
void MATMul_Write_B(volatile uint32_t *b);

// 读取结果 C（48 个 32-bit word，每个元素 3 word）
void MATMul_Read_C(volatile uint32_t *c);

// 计算单组矩阵乘法：写入 A/B，启动，等待，读取 C
void MATMul_Compute(volatile uint32_t *a, volatile uint32_t *b, volatile uint32_t *c);

#endif
