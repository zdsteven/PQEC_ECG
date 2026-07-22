# AGENTS.md — 线上矩阵乘法评测提速指南

## 项目目标

本项目的首要目标是提升 CICIEC 2026 龙芯中科杯区域赛线上矩阵乘法评测速度，尽可能缩短平台统计的 elapsed time、提高性能得分。

CRC32 正确、串口协议正确、AXI4 合规、DSP 使用量为 0、HDL lint 通过和 WNS 严格大于 0 是成绩有效的前提。后续 agent 应在这些约束内以速度为最高优化目标；如果更改能够稳定提高线上成绩，可以调整本文所列的临时调度结构，但必须同时更新代码、验证结果和本文说明。

当前工作区全程默认使用评测模式。后续 agent 只对线上评测系统及其直接数据通路工作，不开发、优化或验证其他模式和无关模块。同一源文件中如果包含多个宏分支，只修改当前评测分支；除非评测分支连接必须调整，否则不要改动未选中的实现。

## 当前临时评测流程

在用户给出新的调度方案前，后续 agent 将以下流程视为当前优化基线：

1. 启动汇编由 CPU 尽早把 `MATMUL_START\n` 写入 UART TX FIFO。
2. CPU 等待 START 最后一个 stop bit 完整发送后，写 CTRL.start 启动 `matmul_dma`。
3. DMA 从 ExtRAM 连续读取 5000 组 A/B，每个 50 MHz 周期交付两个 word。
4. 单个流式矩阵 core 让第 N 组计算与第 N+1 组输入重叠，保持每 16 周期一组。
5. DMA 按 group 顺序收集 66-bit 结果并在硬件中计算完整 CRC32。
6. CPU 显式安排 `MATMUL_CRC32=` 的提前发送时机。
7. DMA CRC32 就绪后，CPU 读取最终 CRC，并把 8 位十六进制字符紧接在前缀之后送入 UART。
8. 前缀和 8 位 CRC 在串口线上必须无缝连续，接收端不能观察到两者之间的时间间隔。
9. CRC 字符发送顺序建立后，由 CPU 显式打印 `MATMUL_DONE\n`。

目标串口字节流仍是：

```text
MATMUL_START
MATMUL_CRC32=XXXXXXXX
MATMUL_DONE
```

其中 `XXXXXXXX` 是最终 CRC32 的 8 位十六进制表示，不带 `0x`。当前约定使用大写字符。

上述 CPU/DMA/UART 分工是临时基线，不是禁止调整的固定架构。若线上证据表明其他调度能提高成绩，可以修改，但必须保证：

- START、CRC、DONE 的内容和顺序不变；
- `MATMUL_CRC32=` 与 8 位 CRC 在线路上没有可见空隙；
- DONE 不早于完整 CRC；
- CRC 与平台期望值一致；
- 修改后的 elapsed time 确有线上平台结果支持。

## 线上平台测试流程

线上平台按以下流程执行测试：

1. 按住复位。
2. 生成 5000 组 4×4 无符号矩阵乘法测试数据，其中非 0 组每次运行随机生成。
3. 在评测脚本内计算期望结果区 CRC32。
4. 向 BaseRAM 写入 `user-sample.bin`。
5. 向 ExtRAM 写入初始数据。
6. 配置并打开串口，波特率为 115200。
7. 松开复位并开始计时。
8. 等待串口输出 `MATMUL_START`。
9. 解析串口输出中的 `MATMUL_CRC32=XXXXXXXX`。
10. 等待串口输出 `MATMUL_DONE`，收到后立即停止计时。
11. 比对用户程序输出的 CRC32 与评测脚本计算的期望 CRC32。
12. 输出 CRC32 正确性、elapsed time 和得分。

优化时既要关注复位释放后的 CPU 启动与 DMA 启动延迟，也要关注 START、CRC 和 DONE 的物理串口发送时间。不要仅根据 RTL 内部 done 周期推断线上成绩。

