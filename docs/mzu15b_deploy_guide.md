# MZU15B 上板部署指南

MZU15B-488A (XCZU15EG-FFVB1156-2-I) 是魔改板，没有 Xilinx 官方 BSP。本文档描述三种上板方式：ARM-direct (PetaLinux)、PicoRV32 (baremetal FW) 和 PYNQ/Ubuntu (通用 ARM64 rootfs)。

## 板子信息速查

| 项目     | 值                                                              |
| -------- | --------------------------------------------------------------- |
| 芯片     | XCZU15EG-FFVB1156-2-I                                           |
| DDR4     | 4×MT40A512M16LY-062E, 4GB, 64-bit, 2400T                        |
| 串口     | J2 (CP2104), MIO 34-35, 115200 8N1                              |
| SD卡     | MIO 13-16,21-22 (TF卡槽, MAX13035E 电平转换)                    |
| eMMC     | MIO 39-51 (MTFC8GAKAJCN-4M)                                     |
| 启动 DIP | SW1: SD卡 OFF-OFF-OFF-ON / QSPI ON-OFF-ON-ON / JTAG ON-ON-ON-ON |

## 三种方式对比

|                  | ARM-direct (PetaLinux)   | PicoRV32                   | PYNQ/Ubuntu                       |
| ---------------- | ------------------------ | -------------------------- | --------------------------------- |
| **控制核心**     | ARM A53 (PS)             | PicoRV32 (PL RISC-V)       | ARM A53 (PS)                      |
| **OS**           | PetaLinux (Yocto)        | 无 (baremetal FW)          | Ubuntu 22.04                      |
| **CIM 访问**     | /dev/mem @ 0xA0000000    | PicoRV32 直接 AXI          | /dev/mem @ 0xA0000000             |
| **Python**       | 内置 (rootfs)            | 无 (host 侧控制)           | apt/pip 安装                      |
| **PYNQ overlay** | 不需要                   | 不需要                     | pip install pynq                  |
| **构建复杂度**   | 中 (需 Docker)           | 低 (只需 Vivado bitstream) | 中 (依赖 PetaLinux + Ubuntu 下载) |
| **适用场景**     | 完整 Linux + Python 开发 | 纯 PL 推理 / 功耗测试      | Jupyter Notebook + PYNQ 生态      |

---

## 方式一：ARM-direct (PetaLinux)

### 思路

PS 端运行 PetaLinux，通过 AXI HPM0_FPD 直接 MMIO 访问 CIM IP (0xA0000000, 16K)。PetaLinux 的 boot 组件（FSBL/PMU/ATF/U-Boot/kernel/DTB）由 Vivado XSA 自动生成，包含正确的 DDR/MIO 配置。

```
PS (A53, PetaLinux) → AXI HPM0_FPD → CIM S_AXI (CSR + MMIO Data)
                                       CIM @ 0xA0000000 (16K)
```

### 步骤

**1. 构建 Vivado bitstream（host 侧，约 1 小时）**

```bash
cd /home/jiao/git/INT8-CIM-of-jiao
bash hw/scripts/vivado_build.sh
```

输出：`vivado_proj/deploy/cim_soc_mzu15b.{bit,hwh,xsa}`

**2. 构建 PetaLinux（Docker，约 30-60 分钟）**

```bash
cd cim_mzu15b
bash petalinux_build.sh
```

此脚本自动：发现 XSA → 拷贝 bitstream 到 hw-description → 运行 petalinux-config/petalinux-build → 打包 BOOT.BIN。

输出：`cim_mzu15b/images/linux/{BOOT.BIN, Image, system.dtb, boot.scr, rootfs.ext4}`

**3. 制作 SD 卡**

分区表：

| 分区 | 类型         | 大小     | 内容                                  |
| ---- | ------------ | -------- | ------------------------------------- |
| p1   | FAT32 (0x0c) | 512MB    | BOOT.BIN, Image, system.dtb, boot.scr |
| p2   | ext4 (0x83)  | 剩余空间 | PetaLinux rootfs                      |

