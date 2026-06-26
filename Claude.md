# CLAUDE.md — ciciec2026_loongson_regional

## 项目概述

集成电路创新创业大赛（CICIEC 2026）龙芯中科杯区域赛决赛项目。基于 LoongArch32R SoC 平台，完成 4×4 无符号矩阵乘法加速器的 RTL 设计、BSP 驱动开发和评测程序编写。

### 核心任务

1. 在基础 SoC 上新增 RTL 矩阵乘法计算模块（不能纯软件完成）
2. 编写 C 驱动程序：从 ExtRAM 读取 5000 组 4×4 矩阵，驱动硬件完成乘法，写回结果，计算 CRC32，通过串口输出评测标识
3. 通过 CI/CD 流程生成 bitstream 和 `user-sample.bin`，在在线 FPGA 平台评测

### 评分规则

- CRC32 正确：基础 20 分
- 性能分 80 分：10ms 以内得满分，10s 以上得 20 分，中间按对数曲线映射
- 总超时 25 秒

## 目录结构

```
├── rtl/                          # RTL 源码
│   ├── soc_top.v                 # SoC 顶层模块
│   ├── config.h                  # AXI 总线宽度定义
│   ├── ip/
│   │   ├── matmul/               # ★ 矩阵乘法加速器 IP
│   │   │   ├── matmul_axi_slave.v        # 初始版本（需要改进优化）
│   │   ├── Bus_interconnects/
│   │   │   ├── AxiCrossbar_2x8.v  # SpinalHDL 生成的 2-master × 8-slave AXI 交叉开关
│   │   │   └── Axi_CDC.v          # AXI 时钟域交叉桥
│   │   ├── ram_wrap/              # AXI-to-SRAM 桥接
│   │   ├── confreg/               # 控制寄存器（LED、开关、定时器、中断控制器、数码管）
│   │   ├── APB_UART/              # UART 控制器
│   │   ├── DMA/                   # DMA 引擎
│   │   ├── DVI/                   # DVI 显示控制器
│   │   
│   │   
│   └── fpga/                      # FPGA 综合脚本、CI 检查脚本
├── sdk/
│   └── software/
│       ├── bsp/                   # 板级支持包
│       │   ├── common.mk          # 构建系统
│       │   ├── env/
│       │   │   ├── start.S        # 启动代码（初始化 cache、DMW、UART、异常）
│       │   │   ├── trap_handler.S # 异常/中断分发
│       │   │   ├── script.lds     # 链接脚本（isram: 0x1c000000, dsram: 0x1c080000）
│       │   │   └── convert.c      # bin → .coe/.mif/.vlog 转换工具
│       │   ├── include/           # 头文件
│       │   │   ├── common_func.h  # 基础类型（uint32_t 等）、RegRead/RegWrite、CSR/Cache 操作
│       │   │   ├── regdef.h       # LoongArch32 CSR 定义
│       │   │   ├── fft.h          # FFT 驱动
│       │   │   ├── dma.h          # DMA 驱动
│       │   │   ├── Kyber.h        # Kyber 驱动
│       │   │   ├── led.h          # LED 驱动
│       │   │   ├── seg7.h         # 数码管驱动
│       │   │   ├── dvi.h          # DVI 驱动
│       │   │   ├── confreg_time.h # 板级定时器
│       │   │   ├── core_time.h    # CPU 周期计数器
│       │   │   └── uart_print.h   # UART 打印宏
│       │   └── drivers/           # 驱动实现
│       └── examples/
│           └── asm/               # ★ 评测程序目录
│               ├── Makefile       # 构建配置（TARGET=user-sample）
│               └── user-sample.c  # ★ 评测主程序
├── docs/
    └── 2026集创赛龙芯中科杯-区域赛决赛描述.md  # 评测任务说明

```

## SoC 地址映射