## 线上平台输出格式

`make gitlab` 触发的 CI/线上验证通常先给出构建检查，再给出运行日志。后续 agent 应让用户回传完整日志，至少保留 seed、CRC、elapsed time、串口尾部和失败原因。

典型运行日志字段如下：

```text
Holding reset.
Preparing 5000 unsigned 4x4 matrix multiplication cases.
Random seed: 0xXXXXXXXX
Expected result CRC32: 0xXXXXXXXX
Writing user-sample.bin to BaseRAM.
Writing ExtRAM initial data: N bytes.
Opening serial port at 115200 baud.
Releasing reset and waiting for MATMUL_START.
Timing started.
Received MATMUL_START.
Received MATMUL_DONE. Timing stopped.
Elapsed time: X.XXXXXX ms
Reported CRC32: 0xXXXXXXXX
Expected CRC32: 0xXXXXXXXX
PASS/FAIL: ...
```

失败时常见附加字段：

```text
FAIL: Timeout: MATMUL_START was not received ...
FAIL: MATMUL_CRC32 was not received before MATMUL_DONE.
FAIL: CRC32 mismatch.
Serial tail: b'...'
```

CI 静态检查通常应关注：

```text
HDL lint check... passed/failed
DSP used: N, allowed: 0
Timing WNS check...
WNS: X.XXX ns
```

若失败，先按日志类型分类：

- lint/DSP/WNS 失败：先修复综合与实现问题，不进入运行时间分析；
- START 超时或串口乱码：检查 UART 初始化、FIFO、字符状态机和 CPU/UART 并发写入；
- CRC 前缀或 DONE 顺序错误：检查 CPU 调度、FIFO 入队顺序和发送完成判定；
- CRC mismatch：检查输入顺序、core 调度、结果顺序和 CRC 更新；
- CRC 正确但 elapsed time 变差：再分析真实空泡和不可重叠尾部。

## 验证工作流

### 首选：`make gitlab` 线上验证

评测提速以线上平台返回的 CRC、elapsed time 和得分为主要依据。完成有明确目的的修改并做必要静态检查后，优先在仓库根目录运行：

```powershell
make gitlab
```

为缩短实验周转时间，评测提速修改默认采用“线上先行、本地并行补验”的顺序：完成源码自检、必要 lint 或范围明确的单元仿真后，可以先运行 `make gitlab` 让线上任务进入排队，再继续执行耗时较长的本地 Vivado 综合、实现和完整仿真。线上评测通常比本地实现返回更晚，提前提交能够覆盖等待时间。

线上提交可视为实验草稿；即使后续本地检查或线上结果发现问题，也不需要为了保持远端每个版本都可用而延迟实验。用户最终会从各次结果中手动选择最满意的版本作为正式保留版本。但这不降低最终有效版本的要求：CRC、协议、lint、DSP=0 和 WNS>0 仍须全部通过，agent 也必须如实记录提交时尚未完成的本地验证，不能把草稿结果描述为已经验证成功。

该命令调用 `sync_gitlab.bat`，会把当前需要提交的源码同步到外部 GitLab 提交仓库并触发相应的线上流程。它是评测验证入口，不代表允许 agent 在当前工作区手工执行 Git 操作。

线上 GitLab 测试平台只接收并使用当前仓库的 `rtl/` 和 `sdk/` 文件。`fpga/`、`sim/`、`doc/`、根目录脚本以及其他目录中的修改不会被同步到线上评测环境，因此：

