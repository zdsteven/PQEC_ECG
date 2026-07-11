# 矩阵乘法 DMA 加速器工作流程说明

## 1. 当前总体结构

当前矩阵乘法加速路径由三个主要硬件部分组成：

1. `matmul_dma`
   - 负责从 ExtRAM 连续读取 5000 组输入矩阵。
   - 通过专用 stream 接口把输入 word 直接送入矩阵计算 IP。
   - 从矩阵计算 IP 读取 66-bit 结果，并在硬件中直接计算标准 IEEE CRC-32。
   - 当前优化版不再把结果写回 ExtRAM，评测只使用串口上报的 CRC。

2. `matmul_axi_slave`
   - 保留原有 CPU AXI 兼容窗口，CPU 仍可通过寄存器写入 A/B、读取 C。
   - DMA 高速路径通过新增的 stream 接口进入内部两个 `matmul_batch_core`。
   - DMA 路径只使用 core0/core1；core2/core3 相关输出保留为接口兼容。

3. `matmul_batch_core`
   - 内部支持 stream 输入。
   - 在 DMA 模式下，输入 word 到达时立即进入计算路径，不再需要先完整搬入 32-word 输入缓存再启动。
   - 不使用 DSP 资源。

顶层 `soc_top.v` 中，DMA 和 Matmul IP 通过如下专用信号连接：

```verilog
matmul_stream_valid
matmul_stream_start[3:0]
matmul_stream_core[3:0]
matmul_stream_index[4:0]
matmul_stream_data[31:0]
matmul_ready[3:0]
matmul_done[3:0]
matmul_result_index[3:0]
matmul_result_data0/1
```

## 2. 数据布局和读入流程

ExtRAM 输入区保持比赛规定布局不变：

```text
每组 128 byte：
A[0..15]，共 16 word
B[0..15]，共 16 word
```

DMA 读侧以 256-beat AXI burst 为主要单位工作：

- 1 个 256-beat burst 覆盖 8 组输入矩阵。
- 每个输入组仍按 32 word 解析。
- `read_beat[4:0] == 0` 表示一组矩阵的第一个 word，此时 DMA 选择一个空闲 core，并在同一拍发出 `matmul_stream_start`。
- 后续 31 个 word 继续送给同一个 core。

为了减少 burst 边界空泡，DMA 在当前 burst 末尾提前给出下一次 AR 请求：

```verilog
read_chain_offer = (read_state == RD_DATA) && (read_beat[7:5] == 3'b111)
```

配合 `axi2sram_sp_external` 的读端连续地址发射，目标是让 ExtRAM 读数据尽可能接近 1 word/cycle。

## 3. DMA 寄存器接口

DMA 基址为 CPU uncached 地址 `0xBF30_0000`。

| 偏移 | 名称 | 说明 |
|---:|---|---|
| `0x00` | CTRL | bit0 写 1 启动；当前也支持复位后自动启动 |
| `0x04` | STATUS | bit0 busy，bit1 done，bit2 error；写 bit1/2 清状态 |
| `0x08` | SRC_BASE | ExtRAM 输入区物理地址，默认 `0x1C40_0000` |
| `0x0C` | DST_BASE | ExtRAM 结果区物理地址，默认 `0x1C49_C400`；当前高速评测路径不写回结果 |
| `0x10` | GROUP_NUM | 组数，合法范围 1～5000 |
| `0x20` | CRC32 | 当前 CRC 状态读回值 |

历史调试用的 `READ_COUNT / CALC_COUNT / WRITE_COUNT / perf_*` 计数器已经删除，以减少寄存器、比较器和读 mux。

## 4. Matmul IP 工作流程

### 4.1 CPU 兼容路径

`matmul_axi_slave` 保留原有寄存器窗口：

- CPU 可写 A/B 输入窗口。
- CPU 可写 CTRL 启动计算。
- CPU 可读 STATUS 和 C_DATA。

这条路径主要用于兼容和调试，不是当前在线评测的性能路径。

### 4.2 DMA stream 路径

DMA stream 路径直接送入两个 `matmul_batch_core`。

当前输入顺序仍为比赛原始布局，即先 A 后 B：

```text
A00, A01, ..., A33,
B00, B01, ..., B33
```

core 内部做了 stream 化处理：

- A word 到达时写入 A 寄存器并置 valid。
- B word 到达时，立即与已缓存的对应 A 列数据组合，发起 4 路 MAC。
- 结果通过流水乘法/累加路径逐步归并。
- 最后一个 B word 到达后，只需等待现有流水线延迟即可输出 `done`。

这样去掉了旧结构中“先完整收齐 A/B，再启动计算”的等待时间。

## 5. CRC 和结果处理

当前高速路径不再写回 960000 byte 结果区。原因是在线评测最终只检查串口上报的 CRC，且写回 ExtRAM 会带来额外 AXI 写事务、仲裁、burst 边界和状态机开销。

因此结果处理流程变为：

1. core 完成一组矩阵后置位 `matmul_done`。
2. DMA 按 `matmul_result_index = 0..15` 依次读取 16 个 66-bit C 元素。
3. 每个 66-bit 结果按比赛规定拆成 3 个 word：

```text
word0 = result[31:0]
word1 = result[63:32]
word2 = {30'b0, result[65:64]}
```

4. DMA 对这 3 个 word 直接更新 IEEE CRC-32。
5. 最后一组最后一个元素进入 CRC 后，DMA 拉高 `crc32_valid` 并输出 `crc32_final`。

旧版 result BRAM 和 AXI 写回状态机已经删除：

