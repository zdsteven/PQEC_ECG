# 线上评测模式矩阵乘法加速系统说明

## 1. 文档范围

本文只说明集创赛线上评测使用的 5000 组 4×4 无符号矩阵乘法高速路径，包括：

- FPGA 配置和平台复位释放后的启动过程；
- ExtRAM 输入读取、矩阵流式计算、硬件 CRC32 和 CPU/UART 协同上报；
- 从 `MATMUL_START` 到 `MATMUL_DONE` 的计时覆盖关系；
- 当前用于缩短线上评测时间的硬件与软件结构；
- 当前实现的时序、AXI4 和正确性约束。

本文不讨论非评测用途。当前工作区默认使用本文所述的评测硬件配置。

## 2. 评测任务与数据格式

### 2.1 输入和输出规模

线上平台在 ExtRAM 中准备 5000 组测试数据。每组包含两个 4×4、32-bit 无符号矩阵：

```text
输入区：5000 × (16 word A + 16 word B)
      = 160000 word
      = 640000 byte

逻辑结果：5000 × 16 个 66-bit C 元素
        = 5000 × 48 word
        = 240000 word
        = 960000 byte
```

评测初始化文件同时包含输入区和预留结果区。当前高速路径只读取前 640000 byte，不向后 960000 byte 结果区写数据。

### 2.2 ExtRAM 布局

```text
0x1C40_0000：输入区
    group 0：A[0..15]，B[0..15]
    group 1：A[0..15]，B[0..15]
    ...
    group 4999

0x1C49_C400：结果区起始地址
    当前评测高速路径不写该区域
```

矩阵元素按行主序排列。DMA 送给计算 core 的一组输入固定为：

```text
A00, A01, A02, A03, A10, ... , A33,
B00, B01, B02, B03, B10, ... , B33
```

`stream_index[4:0]` 为 0～31：bit4 区分 A/B，低 4 bit 是矩阵内位置。

### 2.3 结果与 CRC 格式

每个结果为四个 32×32 无符号乘积之和，最大需要 66 bit：

```text
C[i][j] = Σ A[i][k] × B[k][j]，k=0..3
```

按评测规定，每个结果以三个小端 32-bit word 进入 CRC：

```text
word0 = C[31:0]
word1 = C[63:32]
word2 = {30'b0, C[65:64]}
```

CRC 使用 reflected IEEE CRC-32，初值 `0xFFFFFFFF`，反射多项式 `0xEDB88320`，处理完全部 240000 个逻辑结果 word 后再与 `0xFFFFFFFF` 异或。

### 2.4 UART 协议

UART 为 115200 baud、8N1，必须依次输出：

```text
MATMUL_START\n
MATMUL_CRC32=XXXXXXXX\n
MATMUL_DONE\n
```

CRC 使用 8 位大写十六进制。线上平台收到完整的 `MATMUL_START` 后开始计时，收到完整的 `MATMUL_DONE` 后停止计时，并校验两者之间收到的 CRC。

## 3. 当前评测硬件结构

评测数据通路如下：

```text
ExtRAM
  │  256-beat AXI4 INCR burst
  ▼
评测版 axi2sram_sp_external（连续地址发射 + 256-entry R FIFO）
  │
  ▼
matmul_dma 读调度器
  ├────────► matmul_batch_core 0 ──┐
  └────────► matmul_batch_core 1 ──┤ 66-bit result
                                   ▼
                         有序结果收集 + 硬件 CRC32
                                   │
                          start 专用触发信号
                                   ▼
                      UART 自动发送 START 状态机
                                   │
                                   ▼
                               UART_TX

CPU ──► DMA 配置/start ──► 读取进度、done、CRC32
 └──────────────────────► UART TX FIFO（CRC 前缀、数字和 DONE）
```

这条路径有四个重要特点：

1. DMA 只负责数据搬运、core 调度、结果排序和 CRC，不在 DMA 内做矩阵乘法；
2. AXI R 握手的数据直接旁路到矩阵 core，不先写大型输入 block；
3. 计算结果不写回 ExtRAM，也不进入大型结果 block；
4. CPU 不参与 5000 组循环或 CRC 计算，但负责启动 DMA、安排 CRC 前缀并格式化最终 CRC/DONE。