- `fpga/constraints/*.xdc` 只影响本地 Vivado 工程，不能改变线上综合实现所用的约束或线上 WNS；
- `fpga/` 下的工程、检查脚本和报告只用于本地诊断，不能把这些文件的修改当作线上修复；
- 需要在线上生效的功能、时序结构和 lint 修复必须落在平台接收的 `rtl/` 或 `sdk/` 中；
- 本地 `.xdc` 或工程调整得到的结果可以辅助分析，但不得据此宣称线上结果已经改善，仍须以 `make gitlab` 返回的线上 lint、DSP、WNS、协议和 elapsed time 为准。
- 修改 `rtl/ip/PLL_2019_2` 时，线上只上传 `clk_pll.xci`。不得上传该目录中的 `.vhdl`，也不要上传生成的 Verilog stub、仿真网表、DCP 或其他 output products；线上 lint 脚本会把 `.vhdl` 错误加入 Verilog 输入列表，从而在功能验证前直接报错。

运行 `make gitlab` 后：

1. 向用户说明已发送线上验证，以及本次需要重点观察的指标。
2. 不自行猜测线上结果。
3. 等待用户确认平台评测已经完成。
4. 评测完成后，优先在仓库根目录使用虚拟环境运行 `.\.venv\Scripts\python.exe cbor.py`，从最新 CBOR 截取中读取 UART 尾部、CRC 和调试计数；无需等待用户手工转抄这些字段。
5. 若 CBOR 不包含 elapsed time、得分或失败原因，再由用户补充相应平台结果。
6. 根据 CRC、elapsed time、得分、WNS、lint、DBG 计数或串口 tail 继续诊断。

用户负责判断修改是否有效，并负责在仓库中提交需要保留的更改。agent 不得为了“保存实验”而在当前仓库自行提交。

### 补充：本地 HDL lint

仓库 Python 虚拟环境已经安装 `lxml`、`chardet` 等依赖，MSYS2 Verilator 也已加入当前环境。RTL 修改后可以直接运行：

```powershell
.\.venv\Scripts\python.exe fpga/run-linter.py fpga/project/Loongson_Soc.xpr
```

本地 linter 中仅由 PLL/IP 仿真模型、PLL 黑盒或相关原语缺失产生的报错可以忽略，因为它们不影响线上评测；除此之外的 HDL lint、位宽、锁存、组合环和未驱动错误仍必须处理。最终仍以线上 lint 通过为准。

### 补充：本地仿真和实现分析

当线上日志不足以定位具体周期或握手问题时，使用本地仿真获得更详细反馈。仿真应根据问题选择观测信号，例如：

- CPU 写 DMA CTRL 的实际时刻；
- DMA ARVALID/ARREADY、RVALID/RREADY、RLAST；
- `read_group_count`、`read_beat` 和组首 core-ready 停顿；
- 单 core 的 start/input-busy/compute-active/done/result index；
- `calc_group_count`、CRC 输入 valid 和最终 CRC valid；
- CPU 发送 CRC 前缀、读取 CRC、写 8 位 hex 和打印 DONE 的周期；
- UART TX FIFO push/pop/count、字符状态和实际 TX 波形。

当前 `fpga/project/Loongson_Soc.xpr` 可以直接复用。进行本地 Vivado 仿真、综合或实现分析时，默认打开或调用现有工程，并确认工程引用的是当前 `rtl/`、`sim/` 和 `fpga/constraints` 源码；不要为了常规验证删除并重建工程。

评测 ExtRAM 完整 XSim 必须使用 `sim/sram.v` 的 10 ns 读延迟和约 149.516° 的 PLL 采样相位。零延迟 SRAM 与地址 ODDR/数据 IDDR 会产生仿真竞争并导致 pair 错位，不能据此判断线上 CRC。当前 5000 组固定输入完整仿真的参考 CRC 为 `0xDDA0905C`。

只有当工程文件缺失、损坏、源文件集合明显失配，或用户明确要求重新创建时，才运行 `fpga/create_project.tcl`。现有 run 生成的 WNS/DSP 报告只有在对应源码已经重新综合实现后才能作为依据；源码改变后需要生成 bitstream 和最新实现报告时，在仓库根目录运行 `make vivado`。

本地仿真用于解释线上结果，不能替代线上平台的最终速度和串口可靠性验证。若仓库没有覆盖目标路径的现成 testbench，可以添加范围明确的仿真 testbench，但不要把仅用于诊断的计数器或大段调试逻辑留在评测网表中。

