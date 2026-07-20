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
  │  下降沿/上升沿连续给出相邻 word 地址
  ▼
eval_ext_sram_ddr_phy（每个 50 MHz 周期返回两个 word）
  │  fast_pair_valid/data0/data1/ready
  ▼
matmul_dma 读调度器
  ├────────► matmul_batch_core 0 ──┐
  └────────► matmul_batch_core 1 ──┤ 66-bit result
                                   ▼
                         有序结果收集 + 硬件 CRC32
                                   │
CPU ──► UART TX FIFO（START、CRC 前缀、数字和 DONE）──► UART_TX
 │
 ├─ 等待 START 最后一个 stop bit 完成
 └─► DMA CTRL.start ──► 读取进度、done、CRC32
```

这条路径有四个重要特点：

1. DMA 只负责数据搬运、core 调度、结果排序和 CRC，不在 DMA 内做矩阵乘法；
2. ExtRAM 返回的两个相邻 word 直接流入矩阵 core，不先写大型输入 block；
3. 计算结果不写回 ExtRAM，也不进入大型结果 block；
4. CPU 不参与 5000 组循环或 CRC 计算，但负责发送 START、在 START 完整发送后启动 DMA、安排 CRC 前缀并格式化最终 CRC/DONE。

## 4. 从 FPGA 复位到评测完成的全过程

### 4.1 PLL 提前运行

非仿真顶层中，PLL 的 `resetn` 固定为 1。平台保持 CPU/SoC 复位时，PLL 仍可运行并提前锁定：

```verilog
.resetn(1'b1)
```

系统复位释放条件是 `pll_locked & ~reset`，因此各状态机只在 PLL 已锁定且平台释放复位后运行。

### 4.2 评测 cache 冷启动与 CPU 提前发送 START

`matmul_dma` 的复位默认参数已经固定为评测数据：

```text
SRC_BASE  = 0x1C40_0000
DST_BASE  = 0x1C49_C400（保留寄存器，当前不写回）
GROUP_NUM = 5000
```

评测网表将 I-cache 和 D-cache 的 tag/valid BRAM 初始化为全 0。软件使用 `EVAL_FAST_START=1`，因此复位释放后不再重复执行 256 个索引、两个 cache、两个 way 的 1024 次 `cacop`，但仍保留地址模式、data/bss、cache enable、异常入口和栈初始化。

启动汇编使用 `EVAL_CPU_START_BANNER=1`。在 DMW 建立、CPU 可以访问未缓存 UART 地址后，CPU 立即用 13 次 byte MMIO 写把 `MATMUL_START\n` 放入 16-entry TX FIFO。发送与后续 data/bss、cache、异常入口和栈初始化重叠。

CPU 进入 `main` 后轮询 UART TE；只有最后一个 START stop bit 已在线路上完成，才写一次 CTRL.start。DMA 接受该写入后：

- 清空组计数、core 调度状态和 CRC 状态；
- 置 `busy`；
- 随即发起第一笔 ExtRAM AXI 读请求。

完整配置式 `MATMUL_DMA_Start` 仍保留在关闭 `EVAL_FAST_DMA_START` 时使用；正式评测默认 `EVAL_FAST_DMA_START=1`。

评测 RTL 已删除硬件自动 START/CRC/DONE 状态机和 DMA-to-UART sideband，只保留 CPU 写 TX FIFO 的发送路径。DMA 的 `eval_read_enable` 固定允许，顺序正确性由 CPU 的“先等待 TE、后写 DMA start”保证。

### 4.3 CPU 驱动 UART 与分数分频

平台串口按 115200 baud、8N1 接收。评测版 UART 的复位整数分频低字节为 `0x1A`，分数部分为 `0xF0`，平均 16x tick 分频为 `26 + 240/256 = 26.9375`，50 MHz 下实际发送速率约为 116.01 kbaud。transmitter 仍使用已验证的 13-tick stop interval。

分数累加器在 transmitter 完全空闲时固定为相位 0，使 START 和后续 CPU 字节 burst 都从确定的 tick 序列开始，避免空闲期间自由运行造成前缀乱码。

当前启动汇编不执行 UART 重新初始化，因此 CPU 不清空 TX FIFO，也不覆盖复位分频。CPU 不执行 printf、不启动逐组运算，也不计算 CRC；START、CRC 前缀、CRC 数字和 DONE 均通过 CPU MMIO 写 TX FIFO。

### 4.4 ExtRAM 连续读入

每组输入 32 word。当前评测路径直接控制 ExtRAM 引脚，在一个 50 MHz 周期内读取相邻两个 word：

```text
16 pair/group × 5000 group = 80000 pair
每 pair = data0、data1 两个连续 32-bit word
```

`fast_read_base_word` 给出首 word 地址，`fast_read_pair_count` 固定为 `group_num×16`。物理层在两个半周期发出相邻地址，经 SRAM 采样后以 `fast_pair_valid` 同拍返回 `data0/data1`。DMA 只在 `fast_pair_valid && fast_pair_ready` 时推进 pair 和 group 计数；仅组首且两个 core 都不 ready 时允许反压。当前正式路径的 AXI master 读写 VALID 均固定为 0，不参与评测数据搬运。

### 4.5 双 core 交替调度

`matmul_dma` 当前只调度 core0 和 core1。每组第一个 word A00 握手时：

- 从 ready core 中选择一个 core；
- 同拍产生该 core 的 `stream_start`；
- A00 通过输入旁路被 core 直接接收；
- 后续 31 word 固定路由到同一 core；
- `next_core` 使相邻组优先交替使用两个 core。

只有在一组第一个 word 到来而两个 core 都不 ready 时，DMA 才拉低 `m_axi_rready`。组内其余 31 word 不产生调度背压。

评测读路径每个系统周期向 core 提供相邻的两个 word，因此一组 32 word 占 16 个输入周期。B32/B33 进入后，选中 core 还需 15 个 radix-4 digit 周期形成结果；下一组先送入另一个 ready core。相邻两次选择同一 core 的间隔为 32 周期，当前结构无需为计算主动插入输入停顿。

### 4.6 十六个固定 C 引擎

评测 core 使用流式输入和 16 个固定 C 引擎，不需要完整的 1024-bit A/B block 输入端口。当前输入布局仍为先 A 后 B：

1. A00～A33 到达时写入 16 个 A 寄存器，A00 可与 `start` 同拍旁路接收；
2. B00/B01 到达时，把各行 A 操作数复制到对应 C 引擎的局部 radix-4 状态，并预先形成 `A` 和 `3A`；
3. B00～B33 写入输入暂存；B32/B33 到达的同拍，通过直接旁路处理所有 16 个 C 的 digit 0；
4. 随后 15 个周期依次处理 digit 1～15。每个 C 引擎固定计算：

```text
A[0][k] × B[k][j] → C[0][j]
A[1][k] × B[k][j] → C[1][j]
A[2][k] × B[k][j] → C[2][j]
A[3][k] × B[k][j] → C[3][j]
```

每个 digit 周期，各引擎根据四个 B 的 2-bit digit 在 `0/A/2A/3A` 中选择四项，经平衡加法树加入自己的 66-bit accumulator。第 15 个 digit 同拍写入 16 个稳定的 `result_snapshot`，随后 core 拉低 busy 并脉冲输出 done。

这种结构以 16 个迭代 C 引擎替代原先四条、16 级完全展开且每条包含双通道的乘法流水。A/B 移位状态按 C 引擎局部复制，避免共享状态形成跨行列高扇出布线；首 digit 与后续 digit 共用同一套加法树。评测宏下例化的是 `matmul_batch_core`，数据通路使用 radix-4 shift/add，不使用 Verilog `*` 运算符，DSP 使用量为 0。

当前版本的本地完整实现及线上功能验证结果如下：

| 指标 | 原 16 级全流水基线 | 当前固定 C 引擎实现 |
|---|---:|---:|
| 整体布局 LUT | 63,415 | 42,537 |
| 整体布局 FF | 43,295 | 21,939 |
| 两个计算 core 的综合 LUT | 48,518 | 28,029 |
| 两个计算 core 的综合 FF | 33,195 | 11,897 |
| DSP | 0 | 0 |
| 本地实现 WNS | +0.908 ns | +0.118 ns |

5000 组全系统仿真中 `core-stall=0`、结果 word mismatch 为 0。当前清理前的 CPU-START 版本在线上随机 seed `0xd1245467` 下得到 CRC `0x056bb209`，CRC 匹配，elapsed time 为 5.039490 ms，得分 99.92；完整成绩日志也表示线上 lint、DSP=0 与 WNS>0 均通过。表中资源和 WNS 来自删除评测调试端口及硬件自动串口死逻辑后的本地重新实现；清理版仍需以新一轮线上结果确认最终 elapsed time。

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

DMA 提供只读的 `READ_GROUPS` 寄存器。当前软件的 `CRC_PREFIX_GROUP` 为 1582；CPU 观察到已读取 1582 组后，向 UART TX FIFO 写入：

```text
MATMUL_CRC32=
```

前缀与剩余 DMA/计算/CRC 时间重叠。CPU 随后轮询 DMA done 并读取最终 CRC32。当前 UART 的 TFE 状态在最后一个排队字符被 transmitter 取走时置位，因此 CPU 在 `=` 已进入 transmitter、尚未在线路上发送完成的一个字符时间内，把 8 位大写 CRC 和尾串的前 8 字节填满 16-entry FIFO；第二次 TFE 置位后再补入尾串剩余 5 字节。

这种两批写入保持以下物理字节流连续：

```text
MATMUL_CRC32=XXXXXXXX\nMATMUL_DONE\n
```

评测 UART 不再包含自主输出状态机或 DMA 的 START/CRC sideband。transmitter 在 stop bit 状态结束时，如果 FIFO 已有下一字节，则直接装载该字节并进入下一字符的 start bit。

## 5. 评测计时边界和并行关系

根据评测协议，线上平台收到完整 START 行后开始计时，收到完整 DONE 行后停止计时。当前硬件允许以下状态机并行运行：

```text
平台释放 reset
│
├─ CPU 在 start.S 提前写 MATMUL_START\n ──► 平台开始计时             │
├─ CPU 继续运行时初始化，与 START 物理发送重叠                         │
├─ UART TE=1 ─► CPU 写 DMA start ─► ExtRAM 读取、core 计算             │
│                                                                    │
├─ 后续 ExtRAM 读取 + 双 core 计算 + 已完成结果收集/CRC                │
├─ read_groups=1582 ─► CPU 提前发送 MATMUL_CRC32=                     │
│                                                                    │
└─ CRC ready ─► CPU 读 CRC ─► 8 hex + DONE ─► 平台停止计时 ◄────────┘
```

代码中的并行关系为：

- 平台保持 SoC 复位时，PLL 仍保持运行；
- CPU 在启动汇编中尽早发送 START，使物理发送与剩余初始化重叠；
- CPU 必须观察到 TE 后才写 DMA start，因此 START 完成前不会读取 ExtRAM；
- ExtRAM 读取与两个 core 的计算并行推进；
- DMA 读取已完成结果并更新 CRC 时，core 可处理后续输入；
- CPU 发送 CRC 前缀时 DMA、core 和 CRC 继续运行；
- CPU 的 done 轮询不参与矩阵计算或硬件 CRC 更新。

当前 CPU 驱动 START 版本已通过线上随机 seed 完整评测：seed `0xD1245467`，CRC32 `0x056BB209` 匹配，elapsed time `5.039490 ms`，得分 `99.92%`。按平台日志约定，该次评测同时表示 HDL lint、DSP=0 和 WNS>0 检查通过。elapsed time 会受单次平台波动影响，后续性能比较仍应保存并对照新的线上结果。

## 6. 面向评测时间的当前设计

### 6.1 控制路径

- 评测 tag/valid BRAM 使用冷启动无效初值，软件跳过重复 `cacop`；
- CPU 依赖固定评测复位参数，仅用一次 CTRL.start 写显式启动 DMA；
- START 由 CPU 在启动汇编中写入 UART FIFO，硬件自动 START 已禁用；
- 软件按读取组数提前安排 CRC 前缀，等待 done 后读取 CRC；
- 评测程序不包含 `printf`、软件 CRC、CPU 逐组搬运和结果读取；
- 平台按 115200 8N1 接收；UART 使用平均分频 26.9375 和 13-tick stop，评测时禁止启动代码清 TX FIFO；
- PLL 在外部复位期间保持运行，并在锁定后允许系统复位释放。

### 6.2 ExtRAM 双沿读路径

- 每个 50 MHz 周期读取两个连续 32-bit word；
- 16 个 pair 组成一组，5000 组共 80000 pair；
- START 完整发送后才拉起 `fast_read_active`；
- 物理层用独立的 180° 地址相位和采样时钟完成两个半周期读取；
- DMA 只按 `fast_pair_valid && fast_pair_ready` 推进；
- 全系统仿真中读取空泡和组首 core stall 均为 0。

### 6.3 矩阵计算路径

- 乘法运算保留在独立矩阵 IP 内，DMA 不复制计算资源；
- core 缓存 A/B，B32/B33 到达时处理 digit 0；
- A00 与 start 同拍旁路接收；
- 使用两个 core 交叠输入阶段和 15 周期迭代计算尾部；
- 16 个固定 C 引擎共用 16 个 radix-4 digit 周期，不使用 DSP；
- 每个引擎静态绑定一个 C 下标，不需要乘积 tag 或动态结果写交叉开关；
- A/B radix-4 状态局部化，首 digit 与后续 digit 共用加法树；
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

- START、CRC 前缀、CRC 数字和 DONE 均由 CPU 写 TX FIFO；
- START 完整发送且 TE 置位后，CPU 才启动 DMA；
- CRC 前缀在 `read_group_count>=1582` 时提前发送；
- CPU 使用 TFE 的“最后一个 FIFO 字节已被 transmitter 取走”语义及时补入下一批；
- TX FIFO 提前准备下一字节；
- stop bit 状态结束且 FIFO 非空时直接装载下一字符。

### 6.6 时序与结构精简

- CRC 输入前有一级 `crc_result_data/crc_result_valid` 寄存器；
- ExtRAM pair 地址由物理层连续生成；
- 当前评测分支例化两个 core；
- 使用固定 case 选择 16 个结果；
- 评测数据通路只保留输入读取、core 调度、结果排序和 CRC 所需状态；
- 复位 for-loop 内的数组初始化使用阻塞赋值。

## 7. 协议与完成条件

### 7.1 ExtRAM 快速读握手

- `fast_pair_valid` 有效时 `data0/data1` 对应相邻地址且只处理一次；
- `fast_pair_ready` 为低时物理层不得覆盖尚未接收的 pair；
- DMA 仅在 `fast_pair_valid && fast_pair_ready` 时推进 `read_pair`；
- 每组 16 个 pair 固定绑定同一 core；
- 当前评测分支保持未使用的 AXI master VALID 为低。

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
- 评测 UART 只有 CPU TX FIFO 写入口；CPU 必须保持 START、CRC 前缀、数字和 DONE 的顺序。

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

当前本地 `fpga/project/Loongson_Soc.xpr` 可直接复用。源码改变后必须重新运行实现流程，只有对应当前源码的新 WNS/DSP/资源报告才有效；仅在工程缺失、损坏或源文件集合失配时才运行 `fpga/create_project.tcl` 重建工程。

## 9. 关键源码位置

| 文件 | 评测相关职责 |
|---|---|
| `rtl/soc_top.v` | PLL/复位、评测 DMA、Matmul、UART 和 ExtRAM 桥连接 |
| `rtl/ip/DMA/matmul_dma.v` | CPU start、fast pair 读取进度、双 core 调度、有序结果收集、CRC32 |
| `rtl/ip/matmul/matmul_axi_slave.v` | 两个评测 core 的例化和 DMA stream 接口 |
| `rtl/ip/matmul/matmul_batch_core.v` | 评测分支例化的无 `*` 流式 4×4 矩阵乘法 core |
| `rtl/ip/Bus_interconnects/axi2sram_sp_external.v` | 连续 SRAM 地址发射、R FIFO、burst 链接 |
| `rtl/ip/APB_UART/URT/uart_top.v` | CPU 驱动的 UART TX 数据通路 |
| `rtl/ip/APB_UART/URT/uart_regs.v` | UART 整数/分数复位分频、空闲相位复位和 CPU TX FIFO 写入 |
| `rtl/ip/APB_UART/URT/uart_transmitter.v` | 字符位状态和相邻字符衔接 |
| `rtl/ip/ram_wrap/cache_sram.v` | 评测 cache tag/valid 的确定性冷启动无效初值 |
| `sdk/software/bsp/env/start.S` | CPU 尽早写入 START、评测快速启动和可关闭的 UART 软件初始化 |
| `sdk/software/examples/asm/user-sample.c` | 等待 START TE、DMA start、提前前缀、读取 CRC、发送 CRC/DONE |
| `fpga/create_project.tcl` | 本地验证前重新创建已过期的 Vivado 工程 |
