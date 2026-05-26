# kv260 migration

这是设计第五阶段的部分，尝试通过移植到kv260获取更好性能，以及确认设计的灵活性。

# 硬件对比

我们之前使用的是PYNQ-Z2板子，首先来看一下两者的硬件规格对比。

| 规格           | PYNQ-Z2 7020(xc7z020)         | KV260(xck26 / ZU5EV)            |
| -------------- | ----------------------------- | ------------------------------- |
| 架构           | Zyqnnq-7000                   | Zynq UltraScale + MPSoC         |
| PS             | Cortex-A9 x 2(32-bit, 650MHz) | Cortex-A53 x 4 (64-bit, 1.3GHz) |
| LUT            | 53,200                        | 117,120(2.2x)                   |
| FF             | 106,400                       | 234,240(2.2x)                   |
| BRAM(36Kb)     | 140(4.9Mb)                    | 144(5.1Mb)                      |
| UltraRAM       | 0                             | 64(27Mb)                        |
| DSP            | 220                           | 1,248(5.7x)                     |
| PS DRAM        | 512MB DDR3                    | 4GB DDR4                        |
| PL clk source  | PS FCLK_CLK0                  | PS pl_clk0                      |
| PL default clk | none                          | 100MHz                          |
| AXI GP port    | M_AXI_GP0(32-bit)             | M_AXI_HPM0_FPD(128-bit)         |
| PS IP(vivado)  | processing_system7            | zynq_ultra_ps_e                 |
| Board part     | tul.com.tw:pynq-z2:part0:1.0  | xilinx.com:kv260_som:part0:1.4  |
| PMOD           | PMODA/PMODB <-> PL            | J2 PMOD, carrier                |
| PL LED         | 4                             | none                            |
| PYNQ install   | pynq + SD card                | Ubuntu22.04 + Kria-PYNQ         |
| vivado         | 2024.2                        | 2024.2                          |

可以发现，换成kria kv260，

- 可以获得5.7倍数量的DSP，在`PAR_OB=1`的情况下，只使用了大约55个DUT，换成kv260可以获得成倍的性能提升；

- UltraScale+工艺，可以放宽时序收敛条件，之前需要放宽到60MHz才能收敛的，在新板子上可能100MHz就可以收敛；

- 4GB DDR4，我们可以加载更大的模型，不再受限于PL BRAM，可以直接通过PS DDR加载；

- AXI 128bits，带宽也有4倍提升。

# immigration

关于将项目移植到Kira KV260.

关于原项目的所有RTL，还有PicoRV32的RTL和python，这些是纯粹的逻辑电路或者是算法，和FPGA型号无关，因此无需修改，具体包括如下内容：

```
hw/rtl
picorv32/hw/rtl
picorv32/fw
sw
```

需要改或者新写的内容有：

| files                                 | description                    |
| ------------------------------------- | ------------------------------ |
| kv260/hw/scripts/vivado_build.sh(tcl) | 需要修改一些端口，更新连接方式 |
| kv260/hw/constraints/cim_kv260.xdc    | 如有用到，还需要修改PMOD映射   |

## TCL

除了端口和连线，主要还是板型的修改：

```tcl
# PYNQ-Z2:
set PART       "xc7z020clg400-1"
set BOARD_PART "tul.com.tw:pynq-z2:part0:1.0"
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7
# 时钟: ps7/FCLK_CLK0
# AXI:  ps7/M_AXI_GP0
# 复位: ps7/FCLK_RESET0_N

# KV260:
set PART       "xck26-sfvc784-2LV-c"
set BOARD_PART "xilinx.com:kv260_som:part0:1.4"
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.5 ps_e
# 时钟: ps_e/pl_clk0
# AXI:  ps_e/M_AXI_HPM0_FPD
# 复位: ps_e/pl_resetn0
```

## XDC

由于连线和引脚完全不同，这一部分还需要查看文档之后再写。

# Kria KV260上板准备

## env

这里需要的硬件和之前几乎一致，只多一个供电方式：

- Kria KV260 Vision AI Starter Kit
- 12V/3A 电源适配器
- microSD card
- 网线
- micro USB线

首先去官网下载Ubuntu和PYNQ镜像。