### 补充：硬件计数器与线上串口调试

如果线上平台只有 elapsed time，无法判断时间消耗位于 ExtRAM、计算、CRC、CPU 调度还是 UART，可以制作专门的线上调试版本：

1. 在评测硬件内部加入 32-bit 周期计数器或关键事件时间戳。
2. 将计数器通过评测 DMA 的只读寄存器或现有状态接口提供给 CPU。
3. CPU 在任务完成后读取计数器，并在 `MATMUL_DONE` 之前通过 UART 输出固定格式的调试行。
4. 用户从线上平台的串口日志或 `Serial tail` 回传计数器结果。
5. 根据计数差值定位阶段耗时，完成定位后关闭或删除调试逻辑，再测试正式成绩。

可观测的事件包括：

- CPU 写 DMA start 的周期；
- 第一个 AR 握手和第一个 R word 退休周期；
- 最后一个输入 word 退休周期；
- R 通道有效握手总数和无握手周期数；
- 组首因 core not-ready 停顿的周期数；
- 最后一组 core done 周期；
- 最后一个结果进入 CRC 和最终 CRC valid 周期；
- CPU 开始发送 CRC 前缀、写入第一个/最后一个 CRC hex 和写入 DONE 的周期。

建议调试输出使用容易解析的固定十六进制格式，例如：

```text
MATMUL_START
MATMUL_CRC32=XXXXXXXX
DBG_CPU_START=XXXXXXXX
DBG_LAST_READ=XXXXXXXX
DBG_LAST_CORE=XXXXXXXX
DBG_CRC_VALID=XXXXXXXX
MATMUL_DONE
```

评测协议允许额外调试信息时，仍必须保持 START、CRC、DONE 的相对顺序，不能输出第二个 CRC，也不能拆开 `MATMUL_CRC32=XXXXXXXX`。调试字符位于 DONE 前，会增加 elapsed time，因此调试版本只用于定位，不用于比较最终得分；DONE 之后平台会立即结束测试，不能依赖 DONE 后的输出一定被采集。

计数器不能直接进入 AXI ready/valid、SRAM 地址、core result 或 CRC 的组合控制路径。优先使用寄存事件脉冲驱动计数，并用独立编译宏（例如 `EVAL_DEBUG_COUNTERS`）控制是否生成调试逻辑，正式测速版本默认关闭。

本地综合实现与静态检查命令：

```powershell
make wsl
make vivado
make check
```

- `make wsl` 构建 `user-sample.bin`；必须核对构建参数确实对应 5000 组和当前 UART 调度。
- `make vivado` 默认复用 `fpga/project/Loongson_Soc.xpr`，用于生成 bitstream 和当前实现报告；不要在每次编译前删除工程。
- `make check`（兼容别名 `make checks`）统一运行本地 HDL lint、DSP=0 和 WNS>0 检查；DSP/WNS 只对最新一次重新实现产生的报告有效，报告缺失时会提示先运行 `make vivado` 并返回失败。
- 本地 linter 也可单独运行；PLL 相关模型或黑盒报错可忽略，其他错误必须修复，线上 lint 仍是最终判据。

## 评测任务配置

正式软件必须处理 5000 组：

```text
MATMUL_GROUP_NUM=5000
```

当前仓库已经固定使用评测所需的硬件和 UART 启动配置。`user-sample` Makefile 默认 `MATMUL_EVALUATION=1`，`common.mk` 默认 0。后续 agent 只需确保自己的更改没有切换评测分支、没有在 CPU 写入 START 后清空 TX FIFO，也没有把正式组数改离 5000。

## 数据布局与 CRC 不变量

ExtRAM 输入区：

```text
物理基址：0x1C40_0000
组数：5000
每组：32 word = 128 byte
顺序：A[0..15]，随后 B[0..15]
总计：160000 word = 640000 byte = 0x0009C400
```