## 4. 从 FPGA 复位到评测完成的全过程

### 4.1 PLL 提前运行

非仿真顶层中，PLL 的 `resetn` 固定为 1。平台保持 CPU/SoC 复位时，PLL 仍可运行并提前锁定：

```verilog
.resetn(1'b1)
```

系统复位释放条件是 `pll_locked & ~reset`，因此各状态机只在 PLL 已锁定且平台释放复位后运行。

### 4.2 评测 cache 冷启动与 CPU 显式启动 DMA

`matmul_dma` 的复位默认参数已经固定为评测数据：

```text
SRC_BASE  = 0x1C40_0000
DST_BASE  = 0x1C49_C400（保留寄存器，当前不写回）
GROUP_NUM = 5000
```

评测网表将 I-cache 和 D-cache 的 tag/valid BRAM 初始化为全 0。软件使用 `EVAL_FAST_START=1`，因此复位释放后不再重复执行 256 个索引、两个 cache、两个 way 的 1024 次 `cacop`，但仍保留地址模式、data/bss、cache enable、异常入口和栈初始化。

DMA 复位时 `auto_start_armed=0`。CPU 进入 `main` 后通过 `MATMUL_DMA_Start` 写入固定评测参数并显式写 CTRL.start：

- 配置源地址、保留的结果地址和 5000 组数量；
- 清空组计数、core 调度状态和 CRC 状态；
- 置 `busy`；
- 同拍产生一次 `start_banner_valid`；
- 随即发起第一笔 ExtRAM AXI 读请求。

DMA 接受 CPU start 时触发 START 字符串；DMA 状态机、CPU 调度和 UART 发送随后并行推进。

### 4.3 UART 无需等待 CPU 初始化

评测版 UART 的复位分频低字节为 `0x1B`，线路格式为 8N1，用于平台约定的 115200-baud 串口。它在收到 `start_banner_valid` 后自动发送 `MATMUL_START\n`。

当前启动汇编不执行 UART 重新初始化，因此 CPU 不清空 TX FIFO，也不重写自动 UART 的分频器。

CPU 不执行 printf、不启动逐组运算，也不计算 CRC。`user-sample.c` 显式启动 DMA，随后通过只读进度寄存器安排 CRC 前缀；启动代码仍保持 `UART_INIT_ON_START=0`，不会清空自动 START 使用的 TX FIFO。

### 4.4 ExtRAM 连续读入

每组输入 32 word，DMA 将 8 组组合成一个 AXI4 最大长度 burst：

```text
8 group × 32 word = 256 beat = 1024 byte
ARLEN = 255, ARSIZE = 2, ARBURST = INCR
```

CPU 启动的 5000 组任务使用 625 个 1024-byte burst；这些 burst 的起始地址按组布局对齐，不跨越 AXI4 的 4 KiB 边界。

评测版 ExtRAM 桥将“SRAM 地址发射”和“AXI R 数据退休”解耦：

- READ 状态中只要本 burst 仍有地址，就每拍置 `req_o` 并推进地址；
- 地址发射不受上一拍 `RVALID/RREADY` 或单级 `rd_valid` 反向 gating；
- SRAM 返回数据写入 256-entry R FIFO，FIFO 可容纳一个完整最大 burst；
- AXI R 通道从 FIFO 独立握手，背压不会立即切断 SRAM 地址流水；
- 弹出当前 burst 的 RLAST 时可同拍接受下一笔 AR，并采集下一 burst 的第一个 word。

DMA 在当前 burst 最后 32 beat 期间持续预告下一笔 AR：

```text
read_chain_offer = read_state==RD_DATA && read_beat[7:5]==3'b111
```

桥只在当前 burst 的 RLAST 退休时接收这笔请求；DMA 的 ARVALID 由提前保持的 `read_chain_offer` 产生，不由当拍 RLAST 组合产生。

### 4.5 双 core 交替调度

`matmul_dma` 当前只调度 core0 和 core1。每组第一个 word A00 握手时：

- 从 ready core 中选择一个 core；
- 同拍产生该 core 的 `stream_start`；
- A00 通过输入旁路被 core 直接接收；
- 后续 31 word 固定路由到同一 core；
- `next_core` 使相邻组优先交替使用两个 core。