```bash
sudo wipefs -a /dev/sdX
# 用 fdisk 分区，或用脚本：
# （参考 cim_mzu15b_ubuntu/build_ubuntu_sd.sh 的分区逻辑）

# sudo mkfs.vfat -F 32 /dev/p1
# sudo mkfs.ext4 -L rootfs /dev/p2


# 拷贝 boot 文件到 p1
cp cim_mzu15b/images/linux/BOOT.BIN /mnt/p1/
cp cim_mzu15b/images/linux/Image /mnt/p1/
cp cim_mzu15b/images/linux/system.dtb /mnt/p1/
cp cim_mzu15b/images/linux/boot.scr /mnt/p1/

# 解压 rootfs 到 p2
sudo tar -xzf cim_mzu15b/images/linux/rootfs.tar.gz -C /mnt/p2/

# 或者
sudo dd if=cim_mzu15b/images/linux/rootfs.ext4 of=/dev/sdX2 bs=512M
```

完成分区之后可以按照这样来写入sd卡：

```bash
sudo mkfs.vfat -F 32 /dev/sdb1
sudo mkfs.ext4 -L rootfs /dev/sdb2
sudo mount /dev/sdb1 /mnt/sdb1
sudo mount /dev/sdb2 /mnt/sdb2
sudo rm -rf /mnt/sdb1/* /mnt/sdb2/*
sudo cp cim_mzu15b/images/linux/Image /mnt/sdb1
sudo cp cim_mzu15b/images/linux/BOOT.BIN /mnt/sdb1
sudo cp cim_mzu15b/images/linux/system.dtb /mnt/sdb1
sudo cp cim_mzu15b/images/linux/boot.scr /mnt/sdb1
sudo tar -xzf cim_mzu15b/images/linux/rootfs.tar.gz -C /mnt/sdb2
sudo cp bitsream\&hwh_xczu15eg-ffvb1156-2-i /mnt/sdb2/home/petalinux/222 -r
cd sw
sudo cp cim_driver.py lenet5_data mlp_data golden_model.py scripts/benchmark_e2e.py /mnt/sdb2/home/petalinux -r
cd ..
sudo umount /dev/sdb1 /dev/sdb2
```

**4. 启动**

- 插入 SD 卡，DIP SW1 设为 OFF-OFF-OFF-ON
- 上电，J2 串口 115200 8N1 观察启动日志
- 登录：root/root

**5. 访问 CIM**

```python
import os, mmap, struct

fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
cim = mmap.mmap(fd, 0x4000, offset=0xA0000000)

# 读状态寄存器
status = struct.unpack('<I', cim[0x004:0x008])[0]
print(f'CIM status: 0x{status:08x}')
```

---

## 方式二：PicoRV32

### 思路

PS 仅负责：加载 firmware 到 FW BRAM、拉高 cpu_rst_n 释放 PicoRV32、从 Result BRAM 读取推理结果。PicoRV32 做 CIM 的全部控制和计算。

```
PS (A53, baremetal/FSBL)                  PicoRV32 (PL RISC-V)
  ├─ FW BRAM @ 0xA0000000 (32K, port B) ─→ 取指执行 firmware
  ├─ GPIO @ 0xA3000000 (bit0=cpu_rst_n) ─→ 释放/复位 PicoRV32
  └─ Result BRAM @ 0xA2000000 (4K) ←───── CIM 推理结果
                                               │
                                               └─→ CIM IP (同一 AXI slave)
```

### 步骤

**1. 构建 Vivado bitstream（host 侧，约 2.5 小时）**

```bash
cd /home/jiao/git/INT8-CIM-of-jiao
bash picorv32/hw/scripts/vivado_build_mzu15b.sh
```

输出：`picorv32/vivado_mzu15b_proj/deploy/cim_rv32_mzu15b.{bit,hwh,xsa}`

注：路由耗时约 114 分钟（congestion L6-L7，94% DSP），比 ARM 版本慢 3 倍。

**2. 编译 firmware**

```bash
cd picorv32/fw
make
# 生成 firmware.hex
```

**3. 上板流程**

用 XSCT / JTAG 或 baremetal 程序完成以下步骤：