每组 stream 顺序为：

```text
A00, A01, A02, A03, A10, ... , A33,
B00, B01, B02, B03, B10, ... , B33
```

不要写成 A/B 交错输入。

每个输出为 66-bit 无符号值：

```text
C[i][j] = sum(k=0..3) A[i][k] * B[k][j]
```

每个 C 按三个 little-endian 32-bit word 进入 CRC：

```text
word0 = C[31:0]
word1 = C[63:32]
word2 = {30'b0, C[65:64]}
```

完整逻辑结果流为 5000 × 16 × 3 = 240000 word，第三个 word 的高 30 位必须为 0。

CRC 为 reflected IEEE CRC-32：

```text
初值：0xFFFFFFFF
多项式：0xEDB88320
最终异或：0xFFFFFFFF
顺序：group 0..4999 -> C index 0..15 -> word0, word1, word2
```

## 当前硬件热路径

### ExtRAM 快速读取

- 必须等 CPU 驱动 UART 完整发送 `MATMUL_START\n` 后，评测 DMA 才允许读取 ExtRAM。
- `axi_wrap_ram_sp_external.v` 的评测路径用相差 180° 的两个 50 MHz 相位发射相邻 word 地址，并用 IDDR 分别采样两个返回 word。
- 桥以 `fast_pair_valid/ready` 每个系统时钟向 DMA 交付一对连续 word；5000 组共 80000 对。
- DMA 仅在组首且单 core 尚未释放输入 busy 时反压，反压期间必须保持 pair 数据和地址进度不变。
- 原 CPU/通用 AXI 主读接口仍保留端口兼容性，但评测输入不经过 AXI R burst/FIFO 热路径。

### 单核流式乘法

- 评测路径只例化 core0。
- 一组第一对 A00/A01 与 stream start 同拍进入 core。
- A[0..15] 和 B[0..15] 到达时分别缓存。
- core 使用 16 个固定对应 C 元素的无 DSP 累加引擎，按 16 个 radix-4 digit plane 迭代计算；不展开 16 级乘法器流水线。
- 第 N 组发射后释放输入 busy，用私有计算状态与第 N+1 组装载重叠，稳态每 16 个 50 MHz 周期完成一组。
- 评测 core 乘法数据通路不使用 Verilog `*`，评测网表不允许 DSP。
- DMA 必须保持同组 32 word 连续送入 core。

### 结果排序和 CRC

- DMA 在每组最后一对输入、即计算发射点提交 core0 group 编号。
- core done 进入 pending 状态。
- `calc_group_count` 保证 CRC 按 group 0..4999 更新。
- 每组按 C index 0..15 读取结果。
- result mux 与 CRC 网络之间有一级 `crc_result_data/crc_result_valid` 寄存器。
- CPU 只能在最终 CRC 已有效后读取并格式化 8 位 hex。

### CPU 与 UART

- CPU 在启动汇编中写入 START，并等待 UART TE 后显式启动 DMA。
- START、CRC 前缀、CRC 数字和 DONE 都由 CPU 写 UART TX FIFO。
- CPU 提前发送 `MATMUL_CRC32=`，并在前缀仍在 UART 发送时等待或读取最终 CRC。
- CPU 必须及时把 8 位 CRC hex 补入 TX FIFO，保证前缀末字节 `=` 后直接衔接第一个 hex 字符。
- CPU 在 8 位 CRC 入队后显式打印 `MATMUL_DONE\n`；必须保持 FIFO 顺序，不能让 DONE 越过 CRC。

是否需要等待 THRE、FIFO 可写、发送器 idle 或其他状态，必须根据当前 UART 寄存器语义和仿真/线上结果确定，不能把 TFE 全空当作默认等待条件。

## 评测相关文件