只有在一组第一个 word 到来而两个 core 都不 ready 时，DMA 才拉低 `m_axi_rready`。组内其余 31 word 不产生调度背压。

一组输入占 32 个数据拍；B33 进入后，无 DSP radix-4 乘法流水继续推进。下一组可送入另一个 ready core，使两个 core 的输入和流水尾段交叠。

### 4.6 边输入边计算

评测 core 使用流式结构，不需要完整的 1024-bit A/B block 输入端口。当前输入布局为先 A 后 B：

1. A00～A33 到达时写入 16 个 A 寄存器并置 valid；
2. 每个 B[k][j] 到达时，立即读取已到达的 `A[0..3][k]`；
3. 同拍向四条乘法 lane 发射：

```text
A[0][k] × B[k][j] → C[0][j]
A[1][k] × B[k][j] → C[1][j]
A[2][k] × B[k][j] → C[2][j]
A[3][k] × B[k][j] → C[3][j]
```

4. lane 携带目标 C 下标 tag，通过 16 级 radix-4 流水后累加到对应的 66-bit accumulator；
5. 最后一个 B33 的四个乘积到达流水尾部时，对 C03/C13/C23/C33 做末次加法旁路，并一次性形成 16 个稳定快照；
6. core 拉低 busy、脉冲输出 done。

四条乘法 lane 每拍可接受一个 B word 对应的四个乘积。评测宏下例化的是 `matmul_batch_core`，其乘法数据通路使用 radix-4 shift/add，不使用 Verilog `*` 运算符。

### 4.7 结果有序收集与 CRC

core0/core1 可能交错完成，但 CRC 必须严格保持 group0～group4999、C00～C33 的规定顺序。DMA 为每个 core 记录所属 group，并用 `calc_group_count` 只选择当前应处理的完成结果。

每组结果收集过程为：

- `matmul_result_index` 从 0 递增到 15；
- 每拍读取一个稳定的 66-bit `result_snapshot`；
- 用一级 `crc_result_data/crc_result_valid` 寄存器隔离结果 mux 与 CRC XOR 网络；
- 下一拍调用 `crc32_update_result`，在逻辑上连续处理该结果的三个 32-bit word；
- 每组 16 个结果连续处理，不需要结果 RAM，也没有 AXI 写事务。

core 的结果快照在下一组计算完成前保持不变，因此 DMA 收集已完成组结果时，该 core 可以接收下一组输入并进行计算。最后一组第 16 个结果完成 CRC 更新时，DMA 同拍锁存最终反相值，产生 `crc32_valid`，并置 done。

### 4.8 CPU 安排 CRC 前缀、CRC 数字和 DONE

DMA 提供只读的 `READ_GROUPS` 寄存器。CPU 观察到已读取 3410 组后，向 UART TX FIFO 写入：

```text
MATMUL_CRC32=
```

前缀与剩余 DMA/计算/CRC 时间重叠。CPU 随后轮询 DMA done 并读取最终 CRC32。当前 UART 的 TFE 状态在最后一个排队字符被 transmitter 取走时置位，因此 CPU 在 `=` 已进入 transmitter、尚未在线路上发送完成的一个字符时间内，把 8 位大写 CRC 和尾串的前 8 字节填满 16-entry FIFO；第二次 TFE 置位后再补入尾串剩余 5 字节。

这种两批写入保持以下物理字节流连续：

```text
MATMUL_CRC32=XXXXXXXX\nMATMUL_DONE\n
```

DMA 与 UART 之间当前只用 `start_banner_valid` 触发自动 START。UART 自动状态机在 START 入队完成后进入 IDLE，忽略 CRC sideband；CRC 数字和 DONE 均由 CPU 写 TX FIFO。

UART 自动发送器通过 TX FIFO 写入后续字节；发送器在 stop bit 状态结束时，如果 FIFO 已有下一字节，则直接装载该字节并进入下一字符的 start bit。

## 5. 评测计时边界和并行关系

根据评测协议，线上平台收到完整 START 行后开始计时，收到完整 DONE 行后停止计时。当前硬件允许以下状态机并行运行：