```
1. 加载 bitstream 到 PL
2. PS 写 firmware.hex 到 FW BRAM (0xA0000000, port B)
   - fw_bram_ctrl 的 S_AXI 端口通过 AXI Interconnect 连到 PS HPM0_FPD
3. PS 写 GPIO (0xA3000000) bit0=1，释放 PicoRV32 复位
4. 等待 cim_done_irq 上升沿（或轮询 Result BRAM 中的状态标记）
5. PS 从 Result BRAM (0xA2000000) 读取推理结果
```

**PS 地址空间 (M_AXI_HPM0_FPD)**

| 地址       | 大小 | 用途                  |
| ---------- | ---- | --------------------- |
| 0xA0000000 | 32K  | FW BRAM               |
| 0xA2000000 | 4K   | Result BRAM           |
| 0xA3000000 | 4K   | GPIO (bit0=cpu_rst_n) |

---

## 方式三：PYNQ / Ubuntu

### 思路

MZU15B 没有 Xilinx 官方 BSP，标准 PYNQ 镜像的 DDR/device-tree 与此板不兼容。解决方案：

- **Boot 组件**仍然用 PetaLinux 生成的（知道正确的 DDR/MIO）
- **Rootfs** 用通用 Ubuntu 22.04 ARM64（从 cdimage.ubuntu.com 下载）
- **PYNQ** 通过 pip 安装（纯 Python 包，不依赖板级 overlay）
- **CIM 访问**通过 /dev/mem + mmap（Plan C，不需要 device-tree overlay）

```
PetaLinux boot 组件 (FSBL/PMU/ATF/U-Boot/kernel/DTB)
  └─→ 通用 Ubuntu 22.04 ARM64 rootfs
        ├─ Python3 + numpy + jupyter
        ├─ pip3 install pynq (可选)
        └─ /dev/mem CIM 驱动 @ 0xA0000000
```

### 为什么这样做

| 问题                           | 解决方案                                                                 |
| ------------------------------ | ------------------------------------------------------------------------ |
| 无 Xilinx BSP → DDR/MIO 不匹配 | PetaLinux boot 组件由 Vivado XSA 生成，DDR/MIO 正确                      |
| PYNQ 板级镜像 DDR 配置错误     | 不用板级镜像，pip install pynq（纯 Python，不依赖 DTB）                  |
| 无 device-tree overlay 支持    | Plan C: Python `os.open('/dev/mem')` + `mmap.mmap()` 直接读写 CIM 寄存器 |
| kernel module 签名/版本问题    | /dev/mem 不需要 kernel module，用户态直接访问物理地址                    |

### 步骤

**1. 先构建 PetaLinux（生成 boot 组件）**

方式和 ARM-direct 一样：

```bash
cd cim_mzu15b && bash petalinux_build.sh
```

**2a. 制作 Ubuntu SD 卡**

```bash
cd cim_mzu15b_ubuntu
bash build_ubuntu_sd.sh
```

脚本自动：下载 Ubuntu 22.04 ARM64 base rootfs → 配置 hostname/fstab/netplan/console → 拷贝 PetaLinux boot 组件 → 创建 SD 卡镜像（FAT32 boot + ext4 root）。

输出：`output/mzu15b_ubuntu_sd.img`

**2b. 制作 PYNQ SD 卡**

```bash
cd cim_mzu15b_pynq
bash build_pynq_sd.sh
```

脚本自动：调用 Ubuntu builder → 注入 PYNQ first-boot setup 脚本 → 创建 systemd 服务。

First-boot 自动执行：`apt-get install python3 python3-numpy jupyter` → `pip3 install pynq` → 部署 `/home/root/cim_driver/cim_driver.py`。

输出：`output/mzu15b_pynq_sd.img`

**3. 烧录 SD 卡**

```bash
sudo dd if=cim_mzu15b_pynq/output/mzu15b_pynq_sd.img of=/dev/sdX bs=4M status=progress
```

**4. 启动**

- 插入 SD 卡，DIP SW1 → OFF-OFF-OFF-ON
- 上电，J2 串口 115200 8N1
- 首次启动会自动运行 `pynq-firstboot.service`（约 5-10 分钟，需联网）
- 登录：root（无密码），建议首次登录后 `passwd` 修改

