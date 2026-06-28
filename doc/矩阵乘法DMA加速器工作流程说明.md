# 矩阵乘法 DMA 加速器工作流程说明

## 总体结构

批处理通路由两个相互独立的 SoC 外设组成：`matmul_dma` 负责数据流，`matmul_axi_slave` 内部实例化两个 `matmul_batch_core` 并负责全部矩阵运算。CPU 只配置源物理地址、目标物理地址和矩阵组数；DMA 通过 AXI master 直接访问 ExtRAM，并通过专用握手接口调用 Matmul IP。

1. DMA 每次以 32-word burst 读取一组 `A[16] + B[16]`。
2. 两个 128-byte 寄存器缓冲交替工作：DMA 用双路 `start/ready` 将完整输入组轮流提交给 Matmul IP 内的两个计算 core，同时继续接收后续输入。
3. 每个 core 包含 16 路并行 66-bit 累加器，按 B 的 bit 做移位累加，不使用 `*` 运算符和 DSP。每组核心计算为 128 拍。完成时 16 个结果并行锁存到独立快照寄存器，core 可立即接收下一组；DMA 再通过共享的 `result_index` 用 16 拍串行搬运快照，计算和结果收集互不阻塞。
4. 每组 16 个 66-bit 结果写入一个 `66 bit × 80000` 的 BRAM 结果块。5000 组共约 5.28 Mbit。
5. 最后一个输入读 burst 完成后，只要已有完整结果组落入 BRAM，DMA 就立即开始回写，剩余矩阵继续并行计算。每个 66-bit 元素依次写为 low32、high32、top2；每组 48 words 只发出一个 AXI burst。
6. DMA 在每个写回 word 被 AXI 接收时同步更新 IEEE CRC-32。CPU 等待 `done` 后直接读取 CRC 寄存器，不再扫描 960000-byte 结果区。

## DMA 寄存器

DMA 基址为 CPU uncached 地址 `0xBF30_0000`。

| 偏移 | 名称 | 说明 |
|---:|---|---|
| `0x00` | CTRL | bit0 写 1 启动 |
| `0x04` | STATUS | bit0 busy，bit1 done，bit2 error；写 bit1/2 清状态 |
| `0x08` | SRC_BASE | ExtRAM 输入区物理地址，默认 `0x1C40_0000` |
| `0x0C` | DST_BASE | ExtRAM 结果区物理地址，默认 `0x1C49_C400` |
| `0x10` | GROUP_NUM | 组数，合法范围 1～5000 |
| `0x14` | READ_COUNT | 已读入组数 |
| `0x18` | CALC_COUNT | 已计算并存入结果块的组数 |
| `0x1C` | WRITE_COUNT | 已完整写回组数 |
| `0x20` | CRC32 | 完整写回数据流的标准 IEEE CRC-32 |

## 时序设计要点

- 乘法被分解为逐 bit 条件加法，算术关键路径仅包含一级 66-bit 加法器。
- AXI 地址、状态和 BRAM 输出均寄存；结果 BRAM 预取发生在当前元素 word1 被接受时，不在 AXI 数据输出前串接大组合选择器。
- 结果块使用原生 66-bit 宽度，写回时再补齐第三个 word 的高 30 位。
- 通常每组使用一个 48-word burst；若结果组跨越 AXI4 规定的 4 KiB 边界，则在边界处拆成最少的两个 burst。每个 burst 内 W beat 连续发送。
- ExtRAM 读阶段结束后才允许 AW，保证单端口 SRAM 不发生读写冲突；结果 BRAM 的另一端口仍可接收两个计算 core 的后续结果。
- CRC 在每次 AXI W 握手时完成整个 32-bit word 的并行更新。常量多项式循环会综合为 XOR 网络，CRC 不再参与 `WVALID` 生成，也不会在 burst 内制造空拍。

## 软件流程

`user-sample.c` 在打印 `MATMUL_START` 后启动批处理 DMA，等待全部写回和硬件 CRC 完成，读取 `CRC32` 寄存器，最后输出规定的 CRC 和完成标识。