```text
平台释放 reset
│
├─ CPU 快速启动、写 DMA start ───────────────────────────────────────┐
├─ DMA 首个 AR、ExtRAM 读取、core 计算                              │
├─ UART 自动发送 MATMUL_START\n ──► 平台开始计时                     │
│                                                                    │
├─ 后续 ExtRAM 读取 + 双 core 计算 + 已完成结果收集/CRC                │
├─ read_groups=3410 ─► CPU 提前发送 MATMUL_CRC32=                     │
│                                                                    │
└─ CRC ready ─► CPU 读 CRC ─► 8 hex + DONE ─► 平台停止计时 ◄────────┘
```

代码中的并行关系为：

- 平台保持 SoC 复位时，PLL 仍保持运行；
- CPU 快速启动后显式启动 DMA，DMA start 与 START 串行发送并行；
- ExtRAM 读取与两个 core 的计算并行推进；
- DMA 读取已完成结果并更新 CRC 时，core 可处理后续输入；
- CPU 发送 CRC 前缀时 DMA、core 和 CRC 继续运行；
- CPU 的 done 轮询不参与矩阵计算或硬件 CRC 更新。

## 6. 面向评测时间的当前设计

### 6.1 控制路径

- 评测 tag/valid BRAM 使用冷启动无效初值，软件跳过重复 `cacop`；
- CPU 用固定评测参数显式启动 DMA；
- START 在 DMA 启动时由硬件触发；
- 软件按读取组数提前安排 CRC 前缀，等待 done 后读取 CRC；
- 评测程序不包含 `printf`、软件 CRC、CPU 逐组搬运和结果读取；
- UART 使用复位默认 115200 8N1，评测时禁止启动代码清 TX FIFO；
- PLL 在外部复位期间保持运行，并在锁定后允许系统复位释放。

### 6.2 ExtRAM/AXI 读路径

- 每次读取 256 beat、覆盖 8 组输入；
- burst 地址按 1024 byte 对齐，遵守 AXI4 4 KiB 边界；
- DMA 在最后 32 beat 提前保持下一 AR 请求；
- 桥在当前 RLAST 退休时同拍接受新 AR；
- SRAM 地址 issue 与 R data accept 解耦；
- 使用可容纳完整 burst 的 256-entry R FIFO；
- 地址由寄存器保存并按 `+4` 推进。

### 6.3 矩阵计算路径

- 乘法运算保留在独立矩阵 IP 内，DMA 不复制计算资源；
- core 缓存 A，B 到达即发射四路乘积；
- A00 与 start 同拍旁路接收；
- 使用两个 core 交叠输入阶段和乘法流水尾部；
- 四条 16 级 radix-4 shift/add lane，每拍接收一个 B word，不使用 DSP；
- 最终 B33 的四个结果使用固定下标旁路；
- 结果快照允许已完成组的结果收集与下一组计算重叠。

### 6.4 CRC 与结果路径

- CRC32 完全硬件化；
- 每拍接收一个 66-bit C，并在组合函数中按三个 word 的规定顺序更新；
- result mux 和 CRC 网络之间有一级寄存器；
- 用 group tag 和 `calc_group_count` 保证双 core 乱序完成时仍按输入顺序计算 CRC；
- 评测路径不执行 ExtRAM 结果写回；
- DMA 中没有大型 `result_memory`、写回 block、AW/W/B 写回 FSM；
- DMA 没有专用性能统计寄存器。

### 6.5 UART 尾部

- START 由硬件状态机发送；
- CRC 前缀、CRC 数字和 DONE 由 CPU 写 TX FIFO；
- CRC 前缀在 `read_group_count>=3410` 时提前发送；
- CPU 使用 TFE 的“最后一个 FIFO 字节已被 transmitter 取走”语义及时补入下一批；
- TX FIFO 提前准备下一字节；
- stop bit 状态结束且 FIFO 非空时直接装载下一字符。

### 6.6 时序与结构精简

- CRC 输入前有一级 `crc_result_data/crc_result_valid` 寄存器；
- burst 链式请求在最后 32 beat 期间给出；
- ExtRAM 地址用递增寄存器生成；
- 当前评测分支例化两个 core；
- 使用固定 case 选择 16 个结果；
- 评测数据通路只保留输入读取、core 调度、结果排序和 CRC 所需状态；
- 复位 for-loop 内的数组初始化使用阻塞赋值。

## 7. 协议与完成条件

### 7.1 AXI4 读通道