**5. 使用 CIM 驱动**

```bash
ssh root@<board-ip>
python3 /home/root/cim_driver/cim_driver.py
```

Python API：

```python
from cim_driver import CIMDriver

with CIMDriver() as cim:
    cim.configure(in_dim=784, out_dim=128)
    cim.write_weights(tiles)
    cim.write_inputs(inputs)
    cim.write_biases(biases)
    cim.start()
    cim.wait_done()
    result = cim.read_prediction()
```

## CIM Driver API (`cim_driver.py`)

所有三种方式都使用同一个寄存器映射（`cim_pkg.sv` 定义）：

| 方法                         | 说明                                    |
| ---------------------------- | --------------------------------------- |
| `configure(in_dim, out_dim)` | 设置输入/输出维度，自动计算 N_IB / N_OB |
| `write_weights(tiles)`       | 通过 WDMA 接口写入 INT8 weight tiles    |
| `write_inputs(inputs)`       | 写入 INT8 输入向量 @ MEM_INPUT_BASE     |
| `write_biases(biases)`       | 写入 INT32 bias @ MEM_BIAS_BASE         |
| `start()`                    | 写 CSR_CTRL bit0，触发推理              |
| `wait_done(timeout=1.0)`     | 轮询 CSR_STATUS bit1，等待完成          |
| `read_prediction()`          | 读取 CSR_PRED_CLASS (argmax 结果)       |

寄存器基址：`0xA0000000`，大小 `0x4000` (16K)。

## 时钟与参数

| 参数              | 值      |
| ----------------- | ------- |
| FCLK (PL0)        | 100 MHz |
| PAR_OB            | 13      |
| MAX_IN_DIM        | 3072    |
| MAX_OUT_DIM       | 1024    |
| TILE_SPLIT_FACTOR | 4       |

## PetaLinux 构建与定制

### 构建架构

```
run.sh (Docker 入口)
  └─ petalinux_build.sh (一键构建脚本)
       ├─ 1. 发现/拷贝 XSA → project-spec/hw-description/system.xsa
       ├─ 2. petalinux-config --get-hw-description (导入硬件)
       ├─ 3. petalinux-build (完整 Yocto 构建)
       └─ 4. petalinux-package --boot (打包 BOOT.BIN)
```

`run.sh` 只是 Docker 封装，所有构建逻辑在 `petalinux_build.sh`。项目配置持久化在 `project-spec/` 下，每次 `run.sh` 重新构建都会读取最新配置。

### 关键配置文件

| 文件                                                                    | 用途                                            | 修改后需执行              |
| ----------------------------------------------------------------------- | ----------------------------------------------- | ------------------------- |
| `project-spec/configs/rootfs_config`                                    | rootfs 包选择 (python, numpy, nvim 等)          | 重建 rootfs               |
| `project-spec/meta-user/recipes-bsp/device-tree/files/system-user.dtsi` | 设备树用户修改 (disable-wp, bootargs 等)        | 重建 device-tree          |
| `project-spec/configs/config`                                           | PetaLinux 顶层配置 (启动方式、根文件系统类型等) | `petalinux-config` 后重建 |

### 添加 Python 包 (rootfs_config)

rootfs 包在 `project-spec/configs/rootfs_config` 中通过 `CONFIG_<包名>=y` 启用。

**已为 MZU15B 启用的包：**

- `CONFIG_imagefeature-debug-tweaks=y` — 允许 root 免密登录
- `CONFIG_imagefeature-serial-autologin-root=y` — 串口自动登录 root
- `CONFIG_python3=y` — Python3.12 基础解释器
- `CONFIG_python3-core=y` — 核心内置模块
- `CONFIG_python3-io=y` — I/O 模块
- `CONFIG_python3-mmap=y` — mmap 模块 (/dev/mem 访问)
- `CONFIG_python3-fcntl=y` — fcntl 模块
- `CONFIG_python3-misc=y` — 杂项模块
- `CONFIG_python3-numpy=y` — NumPy

**添加更多包的方法：**