| 地址范围 | 外设 | 说明 |
|----------|------|------|
| `0x1C00_0000` - `0x1C3F_FFFF` | BaseRAM | 4 MB，bit[22]=0 |
| `0x1C40_0000` - `0x1C7F_FFFF` | ExtRAM | 4 MB，bit[22]=1 |
| `0x1F00_0000` | UART | 串口控制器 |
| `0x1F10_0000` | DVI | 视频显示 |
| `0x1F20_0000` | ConfReg | GPIO/定时器/中断/LED/数码管 |
| `0x1F30_0000` | DMA | DMA 寄存器接口 |
| `0x1F40_0000` | FFT | FFT/IFFT 加速器（已丢弃） |
| `0x1F50_0000` | **Matmul** | ★ 矩阵乘法加速器 |
| `0x1F60_0000` | Kyber | NTT/INTT 加速器（已抛弃）|

CPU 通过 DMW 映射访问外设：物理 `0x1F______` → 虚拟 `0xBF______`（uncached）。

## 矩阵乘法器设计

### 寄存器接口

| 偏移 | 名称 | 说明 |
|-----:|------|------|
| `0x00` | CTRL | bit0: start（自清零脉冲） |
| `0x04` | STATUS | bit0: busy, bit1: done |
| `0x20`~`0x5C` | A_DATA[0..15] | 矩阵 A 输入窗口（16 个 uint32） |
| `0x60`~`0x9C` | B_DATA[0..15] | 矩阵 B 输入窗口（16 个 uint32） |
| `0xA0`~`0x15C` | C_DATA[0..47] | 矩阵 C 输出窗口（16 元素 × 3 word） |

### 计算流程

1. CPU 将 A[16] 和 B[16] 写入寄存器
2. 写 CTRL.bit0 = 1 启动计算
3. 硬件执行 4×4 无符号矩阵乘法，每元素 66-bit 累加（4 个 32×32 乘积累加）
4. 16 个时钟周期完成全部计算
5. CPU 轮询 STATUS.done，然后读取 C_DATA[0..47]

### 结果格式

每个 C[i][j] 为 66-bit 无符号数，拆成 3 个 32-bit word：

```
word0 = result[31:0]
word1 = result[63:32]
word2 = {30'b0, result[65:64]}
```

## 评测数据布局（ExtRAM）

```
偏移 0x00000000: 输入区（5000 组，每组 128 字节）
  每组: A[16] (64B) + B[16] (64B)
  总大小: 640000 字节 = 0x0009C400

偏移 0x0009C400: 结果区（5000 组，每组 192 字节）
  每组: C[16] × 3 word × 4B = 192B
  总大小: 960000 字节
  结束: 0x00186A00
```

## 评测串口输出格式

```
MATMUL_START
MATMUL_CRC32=XXXXXXXX
MATMUL_DONE
```

- 波特率 115200
- CRC32 为标准 IEEE CRC-32（多项式 0xEDB88320）
- 8 位十六进制，不带 `0x` 前缀
- 标识字符串区分大小写，前后无空格

## 开发注意事项

### RTL 约束

- **不允许使用 DSP 资源**（CI 会检查 `check_dsp.py`）
- **WNS 必须为正值**（CI 会检查 `check_timing.py`）
- 需通过 HDL lint 检查（本地暂不支持`rulinter.py`运行，只能在gitlab 线上检查）
- **不用考虑面积**（计算性能为核心目标）

### BSP 开发规范

- 外设驱动放在 `sdk/software/bsp/drivers/`，头文件在 `include/`
- 所有 MMIO 访问使用 `RegRead(addr)` / `RegWrite(addr, val)`
- 外设地址在 `0xBF______` 范围（uncached DMW 映射）
- 驱动命名：`Module_Verb_Object()` 风格（如 `MATMul_Write_A()`）
- 类型：使用 `uint32_t`、`S16`、`U16` 等（定义在 `common_func.h`）
- 新驱动需要在 `common.mk` 的 `C_SRCS` 中添加

### 构建系统

- 工具链：`loongarch32r-linux-gnusf-gcc`（GCC 8.3, LA32R soft-float）
- CFLAGS：`-nostartfiles -nostdlib -nostdinc -static -fno-builtin`
- 链接：picolibc（`-lsemihost`）
- 每个示例目录包含自己的 `Makefile`，设置 `TARGET` 和 `C_SRCS`，然后 `include ../../bsp/common.mk`
- 评测程序必须定义：`UART_BASE`、`CONFREG_TIMER_BASE`、`CONFREG_CLOCKS_PER_SEC`、`CORE_CLOCKS_PER_SEC`