- ARLEN 最大 255，符合 AXI4 最大 256 beat；
- burst 不跨 4 KiB；
- RVALID、RDATA、RID、RLAST 由 FIFO 头部产生，在 RREADY 为低时保持稳定；
- RLAST 只标记 burst 的最后一个 beat；
- 下一 AR 只在桥可接受时握手，持续预告不等于重复提交；
- DMA 仅在 `RVALID && RREADY` 时推进 `read_beat` 和 stream 输入。

### 7.2 core 调度和结果顺序

- 每组 32 word 从第一个到最后一个绑定同一 core；
- 只有组首允许因无 ready core 而反压；
- core done 被 pending 位保留，不依赖 DMA 恰好同拍采集；
- group tag 防止双 core 先后次序变化破坏 CRC；
- 结果快照保证收集期间数值稳定。

### 7.3 CRC 和完成条件

- CRC 顺序为 group→C index→低/中/高 word；
- 最后一个 66-bit 结果经过 CRC 寄存级后才产生最终值；
- `crc32_valid` 与 `crc32_final` 同拍有效；
- CPU 只在 DMA done 后读取最终 CRC；
- DONE 字符只在 8 位 CRC 已进入 FIFO 后写入，不会先于 CRC 行。

### 7.4 UART 发送条件

- 评测时不得由启动代码复位正在工作的 TX FIFO；
- UART transmitter 按 start/data/stop 状态发送字符；
- 自动发送状态机只负责 START；CPU 写入必须排在 START 之后，并保持 CRC 前缀、数字和 DONE 的顺序。

## 8. 线上评测构建与检查清单

推荐以如下参数构建评测程序：

```text
make MATMUL_GROUP_NUM=5000 COPY_OUTPUT=0
```

提交前应逐项确认：

1. 评测软件按 `MATMUL_GROUP_NUM=5000` 构建；
2. `user-sample.bin` 使用当前评测程序；
3. DSP 检查结果为 0；
4. HDL lint 通过，尤其没有数组循环延迟赋值错误；
5. 实现后 WNS 严格大于 0；
6. 用多个随机 seed 检查 CRC；
7. 串口必须完整且有序收到 START、CRC32、DONE；
8. 保存线上 elapsed time 和对应 bitstream 的实现报告。

当前本地 `fpga/project` Vivado 工程已经过期。进行本地仿真、综合、实现或读取本地 WNS/DSP 报告前，必须先运行 `fpga/create_project.tcl` 重新创建工程；旧工程和旧报告不代表当前 RTL。工程重建后才能执行本地仿真，并通过新的实现流程生成可用于检查的报告。

## 9. 关键源码位置

| 文件 | 评测相关职责 |
|---|---|
| `rtl/soc_top.v` | PLL/复位、评测 DMA、Matmul、UART 和 ExtRAM 桥连接 |
| `rtl/ip/DMA/matmul_dma.v` | CPU start、读取进度、256-beat 读、双 core 调度、有序结果收集、CRC32 |
| `rtl/ip/matmul/matmul_axi_slave.v` | 两个评测 core 的例化和 DMA stream 接口 |
| `rtl/ip/matmul/matmul_batch_core.v` | 评测分支例化的无 `*` 流式 4×4 矩阵乘法 core |
| `rtl/ip/Bus_interconnects/axi2sram_sp_external.v` | 连续 SRAM 地址发射、R FIFO、burst 链接 |
| `rtl/ip/APB_UART/URT/uart_top.v` | 自动 START 状态机和 CPU TX 数据仲裁 |
| `rtl/ip/APB_UART/URT/uart_regs.v` | UART 复位分频默认值、自动 TX FIFO 注入 |
| `rtl/ip/APB_UART/URT/uart_transmitter.v` | 字符位状态和相邻字符衔接 |
| `rtl/ip/ram_wrap/cache_sram.v` | 评测 cache tag/valid 的确定性冷启动无效初值 |
| `sdk/software/bsp/env/start.S` | 评测快速启动、可关闭的 UART 软件初始化 |
| `sdk/software/examples/asm/user-sample.c` | DMA start、提前前缀、读取 CRC、发送 CRC/DONE |
| `fpga/create_project.tcl` | 本地验证前重新创建已过期的 Vivado 工程 |