| 文件 | 评测提速时需要关注的内容 |
|---|---|
| `rtl/soc_top.v` | PLL/复位、DMA、Matmul stream、UART 和 ExtRAM 连接 |
| `rtl/ip/DMA/matmul_dma.v` | CPU start、fast pair 读取、单核发射、结果排序、CRC32 和完成状态 |
| `rtl/ip/matmul/matmul_axi_slave.v` | 单个评测 core 的例化和 DMA stream 接口 |
| `rtl/ip/matmul/matmul_batch_core.v` | 无 DSP 流式矩阵计算 core |
| `rtl/ip/ram_wrap/axi_wrap_ram_sp_external.v` | ExtRAM 双相位地址、IDDR 采样和 fast pair 接口 |
| `rtl/ip/APB_UART/axi_uart_controller.v` | UART AXI/APB 封装和 CPU TX 路径 |
| `rtl/ip/APB_UART/URT/uart_top.v` | CPU 字节流发送控制 |
| `rtl/ip/APB_UART/URT/uart_regs.v` | TX FIFO 写入、状态位、复位默认值 |
| `rtl/ip/APB_UART/URT/uart_transmitter.v` | 字符位时序和连续字符衔接 |
| `rtl/ip/APB_UART/URT/uart_tfifo.v` | TX FIFO push/pop/count |
| `sdk/software/examples/asm/user-sample.c` | CPU 启动 DMA、提前发前缀、读 CRC、发 hex 和 DONE |
| `sdk/software/examples/asm/Makefile` | 5000 组和 `MATMUL_EVALUATION=1` 评测构建参数 |
| `sdk/software/bsp/env/start.S` | 统一宏选择 CPU START、快速 cache 启动或通用 UART 初始化 |
| `sdk/software/bsp/common.mk` | 默认 `MATMUL_EVALUATION=0` 的通用构建参数 |
| `sdk/software/bsp/drivers/matmul_dma.c` | DMA start/wait/status/CRC MMIO 驱动 |
| `sdk/software/bsp/include/matmul_dma.h` | DMA 地址、状态位和最大组数 |
| `doc/2026集创赛龙芯中科杯-区域赛决赛描述.md` | 任务、数据和串口协议 |
| `doc/矩阵乘法DMA加速器工作流程说明.md` | 当前硬件数据通路说明 |
| `fpga/check_dsp.py` | DSP=0 检查 |
| `fpga/check_timing.py` | WNS>0 检查 |
| `fpga/run-linter.py` | 本地与 CI HDL lint |
| `run_checks.bat` | `make check` / `make checks` 调用的本地 lint、DSP 和 WNS 统一检查入口 |
| `fpga/create_project.tcl` | 仅在现有 Vivado 工程缺失、损坏或源文件集合失配时重建工程 |
| `tools/generate_matmul_testdata.py` | A 后 B 布局的测试数据生成 |
| `Makefile`、`sync_gitlab.bat` | 首选线上验证入口和同步流程 |
| `cbor.py` | 线上评测完成后读取 CBOR 流程时间线、UART、CRC 和 DBG 信息，并跳过大块二进制内容 |

## 优化分析顺序

后续 agent 接到提速任务时：

1. 读取当前 RTL、SDK 和本文件，确认代码是否仍实现上述临时流程。
2. 保存上一版线上 seed、CRC、elapsed time、得分、WNS、lint 和串口 tail 作为基线。
3. 确认仍在评测分支、正式组数为 5000，CPU 启动过程没有重置 START 所在的 UART FIFO。
4. 根据线上日志或本地仿真定位一个明确空泡、等待或关键路径。
5. 一次只修改可归因的一类行为。
6. 做必要本地检查后优先运行 `make gitlab`。
7. 等待用户回传线上结果，再判断保留、调整或撤销。

重点检查：

