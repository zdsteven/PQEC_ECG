# 矩阵乘法 DMA 加速器工作流程说明

## 总体结构

批处理通路由两个相互独立的 SoC 外设组成：`matmul_dma` 负责数据流，`matmul_axi_slave` 内部实例化唯一的 `matmul_batch_core` 并负责全部矩阵运算。CPU 只配置源物理地址、目标物理地址和矩阵组数；DMA 通过 AXI master 直接访问 ExtRAM，并通过专用握手接口调用 Matmul IP。

1. DMA 每次以 32-word burst 读取一组 `A[16] + B[16]`。
2. 两个 128-byte 寄存器缓冲交替工作：DMA 用 `start/ready` 将一块缓冲提交给独立 Matmul IP，同时继续向另一块接收下一组输入。
3. Matmul IP 内的矩阵核包含 16 路并行 66-bit 累加器，按 B 的 bit 做移位累加，不使用 `*` 运算符和 DSP。每组核心计算为 128 拍。完成后 DMA 通过 `done/result_index/result_data` 逐项取回结果。
4. 每组 16 个 66-bit 结果写入一个 `66 bit × 80000` 的 BRAM 结果块。5000 组共约 5.28 Mbit。
5. 所有输入计算完毕后，DMA 才开始集中回写。每个 66-bit 元素依次写为 low32、high32、top2；每 16 words 发出一个 AXI burst，避免跨越 4 KiB 边界。
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
- 写回 burst 固定为 16 words（64 bytes），起始地址始终 64-byte 对齐，天然不会跨 AXI 4 KiB 边界。
- CRC 每个 word 分成低、高两个 16-bit 阶段更新；CRC 级忙时对 AXI W 通道施加背压，最长组合链限制为 16 个 LFSR bit-step。

## 软件流程

`user-sample.c` 在打印 `MATMUL_START` 后启动批处理 DMA，等待全部写回和硬件 CRC 完成，读取 `CRC32` 寄存器，最后输出规定的 CRC 和完成标识。