```bash
# 方法1: 直接在 rootfs_config 中搜索并修改
grep -n "CONFIG_<包名>" project-spec/configs/rootfs_config
# 将 # CONFIG_<包名> is not set 改为 CONFIG_<包名>=y

# 方法2: 交互式 menuconfig (在 Docker 内)
petalinux-config -c rootfs
# 进入后导航: Petalinux Package Groups → 选择需要的包
```

常用可添加包：`python3-numpy`、`nvim` (Neovim)、`git`、`openssh-sftp-server`。

### 添加设备树属性 (system-user.dtsi)

设备树用户修改在 `project-spec/meta-user/recipes-bsp/device-tree/files/system-user.dtsi`。

**MZU15B 已应用的关键修改：**

```dts
&sdhci0 {
    status = "okay";
    no-1-8-v;
    disable-wp;  // MZU15B SD卡槽 WP 引脚悬空，忽略写保护检测
};
```

### 增量重建

只修改了 rootfs_config 时无需全量重建（30-60 分钟），可以只重建相关组件：

```bash
# 在 Docker 内执行

# 只重建 device-tree（修改 system-user.dtsi 后）
source /home/jiao/xilinx/petalinux/settings.sh
petalinux-build -c device-tree

# 只重建 rootfs（修改 rootfs_config 后）
petalinux-build -c petalinux-image-minimal

# 重新打包 BOOT.BIN（修改 XSA/bitstream 后）
petalinux-package --boot --fsbl images/linux/zynqmp_fsbl.elf \
    --fpga <bitfile> --u-boot images/linux/u-boot.elf --force
```

### 构建输出

构建完成后所有产物在 `cim_mzu15b/images/linux/`：

| 文件            | 用途                                        | 应放到 SD 卡哪个分区     |
| --------------- | ------------------------------------------- | ------------------------ |
| `BOOT.BIN`      | FSBL + PMU + bitstream + ATF + U-Boot + DTB | p1 (FAT32)               |
| `Image`         | Linux 内核                                  | p1 (FAT32)               |
| `system.dtb`    | 设备树                                      | p1 (FAT32)               |
| `boot.scr`      | U-Boot 启动脚本                             | p1 (FAT32)               |
| `rootfs.tar.gz` | 根文件系统                                  | p2 (ext4), tar -xzf 解压 |

## 常见问题

**Q: 串口没有输出？**

- 确认 J2 是 CP2104 UART（不是 J1 JTAG）
- 确认波特率 115200 8N1
- 检查 DIP SW1 是否为 SD 卡启动 (OFF-OFF-OFF-ON)
- 用万用表量一下 CP2104 VCC (3.3V)

**Q: PetaLinux 启动卡在 "Starting kernel..."？**

- 检查 system.dtb 中的 console= 参数是否指向 ttyPS0
- 确认 XSA 中的 UART0 MIO 配置为 MIO 34-35

**Q: /dev/mem 访问报 Permission denied？**

- 需要 root 权限：`sudo python3 ...`
- 或者 `echo 0 > /proc/sys/kernel/devmem_restrict` (不推荐，安全风险)

**Q: /dev/mem 访问 0xA0000000 卡住 / RCU stall？**

- 检查 `PSU__USE__M_AXI_HPM0_FPD` 是否在 Vivado TCL 中设为 `{1}`
- 缺失会导致 PS 端 AXI HPM0_FPD 端口关闭，总线 hang
- 修复：在 `hw/scripts/vivado_build.tcl` 中添加 `CONFIG.PSU__USE__M_AXI_HPM0_FPD {1}` 并重建 bitstream

**Q: PYNQ first-boot 脚本没运行？**

- 检查网络：`ping 8.8.8.8`，apt/pip 需要联网
- 手动运行：`bash /home/setup_pynq.sh`
- 查看日志：`journalctl -u pynq-firstboot`

**Q: PicoRV32 WNS=+0.004ns 会不会不稳定？**

- 0.004ns = 4ps，非常临界。如果实际板子上工作异常（特别是高温），可能需要降频到 80MHz 或调整 placement strategy。
- ARM 版本 WNS=+0.318ns 有充足余量，可靠性更好。