- 复位释放到 CPU 写 DMA start 的软件周期；
- START 首字节、完整行到 CPU 写 DMA start 的 UART/软件周期；
- 80000 个 fast pair 的发射、返回、退休以及反压周期；
- 组首是否因单 core 输入 busy 未释放而停顿；
- 最后一组输入、乘法流水、结果排序和 CRC 的尾部；
- CPU 发送 CRC 前缀的提前量；
- 前缀末尾到第一个 CRC hex 是否真正无缝；
- CRC 最后字符到 DONE 的 CPU/FIFO 开销；
- 实现报告中的真实关键路径和高扇出网络。

不要以未运行的理论周期估算宣称提分。线上 elapsed time 和正确 CRC 是主要判据，本地波形和实现报告用于解释原因。

## 不可破坏的条件

### AXI4

- burst 最大 256 beat，不能跨 4 KiB。
- 只在 VALID && READY 时完成握手。
- RREADY 为低时保持 RVALID/RDATA/RID/RLAST 稳定。
- RLAST 必须与最后一个 beat 对齐，不能提前终止 burst。
- 下一 AR 的提前呈现不能造成重复接收或覆盖当前 burst 元数据。
- CPU-facing AXI slave 的 AW/W 是独立通道，不能假设同拍到达。

### 数学和 CRC

- 运算为 32-bit unsigned × unsigned，四项累加为 66 bit。
- 每个输入 word 和结果只能处理一次。
- CRC 顺序必须是 group、row-major C、low/mid/high word。
- 第三个结果 word 的高 30 位必须为 0。
- 下一组提前装载不能覆盖前一组计算状态或 group tag。
- CPU 读取的必须是最后一个结果已更新后的最终 CRC。

### UART

- START、CRC、DONE 必须完整且顺序固定。
- `MATMUL_CRC32=` 与 8 位 CRC 必须无缝连续。
- CPU 写入 START 后，启动代码不能清空 TX FIFO。
- 评测 UART 只使用 CPU TX 写入口，字节入队顺序必须与协议一致。
- DONE 只能排在完整 8 位 CRC 之后。
- 波特率和 start/data/stop 位必须能被平台 115200-baud 接收端识别。

### 综合与时序

- 评测网表 DSP 使用量必须为 0。
- WNS 必须严格大于 0；`0.000 ns` 也失败。
- HDL lint 必须通过。
- 修改流水级时同步调整 valid、last、tag、group 和完成信号。
- 避免在 ready/valid、地址、result mux、CRC 和 UART 状态之间形成长组合链。
- reset for-loop 中的数组赋值必须使用 CI linter 支持的形式。

## 每次线上实验的记录模板

```text
Holding reset.
Preparing 5000 unsigned 4x4 matrix multiplication cases.
Random seed: xxxxxxxxxx
Expected result CRC32: xxxxxxxxxx
Writing user-sample.bin to BaseRAM.
Writing ExtRAM initial data: 1600000 bytes.
Opening serial port at 115200 baud.
Releasing reset and waiting for MATMUL_START.
Timing started.
Received MATMUL_START.
Received MATMUL_DONE. Timing stopped.
Elapsed time: x.xxxxx ms
Reported CRC32: xxxxxxxxxx
Expected CRC32: xxxxxxxxxx
CRC32 matched.
Score percent: xx.xxx
```

出现该回传日志默认WNS、DSP 和 lint通过，否则会特别指出

## Git 与工作区纪律

- 可以按本文件的验证工作流运行 `make gitlab`，把实验发送到线上测试流程。
- 不得在当前仓库手工执行 `git add`、`git commit`、`git push`、merge、rebase 或 tag。
- `make gitlab` 内部对外部提交仓库的同步行为只用于线上验证，不等于授权修改当前仓库的 Git 历史。
- 用户负责在线上平台查看结果，并负责提交最终确认有效的更改。
- agent 修改后保留工作区差异，向用户说明改动和待观察指标。
- 不使用 `git reset --hard`、`git checkout --` 等破坏性命令。
- 不覆盖用户已有的无关改动。
- 搜索优先使用 `rg`/`rg --files`，编辑使用 `apply_patch`。