### CI/CD 流程（GitLab）

1. 提交到 `ciciec_regional_submission_template/` GitLab 仓库
2. CI 合并 RTL 和 SDK 文件到发布包
3. 编译 C 程序生成 `user-sample.bin`
4. Vivado 综合实现 → 生成 bitstream
5. 运行 lint、DSP 检查、WNS 检查
6. 在线 FPGA 平台运行评测

## 本地开发工作流

根目录 Makefile 提供完整的本地开发流程，通过 batch 脚本自动化各步骤。
不要擅自在本仓库进行git提交。

### 顶层 Makefile 命令

```powershell
make help      # 显示帮助
make wsl       # 同步 SDK 到 WSL 并编译 user-sample.bin
make vivado    # 运行 Vivado 综合/实现/生成 bitstream
make checks    # 运行 DSP 使用量和时序检查
make gitlab    # 同步源码到 GitLab 提交仓库并推送（验证通过后再执行）
make all       # 依次执行以上所有步骤
make clean     # 清理构建产物
make status    # 检查所需脚本和文件是否存在
```

### Step 1: WSL 编译（`make wsl`）

**脚本**: `sync_wsl.bat`

- 将 `sdk/software/` 通过 robocopy 复制到 WSL Ubuntu-22.04
- WSL 路径：`/home/sapient610/loongson/sdk/software`
- 使用 zsh 执行 `make clean && make MATMUL_GROUP_NUM=5000 COPY_OUTPUT=0`
- 工具链 PATH：`/home/sapient610/loongson/sdk/toolchains/loongson-gnu-toolchain-8.3-*/bin`
- 产出：`sdk/software/examples/asm/obj/user-sample.bin`

### Step 2: Vivado 生成 Bitstream（`make vivado`）

**脚本**: `sync_vivado.bat`

- 运行 `fpga/run_all.tcl`（Vivado batch 模式）
- 流程：综合 → 实现 → 生成 bitstream → 复制到 `rtl/soc_top.bit`
- Vivado 工程：`fpga/project/Loongson_Soc.xpr`
- 产出：`rtl/soc_top.bit`

**TCL 脚本说明**:
| 脚本 | 用途 |
|------|------|
| `fpga/create_project.tcl` | 创建 Vivado 工程 |
| `fpga/run_all.tcl` | 完整流程（综合+实现+bitstream） |
| `fpga/run_impl.tcl` | 仅实现阶段 |
| `fpga/generate_bit.tcl` | 仅生成 bitstream |

### Step 3: 合规检查（`make checks`）

**脚本**: `run_checks.bat`

1. **HDL Lint**（`fpga/run-linter.py`）：本地暂不支持，CI 中执行
2. **DSP 使用量检查**（`fpga/check_dsp.py`）：解析 `fpga/project/dsp_utilization.rpt`，确保 DSP 使用量为 0
3. **WNS 时序检查**（`fpga/check_timing.py`）：解析 `fpga/project/Loongson_Soc.runs/impl_1/timing_summary.rpt`，确保 WNS > 0

**注意**: 需要先运行 `make vivado` 生成报告文件，检查脚本才能执行。

### Step 4: 同步到 GitLab（`make gitlab`）

**脚本**: `sync_gitlab.bat`

- 使用 robocopy 增量同步 `rtl/`、`sdk/software/bsp/`、`sdk/software/examples/asm/` 到 GitLab 提交仓库
- 目标仓库路径：`E:\Loongson\regional-submission-CICC1000627Rg`
- 目标分支：`dev/matmul`
- 自动 `git add`、`git commit`、`git push`

## 常用命令

```powershell
# 完整流程（推荐）
make all

# 分步执行（推荐顺序）
make wsl                             # 1. WSL 编译 user-sample.bin
make vivado                          # 2. Vivado 生成 bitstream
make checks                          # 3. 运行 DSP/时序检查
make gitlab                          # 4. 验证通过后同步并推送到 GitLab

# 仅编译 C 程序（WSL 环境下）
cd sdk/software/examples/asm
make clean && make MATMUL_GROUP_NUM=5000 COPY_OUTPUT=0


# 检查产物
ls -la rtl/soc_top.bit
ls -la sdk/user-sample.bin
```