Ubuntu镜像可以在[这里](https://people.canonical.com/~platform/images/xilinx/kria-ubuntu-22.04/) 或者[这里](https://ubuntu.com/download/amd#kria-k26)下载，文件名类似`iot-limerick-kria-classic-desktop-2204-****.img.xz`，下载完成之后可以用balenaetcher或者其他工具写入SD卡。

我下载的镜像叫：`iot-limerick-kria-classic-desktop-2204-20240304-165.img.xz`.

准备完镜像SD卡之后，将SD卡插入Kria KV260，连接电源和网线开机。

如果需要登录，默认用户名和密码都是`ubuntu`.

![kv260 login](../img/kv260-login.png)

这个系统默认是`NetworkManager`管理网络。

不过在没有路由器的环境中，可以先不进行Kria的联网。

首先我们把本地网卡设置为`192.168.2.1/24`，然后在串口中把Kria ip设置为`192.168.2.100/24`，pc修改具体方法可见`onboard_guide_PYNW-Z2.md`，kv260修改方式如下：

```bash
sudo ip addr flush dev eth0
sudo ip addr add 192.168.2.100/24 dev eth0
sudo ip route add default via 192.168.2.1
echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf
```

这样就实现了本地联通：

![ping1](../img/ping1.png)

```bash
ping 192.168.2.100 # pc
ping -c 2 8.8.8.8 # kv260

```

如果第二个ping不通，就需要让pc做NAT转发。

首先确认电脑网口名：

```bash
ip -br addr
```

由于我实际上用wifi联网，所以选择wlpxxx转发。此时有两个端口需要注意，wlpxxx用来转发网络，enpyyy也就是被改成`192.168.2.1`和kv260连接的网口接收转发的网络，命令如下:

```bash
sudo sysctl -w net.ipv4.ip_forward=1
sudo iptables -t nat -A POSTROUTING -o wlpxxx -j MASQUERADE
sudo iptables -A FORWARD -j ACCEPT
```

![ping2](../img/ping2.png)

在kv260内部可以ping通，则说明kv260已经通过网线借用了pc的网络。（和virtualbox有"**_同曲同工_**"之妙。）

**_一个补充信息，如果出现了本地stub没有上有DNS的问题(或者DNS被污染)导致`sudo apt-get update`或者下载某些包等命令执行失败，可以通过以下命令直接替换：_**

```bash
sudo rm /etc/resolv.conf
sudo sh -c 'echo "nameserver 8.8.8.8" > /etc/resolv.conf'
ping -c 1 ports.ubuntu.com
```

然后我们需要进入ubuntu系统，在系统中安装`Kria-PYNQ`：

```bash
git clone https://github.com/Xilinx/Kria-PYNQ.git
cd Kria-PYNQ
sudo bash install.sh -b KV260
```

_有人可能会问了，不配置proxy要怎么git clone？
当然要配proxy，不过这个知识太基础了，简单略过。如果不会，也可往下看。_

_还会有人问，这个下载好慢，我可以下完传过去吗？
当然是可以的，本地都ping通了。_

首先在pc上：

```bash
git clone https://github.com/Xilinx/Kria-PYNQ.git
scp -r Kria-PYNQ ubuntu@192.168.2.100:~/
```

这样就传过去了。（其实和`onboard_guide_PYNW-Z2.md`中的jupyter download有"**_同曲同工_**"之妙。简单的计算机网络知识。）

然后在kv260上：

```bash
cd ~/Kria-PYNQ
sudo bash install.sh -b KV260
```

进行安装。

如果scp因为和know host不同导致失败，其原因是之前对192.168.2.100这个ip使用过ssh，但是相关配置发生了变化，导致出现了污染，可以去PC的`.ssh/known_hosts`将相关的部分删除。

如果安装时有识别不了name or service的问题：`sudo unable to resolve host kria: Name or service not known`，其实就是hostname解析失败，这样的话只需要：

```bash
echo "127.0.0.1 $(hostname)" | sudo tee -a /etc/hosts
```

安装pynq完成之后我们就可以进行上板测试了。

首先把需要的文件传入kv260，然后加载bitstream，并且找到实际的uio编号。

```bash

# sudo fpgautil -b cim_soc_kv260.bit -o cim_soc_kv260.dtbo
  for uio in /sys/class/uio/uio*; do
    echo -n "$(basename $uio): addr="
    cat $uio/maps/map0/addr 2>/dev/null || echo "N/A"
    echo -n "  name="
    cat $uio/name 2>/dev/null || echo "N/A"
  done
```

找到之后在cim_driver.py中做对应修改，对上uio编号和地址。

# 如果不用官方的PYNQ环境安装脚本的话...

下一部分的内容就是思考不使用PYNQ的原因，简单来说就是22.04版本的镜像发现有启动问题，在某些情况下会神奇的在串口卡住，但是如果使用的是24.04版本，就会发现官方的PYNQ环境安装脚本写的居然是检测系统版本为20.04和22.04才会继续，虽然可以手动改成24.04也继续，但是会有一大堆不兼容问题，同时还有他的核心库不支持24.04，所以要有脱离PYNQ的手段（确信）

```bash
sudo apt-get update && sudo apt upgrade
sudo apt install -y python3-pip python3-venv

python3 -m venv ./python-venv
source python-venv/bin/activate
pip install numpy

# 其实上面可以用xmutil加载bitstream，下面是强行编译pynq
sudo apt install -y libdrm-dev libboost-dev
sudo apt install -y xrt xlnx-firmware 2>/dev/null
find /usr -name "libxlnk_cma.h" 2>/dev/null
# 如果没有找到这个，就可以考虑跳过下载这个文件，因为他是HDMI支持相关的，这里可以不用
pip install pynq

# 我们可以下载文件后修改设置自己安装

pip download pynq --no-binary pynq -d /tmp/pynq_src
cd /tmp/pynq_src
tar xzf pynq-*.tar.gz
cd pynq-*

sed -i '/_xhdmi/d' setup.py
pip install .
```

如果没有安装pynq也可以直接通过`xmutil`进行：

```bash
sudo mkdir -p /lib/firmware/xilinx/cim_soc_kv260
sudo cp cim_soc_kv260.bit cim_soc_kv260.dtbo /lib/firmware/xilinx/cim_soc_kv260
sudo touch /lib/firmware/xilinx/cim_soc_kv260/shell.json
cat << 'EOF' | sudo tee /lib/firmware/xilinx/cim_soc_kv260/shell.json
{
  "shell_type": "XRT_FLAT",
  "num_slots": 0,
  "shared_mem_addr": "0x0",
  "shared_mem_size": "0x0"
}
EOF

sudo xmutil unloadapp 2>/dev/null # 卸载bitstream
sudo xmutil loadapp cim_soc_kv260
```

还可以使用`sysfs`:

```bash
sudo mkdir -p /lib/firmware
sudo cp cim_soc_kv260.bit /lib/firmware

sudo sh -c 'echo cim_soc_kv260.bit > /sys/class/fpga_manager/fpga0/firmware'
```

_如果bitstream是full bitstream，就需要把fpga_manager的格式修改为full，方法是`echo 0 | sudo tee /sys/class/fpga_manager/fpga0/flags`_

_flags=20代表部分重配模式，flags=0代表full._

还有一些状态查询方式需要知道：

```bash
cat /sys/class/fpga_manager/fpga0/state # 查询加载状态
cat /sys/class/fpga_manager/fpga0/flags # 查询加载模式
```

另外测试中可能需要`.dtbo`文件，生成的命令是：

```bash
# 1. 创建 DTS 源文件
cat > /tmp/cim_kv260_overlay.dts << 'EOF'
/dts-v1/;
/plugin/;

/ {
    fragment@0 {
        target = <&fpga_full>;
        __overlay__ {
            firmware-name = "cim_soc_kv260.bit";
        };
    };
    fragment@1 {
        target = <&amba>;
        __overlay__ {
            #address-cells = <2>;
            #size-cells = <2>;

            cim_0: cim_top_wrapper@a0000000 {
                compatible = "xlnx,cim-top-wrapper-1.0";
                reg = <0x0 0xa0000000 0x0 0x4000>;
            };

            axi_dma_0: dma@b0000000 {
                compatible = "xlnx,axi-dma-7.1", "xlnx,axi-dma-1.00.a";
                reg = <0x0 0xb0000000 0x0 0x10000>;
            };
        };
    };
};
EOF

# 2. 编译为 .dtbo
source /home/jiao/xilinx/Vivado/2024.2/settings64.sh
dtc -I dts -O dtb -o
/home/jiao/git/INT8-CIM-of-jiao/kv260/deploy/cim_soc_kv260.dtbo
/tmp/cim_kv260_overlay.dts
```

**_ ZynqMP 的 PS-PL 桥接机制：_**

Linux 内核需要通过 Device Tree Overlay 通知 PMU固件去使能 PL 时钟和 AXI 接口。这在 Zynq-7000（PYNQ-Z2）上不存在，因为 Zynq-7000 的PL 时钟和 AXI 在 PL 配置完成后自动就绪。

具体步骤是：

```bash
# pc
scp /home/jiao/git/INT8-CIM-of-jiao/kv260/deploy/cim_soc_kv260.dtbo ubuntu@192.168.2.100:~/

# kria kv260
sudo rmdir /sys/kernel/config/device-tree/overlays/k26-starter-kits_image_1
sudo mount -t configfs configfs /sys/kernel/config 2>/dev/null # 做一次就行

sudo mkdir -p /sys/kernel/config/device-tree/overlays/cim
sudo cp cim_soc_kv260.dtbo /sys/kernel/config/device-tree/overlays/cim/dtbo

sudo modprobe uio_pdrv_genirq of_id="generic-uio"

#ls -la /dev/uio*
#cat /sys/class/uio/uio0/name
```

此外还需要写一个最小的内核模块来手动 enable PL时钟：

```bash
cat > ~/pl_enable.c << 'ENDOFFILE'
#include <linux/module.h>
#include <linux/of.h>
#include <linux/clk.h>

static struct clk *cim_clk;

static int __init pl_enable_init(void)
{
    struct device_node *np;
    np = of_find_compatible_node(NULL, NULL, "generic-uio");
    if (!np) {
        pr_err("pl_enable: no generic-uio node found — load dtbo first\n");
        return -ENODEV;
    }
    cim_clk = of_clk_get_by_name(np, "S_AXI_ACLK");
    if (IS_ERR(cim_clk)) {
        pr_err("pl_enable: no S_AXI_ACLK clock (err=%ld)\n", PTR_ERR(cim_clk));
        return PTR_ERR(cim_clk);
    }
    clk_prepare_enable(cim_clk);
    pr_info("pl_enable: S_AXI_ACLK enabled\n");
    return 0;
}

static void __exit pl_enable_exit(void)
{
    if (cim_clk && !IS_ERR(cim_clk))
        clk_disable_unprepare(cim_clk);
    pr_info("pl_enable: clock disabled, module removed\n");
}

module_init(pl_enable_init);
module_exit(pl_enable_exit);
MODULE_LICENSE("GPL");
ENDOFFILE



cat > ~/Makefile << 'ENDOFFILE'
obj-m := pl_enable.o

all:
      make -C /lib/modules/$(shell uname -r)/build M=$(PWD) modules

clean:
      make -C /lib/modules/$(shell uname -r)/build M=$(PWD) clean
ENDOFFILE

sed -i 's/^      /\t/' Makefile

cd ~ && make

sudo mkdir -p /sys/kernel/config/device-tree/overlays/cim

sudo cp /home/ubuntu/cim_soc_kv260.dtbo /sys/kernel/config/device-tree/overlays/cim/dtbo

sudo insmod pl_enable.ko
dmesg | tail -5

sudo cat /sys/kernel/debug/clk/clk_summary | grep pl0_ref
```

关于时钟问题的一些调试方法：

```bash
sudo cp ~/cim_soc_kv260.bit /lib/firmware/
echo 0 | sudo tee /sys/class/fpga_manager/fpga0/flags
sudo sh -c 'echo cim_soc_kv260.bit > /sys/class/fpga_manager/fpga0/firmware'


sudo mount -t debugfs none /sys/kernel/debug 2>/dev/null
ls /sys/kernel/debug/clk/pl0_ref/

# 尝试 enable（具体接口取决于内核版本）
echo 1 | sudo tee /sys/kernel/debug/clk/pl0_ref/clk_prepare_enable 2>/dev/null || \
echo 1 | sudo tee /sys/kernel/debug/clk/pl0_ref/enable 2>/dev/null

sudo cat /sys/kernel/debug/clk/clk_summary | grep pl0_ref
```

# 注意，以下内容为乌龙事件。

> 具体情况就是，kv260这个板子QSPI U-boot太旧了，对于部分比较新的高速卡并不兼容，而且即便是我用24.04进入系统之后手动更新一次固件，还是无法支持我的sd卡(sandisk extreme pro 64GB)，换了一张卡才搞定。因此以下内容都是没有什么实际意义的，但是还是保留下来了。

_这里有个问题，我安装22.04失败了才换成的24.04，结果脚本只支持到22.04，所以我只好进行一次危险的操作：把脚本的22.04改成24.04._

![compatible](../img/compatible.png)

还有很多问题，比如说还需要把所有`install.sh`的`python3.10`换成`python3.12`，因为新的镜像自带的是3.12...

可以把`/kv260/install.sh`用`scp -r install.sh ubuntu@192.168.2.100:~/`传到kv260.

_install 总归有一些pip和apt操作，所以可以换一下国内源进行加速。
当然这个也很基础，就不讲了。_

硬等也是可以完成安装的，除此之外，还可以把之前的`git clone`换成`git clone --recursive https://github.com/Xilinx/Kria-PYNQ.git`稍微加快一下。如果这样的话，通过`:%s/git clone/#git clone/g`屏蔽所有kv260 上的脚本的git clone节省时间。

在安装完成之后，可以访问JupyterLab，在浏览器中输入`http://<kv260_ip>:9090/lab`，密码是`xilinx`.

最后需要注意的是vivado版本不能太低，需要支持Kria KV260.

- _可能出现的问题：
  访问pypi如果网络很慢，就会导致下载失败。这个时候我们可以在pc下好，然后scp传过去。_

```bash
pip download pynqmetadata pynqutils pynq -d /tmp/pynq_pkgs/ --no-deps
scp -r /tmp/pynq_pkgs ubuntu@192.168.2.100:~/
```

在kv260上激活环境之后继续安装：

```bash
pip install  --find-links ~/pynq_pkgs pynqmetadata pynqutils pynq
```

- _如果还是无法安装，其实也不用下载这么多东西，只要下载pynq就好了：_

```bash
sudo apt update
sudo apt install -y python3-pip python3-venv

python3 -m venv ~/pynq-env
source ~/pynq-env/bin/activate

pip install pynq

python3 -c "from pynq import Overlay, MMIO; print('PYNQ OK')"
```

当然如果下载`pynq`失败了，也可以通过pc下好scp传过去：

```bash
pip download pynq -d ./pynq_pkgs

cp -r ./pynq_pkgs ubuntu@<kv260_ip>:~/
```

然后在kv260上面安装：

```bash
pip install --no-index --find-links ~/pynq_pkgs pynq
```

## another way（推荐路径）

22.04镜像启动时卡住（串口乱码/无响应）是KV260的**已知问题**：出厂时的2021.1 QSPI引导固件无法启动22.04镜像。解决方法：

**Step 1**: 先用24.04镜像开机（24.04兼容旧固件）

**Step 2**: 配好网络后更新QSPI固件：

```bash
sudo apt update
sudo xmutil bootfw_update -i /usr/lib/firmware/xilinx/kv26-starter-kits/*.bin
```

**Step 3**: 断电，换回22.04 SD卡，重新上电 → 应能正常启动

**Step 4**: 在22.04上正常安装Kria-PYNQ：

```bash
cd ~/Kria-PYNQ
sudo bash install.sh -b KV260
```

参考链接：

- [AMD官方固件更新指南](https://xilinx.github.io/kria-apps-docs/kv260/2022.1/linux_boot/ubuntu_22_04/build/html/docs/fwupdate.html)
- [element14社区：KV260 Boot Fix](https://community.element14.com/technologies/fpga-group/b/blog/posts/booting-ubuntu-22-04-in-kria-kv260-or-kr260)

### 备选方案：留在24.04 + pip install pynq

如果22.04仍然有问题，可以留在24.04，直接pip安装pynq核心：

```bash
sudo apt install -y python3-pip python3-venv
python3 -m venv ~/pynq-env
source ~/pynq-env/bin/activate
pip install pynq
python3 -c "from pynq import Overlay, MMIO; print('PYNQ OK')"
```

PYNQ的`MMIO`类本质上只是`/dev/mem` + `mmap`的封装，核心MMIO功能不依赖完整的Kria-PYNQ安装脚本。但Overlay自动加载比特流的功能可能不可用，需要改用`fpgautil`手动加载：

```bash
sudo fpgautil -b cim_soc.bit -o cim_soc.dtbo
```

### 最后备选：纯/dev/mem MMIO（零依赖）

如果PYNQ完全无法安装，可以用15行纯Python替代：

```python
import mmap, os, struct

class MMIO:
    def __init__(self, base_addr, length):
        f = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        self.mem = mmap.mmap(f, length, offset=base_addr)
        os.close(f)
    def read(self, offset):
        self.mem.seek(offset)
        return struct.unpack("<I", self.mem.read(4))[0]
    def write(self, offset, value):
        self.mem.seek(offset)
        self.mem.write(struct.pack("<I", value))
```

需要root权限运行。KV260上AXI基址为`0xA0000000`（不是PYNQ-Z2的`0x40000000`）。

## bitstream

可以选择移植ARM控制版本或者是PicoRV32控制的版本。ARM版本是PS直接通过AXI控制CIM，最简单，可以用于快速验证KriaKV260上能不能完成功能，而且验证也很简单，PYNQ notebook应该不用修改；如果选择PicoRV32，这就是PicoRV32控制PL自主推理，然后PS通过BRAM读出结果，可以完整展示RISC-V + CIM架构。

# 性能提升

KV260 的资源足以支持以下优化：

| 优化项            | 改什么                | 预期效果     |
| ----------------- | --------------------- | ------------ |
| `PAR_OB=4`        | `cim_pkg.sv` 一行     | 推理速度 ×4  |
| `PAR_OB=8`        | 同上                  | 推理速度 ×8  |
| 提频到 100MHz     | TCL 里 `FCLK_MHZ`     | 速度 ×2      |
| 提频到 150MHz+    | 可能需要加 MAC 流水线 | 速度 ×3      |
| `MAX_IN_DIM=1024` | `cim_pkg.sv`          | 支持更大网络 |

DSP 预算（cim_tile MAC 用量）：

| PAR_OB | DSP48 估算 | PYNQ-Z2 (220) | KV260 (1248) |
| ------ | ---------- | ------------- | ------------ |
| 1      | ~55        | ✓             | ✓            |
| 4      | ~220       | 刚好用完      | ✓ (18%)      |
| 8      | ~440       | ✗ 超了        | ✓ (35%)      |
| 16     | ~880       | ✗             | ✓ (70%)      |

# 性能对比

| 指标            | PYNQ-Z2 | KV260 |
| --------------- | ------- | ----- |
| 时钟频率        | 60 MHz  | ? MHz |
| PAR_OB          | 1       | ?     |
| MLP 推理 cycles | ~2700   | ?     |
| MLP 推理延迟    | ~45 μs  | ? μs  |
| LeNet-5 cycles  | ~76000  | ?     |
| LUT 占用        | 23%     | ?%    |
| DSP 占用        | 100%    | ?%    |
| BRAM 占用       | 46%     | ?%    |

# 需要注意的事情

- KV260没有板载LED，KV260的LED没有直连PL信号，LED都在PS MIO上，PL不能直接驱动，如果需要LED反馈，还需要连接外部LED到PMOD.

- KV260的PMOD连接和PYNQ-Z2完全不同。不过如果不需要UART TX，其实不约束PMOD pin也可以。

- AXI地址空间和PYNQ-Z2不同。PYNQ-Z2 的 `M_AXI_GP0` base 是 `0x4000_0000`，KV260 的 `M_AXI_HPM0_FPD` 默认映射到 `0xA000_0000`。PYNQ notebook 里的 `MMIO(0x40000000, ...)` 需要改为实际分配的地址。可以用 `ol.ip_dict` 查看。

另：相关文档比如官方XDC等可以在amd/xilinx官方文档站点下载。

比如：

- https://xilinx.github.io/kria-apps-docs/kv260/2022.1/build/html/docs/linux_boot.html

- https://docs.amd.com/v/u/en-US/dh339-kria-kv260-vision-ai-starter-kit