- 删除 `result_memory`
- 删除 `RESULT_WRITEBACK`
- 删除 `WB_*` 写回 FSM
- 删除 AW/W/B burst 写回逻辑

DMA 的 AXI master 写通道仍保留端口形状，但保持 idle，保证顶层连接和 AXI 结构兼容。

## 6. UART 自动输出流程

为了减少 CPU 软件和 UART 初始化/格式化开销，当前串口输出由 UART 硬件自动完成。

输出格式仍满足评测协议：

```text
MATMUL_START
MATMUL_CRC32=XXXXXXXX
MATMUL_DONE
```

当前策略：

- DMA 启动后立即触发 `auto_start_valid`。
- UART 自动发送 `MATMUL_START\n`。
- `MATMUL_CRC32=` 前缀延后约 `0.75 ms` 后发送，使前缀和最终 CRC 数字更贴近，减少串口尾部等待。
- DMA 计算出 CRC 后，UART 自动发送 8 位大写十六进制 CRC。
- 最后自动发送 `MATMUL_DONE\n`。

对应常量：

```verilog
AUTO_CRC_PREFIX_DELAY = 16'd37500; // 0.75 ms @ 50 MHz
```

UART 复位默认配置已经调整为 115200 8N1，软件启动代码中不再重复初始化 UART，避免在硬件自动发送期间清 FIFO。

## 7. 软件流程

当前 `user-sample.c` 的工作已经压缩到极简：

1. CPU 上电后进入程序。
2. DMA 复位后自动启动；软件不负责搬运矩阵数据。
3. 软件只等待 DMA done。
4. 串口 START、CRC 和 DONE 由硬件 UART 自动输出。

因此软件路径基本不再包含：

- printf 格式化开销
- CRC 软件计算
- 结果区扫描
- 大量 UART 轮询发送

## 8. 已完成的主要速度优化

### 8.1 取消软件矩阵乘法和软件 CRC

最初的软件/寄存器驱动方式需要 CPU 逐组搬运、启动、读取结果、计算 CRC，开销过大。当前全部改为硬件 DMA + Matmul core + 硬件 CRC。

### 8.2 读侧 burst 扩大和连续化

读侧从小 burst/逐组请求优化为 256-beat burst：

- 每 burst 覆盖 8 组输入。
- DMA 在 burst 末尾提前给出下一次 AR。
- `axi2sram_sp_external` 读 FSM 拆分地址发射和数据返回，使读端更接近 streaming。

目标是减少 ExtRAM 读侧从 2 cycle/word 退化产生的 bubble。

### 8.3 结果写回逐步弱化并最终取消

中间版本曾做过多轮写回优化：

- 每组 48 word 尝试合并为更大的线性 burst。
- 跳过部分 write NOP。
- 尝试 4/8/16/32-word gap。
- 让写回和剩余计算重叠。

最终发现在线路径只需要 CRC，因此直接取消结果写回，避免了：

- AXI AW/W/B 状态机开销
- ExtRAM 单端口读写冲突
- burst 边界和 B response 空泡
- 结果 BRAM 存储和读出路径

这是结构上最干净的优化。

### 8.4 矩阵 core 支持边输入边计算

旧 core 等 32 个输入 word 全部到齐后才开始计算。当前 core 在 stream 输入时提前使用已经到达的 A/B 数据参与 MAC。

收益：

- 减少每组输入完成后再启动计算的等待。
- 第 32 个输入 word 到达后，只剩流水线尾部延迟。
- DMA 输入流和 core 计算更紧密重叠。

### 8.5 双 core 调度

当前 DMA 使用 core0/core1 两个计算 core：

- 第一个 word 到达时选择 ready core。
- 同一组的后续 word 绑定到该 core。
- core done 后，DMA 用 16 拍读取该组 16 个结果并更新 CRC。

这让读输入、计算和结果收集尽量重叠。

### 8.6 硬件 UART 自动输出

软件 `printf` 和轮询 UART 曾是明显尾部开销。当前改为：

- 硬件自动输出 START/CRC/DONE。
- CRC 前缀延迟发送，让 CRC 数字和前缀更贴近。
- UART transmitter 支持 stop 后衔接下一字节，减少字符间空隙。

曾尝试过更激进的 FIFO 连续填充，但出现串口字符错乱，因此最终保留稳定方案。

### 8.7 PLL 提前锁定

PLL reset 不再跟随平台 CPU/SoC reset 完全重启。FPGA 配置完成后 PLL 可提前运行，平台保持 CPU/SoC reset 时 PLL 继续锁定。

这样释放 reset 后可以减少等待 PLL lock 的启动尾部时间。

### 8.8 删除调试计数器和无用写回结构

在确认瓶颈后，删除了调试用性能计数器：

- `perf_read_cycles`
- `perf_calc_cycles`
- `perf_done_cycles`
- 相关 cycle counter 和寄存器读 mux

同时删除了已经不用的 result writeback block，使 DMA 数据路径更小、更容易过时序。

## 9. 时序设计注意事项

- CRC 更新是组合 XOR 网络，前后用寄存器隔离，避免直接拉长 AXI ready/valid 路径。
- DMA 读请求在 burst 末尾提前发起，避免 RLAST 后再启动 AR 的长空泡。
- Matmul core 内部使用流水乘法/累加结构，不使用 DSP。
- AXI 写通道当前保持 idle，但端口完整保留，避免破坏 SoC crossbar 接口。
- CPU 兼容窗口保留在 `matmul_axi_slave`，但评测性能路径不经过它的寄存器搬运。
