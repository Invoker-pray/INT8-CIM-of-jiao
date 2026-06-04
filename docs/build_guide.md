# CIM SoC 多配置构建指南

## 环境要求

```bash
# Vivado 2024.2
source /home/jiao/xilinx/Vivado/2024.2/settings64.sh
cd ~/git/ce
```

## 构建命令一览

### ARM (PS) 模式

输出: `vivado_proj_<freq>/pynq_deploy/cim_soc_<freq>_par<PAR_OB>.{bit,hwh,xsa}`

| 频率 | PAR_OB | 时序 | 命令 |
|------|--------|------|------|
| 70 MHz | 2 | ✅ 闭合 | `PAR_OB_OVERRIDE=2 bash hw/scripts/vivado_build_70mhz.sh` |
| 70 MHz | 3 | ✅ 闭合 | `PAR_OB_OVERRIDE=3 bash hw/scripts/vivado_build_70mhz.sh` |
| **75 MHz** | **2** | ✅ 闭合 | `PAR_OB_OVERRIDE=2 bash hw/scripts/vivado_build_75mhz.sh` |
| **75 MHz** | **3** | ✅ **闭合 (198 DSP)** | `PAR_OB_OVERRIDE=3 bash hw/scripts/vivado_build_75mhz.sh` |
| 80 MHz | 2 | 常温可用 | `PAR_OB_OVERRIDE=2 bash hw/scripts/vivado_build_80mhz.sh` |
| 80 MHz | 3 | 常温可用 | `PAR_OB_OVERRIDE=3 bash hw/scripts/vivado_build_80mhz.sh` |
| 85 MHz | 2 | 待测试 | `PAR_OB_OVERRIDE=2 bash hw/scripts/vivado_build_85mhz.sh` |
| 90 MHz | 2 | 待测试 | `PAR_OB_OVERRIDE=2 bash hw/scripts/vivado_build_90mhz.sh` |
| 100 MHz | 2 | 超频 | `PAR_OB_OVERRIDE=2 bash hw/scripts/vivado_build_100mhz.sh` |

### PicoRV32 模式

输出: `picorv32/vivado_proj_<freq>/deploy/cim_rv32_soc_<freq>.{bit,hwh,xsa}`

| 频率 | PAR_OB | 时序 | 命令 |
|------|--------|------|------|
| **75 MHz** | **2** | ✅ **闭合 (推荐)** | `bash picorv32/hw/scripts/vivado_build_75mhz.sh` |
| 100 MHz | 1 | 超频 | `bash picorv32/hw/scripts/vivado_build_100mhz.sh` |

> PicoRV32 默认 PAR_OB=2。如需其他值，修改 `hw/rtl/pkg/cim_pkg.sv` 中 `PAR_OB` 参数后构建。

## 推荐构建顺序

```bash
# 1. 主力: PAR_OB=3, 75MHz (198 DSP, 时序闭合)
PAR_OB_OVERRIDE=3 bash hw/scripts/vivado_build_75mhz.sh

# 2. 对比: PAR_OB=2, 75MHz (134 DSP, 稳定基准)
PAR_OB_OVERRIDE=2 bash hw/scripts/vivado_build_75mhz.sh

# 3. 对比: PAR_OB=3, 80MHz (198 DSP, 常温可用)
PAR_OB_OVERRIDE=3 bash hw/scripts/vivado_build_80mhz.sh

# 4. PicoRV32 75MHz
bash picorv32/hw/scripts/vivado_build_75mhz.sh
```

## 输出目录结构

```
vivado_proj_<freq>/
└── pynq_deploy/
    ├── cim_soc_<freq>_par<PAR_OB>.bit   # FPGA配置比特流
    ├── cim_soc_<freq>_par<PAR_OB>.hwh   # 硬件握手文件 (PYNQ)
    └── cim_soc_<freq>_par<PAR_OB>.xsa   # Xilinx Shell Archive

picorv32/vivado_proj_<freq>/
└── deploy/
    ├── cim_rv32_soc_<freq>.bit
    ├── cim_rv32_soc_<freq>.hwh
    └── cim_rv32_soc_<freq>.xsa
```

## 查看结果

```bash
# 检查时序
grep "Worst Slack\|Setup.*Failing" vivado_proj_75mhz/timing_report.txt

# 检查资源
grep "DSPs\|Slice LUTs\|BRAM" vivado_proj_75mhz/utilization_report.txt

# 构建耗时约 20-30 分钟 (synth ~3min + impl ~17-27min)
```

## 已知限制

- PYNQ-Z2 仅 220 个 DSP48E1。PAR_OB=3 使用 ~198 DSP (90%)，PAR_OB=4 会超出预算
- 75 MHz 为最高时序闭合频率。80 MHz 常温可用但 WNS 为负 (~-0.8 ns)
- PicoRV32 仅支持 small_mlp (784→16→10)，权重需存储在 32KB FW BRAM 中
- build 脚本会自动将 PAR_OB 设置为目标值并在完成后恢复
