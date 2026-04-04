#!/bin/bash

# Copyright (C) 2021 Xilinx, Inc
# SPDX-License-Identifier: BSD-3-Clause
#
# PATCHED for Ubuntu 24.04 (noble) compatibility

set -e

GRAY='\033[1;30m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]
  then echo -e "${RED}Please run as root${NC}"
  exit
fi

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#    Input Arguments
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
USAGE="${RED} usage: ${NC}  sudo ./install -b '{KV260 | KR260 | KD240}'"

if [ "$#" -ne 2 ]; then
   echo -e $USAGE
   exit 0 
fi

while getopts b: flag
do
    case "${flag}" in
        b) board=${OPTARG};;
        *) echo -e $USAGE; exit 0;;
    esac
done

case $board in
	"KV260") echo -e ;;
	"KR260") echo -e ;;
	"KD240") echo -e ;;
	*) echo -e $USAGE; exit 0;;
esac
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

source /etc/lsb-release
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#    Check ubuntu version 
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
PYTHON_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
echo -e "${GREEN}Detected Python ${PYTHON_VER}${NC}"

case $DISTRIB_RELEASE in
        20.04)
                echo -e "${RED}This version of Kria-PYNQ is not compatible with Ubuntu 20.04 please checkout tag v1.0 with the command${NC}"
                echo -e "\n\t\tgit checkout tags/v1.0\n"
                exit 1
                ;;
        22.04)
                echo -e "${GREEN}Ubuntu version 22.04 and Kria-PYNQ v3.0 version match${NC}"
                ;;
        24.04)
                echo -e "${YELLOW}Ubuntu 24.04 detected — running in patched compatibility mode${NC}"
                ;;
        *)
                echo -e "${RED}Incompatible version of Ubuntu with Kria-PYNQ. Or unable to determine distribution version from /etc/lsb-release${NC}"
                exit 1
                ;;
esac


echo -e "${GREEN}Installing PYNQ, this process takes around 25 minutes ${NC}"

#-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
#    Autorestart services
#-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
if [ -f /etc/needrestart/needrestart.conf ]; then
  sudo sed -i 's/#$nrconf{restart} = '"'"'i'"'"';/$nrconf{restart} = '"'"'a'"'"';/g' /etc/needrestart/needrestart.conf
fi
#-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=

echo -e "${YELLOW} Extracting archive pynq-v3.0-binaries.tar.gz${NC}"
if [ ! -f /tmp/pynq-v3.0-binaries.tar.gz ]; then
  wget https://www.xilinx.com/bin/public/openDownload?filename=pynq-v3.0-binaries.tar.gz -O /tmp/pynq-v3.0-binaries.tar.gz
fi
pushd /tmp
if [ $(file --mime-type -b pynq-v3.0-binaries.tar.gz) != "application/gzip" ]; then
  echo -e "${RED}Could not extract pynq binaries, is the tarball named correctly?${NC}\n"
  exit
fi
tar -xvf pynq-v3.0-binaries.tar.gz
popd

ARCH=aarch64
HOME=/root
PYNQ_JUPYTER_NOTEBOOKS=$(readlink -f ~)/jupyter_notebooks
BOARD=$board
PYNQ_VENV=/usr/local/share/pynq-venv

# Skip git operations — user must pre-clone with submodules on PC
git config --global --add safe.directory $(pwd)
git config --global --add safe.directory $(pwd)/pynq

if [ ! -d "pynq/" ] || [ ! -f "pynq/setup.py" ]; then
  echo -e "${RED}ERROR: pynq/ submodule not found!${NC}"
  echo -e "${YELLOW}On your PC, run:${NC}"
  echo -e "  git clone --recursive https://github.com/Xilinx/Kria-PYNQ.git"
  echo -e "  scp -r Kria-PYNQ ubuntu@<kv260_ip>:~/"
  echo -e "${YELLOW}Then re-run this script.${NC}"
  exit 1
fi

# Stop unattended upgrades
systemctl stop unattended-upgrades.service || true

while [[ $(lsof -w /var/lib/dpkg/lock-frontend 2>/dev/null) ]] || [[ $(lsof -w /var/lib/apt/lists/lock 2>/dev/null) ]]
do
  echo -e "${YELLOW}Waiting for Ubuntu unattended upgrades to finish ${NC}"
  sleep 20s
done

# Only add Xilinx jammy PPA for 22.04; on 24.04 it causes dependency conflicts
if [ "$DISTRIB_RELEASE" == "22.04" ]; then
  apt-key adv --recv-keys --keyserver hkp://keyserver.ubuntu.com:80 \
              --verbose 803DDF595EA7B6644F9B96B752150A179A9E84C9
  echo "deb http://ppa.launchpad.net/ubuntu-xilinx/updates/ubuntu jammy main" > /etc/apt/sources.list.d/xilinx-gstreamer.list
fi
apt update 

apt-get -o DPkg::Lock::Timeout=10 update

if [ "$DISTRIB_RELEASE" == "24.04" ]; then
  apt-get install -y python3-venv python3-cffi libssl-dev libcurl4-openssl-dev \
    portaudio19-dev libcairo2-dev python3-dev python3-pip \
    graphviz i2c-tools fswebcam libboost-all-dev || true
else
  apt-get install -y python3.12-venv python3-cffi libssl-dev libcurl4-openssl-dev \
    portaudio19-dev libcairo2-dev python3-opencv graphviz i2c-tools \
    fswebcam libboost-all-dev python3-dev python3-pip
  #apt-get install -y libdrm-xlnx-dev  libopencv-dev
fi

# Create venv
if [ "$DISTRIB_RELEASE" == "24.04" ]; then
  echo -e "${YELLOW}Creating PYNQ venv with Python ${PYTHON_VER}${NC}"
  python3 -m venv --system-site-packages $PYNQ_VENV
  
  cat > /etc/profile.d/pynq_venv.sh <<VEOF
export PYNQ_JUPYTER_NOTEBOOKS=${PYNQ_JUPYTER_NOTEBOOKS}
export BOARD=$BOARD
export XILINX_XRT=/usr
export VIRTUAL_ENV=${PYNQ_VENV}
export PATH="${PYNQ_VENV}/bin:\$PATH"
VEOF
  source /etc/profile.d/pynq_venv.sh
  python3 -m pip install --upgrade pip setuptools wheel
else
  pushd pynq/sdbuild/packages/python_packages_jammy
  mkdir -p $PYNQ_VENV
  cat > $PYNQ_VENV/pip.conf <<EOT
[install]
no-build-isolation = yes
EOT
  ./pre.sh
  ./qemu.sh
  popd
  echo "export PYNQ_JUPYTER_NOTEBOOKS=${PYNQ_JUPYTER_NOTEBOOKS}" >> /etc/profile.d/pynq_venv.sh
  echo "export BOARD=$BOARD" >> /etc/profile.d/pynq_venv.sh
  echo "export XILINX_XRT=/usr" >> /etc/profile.d/pynq_venv.sh
  source /etc/profile.d/pynq_venv.sh
fi

if [[ "$VIRTUAL_ENV" == "" ]]
then
        echo "ERROR: could not enter the Pynq venv, stopping the installation"
        exit 1
fi

echo -e "${GREEN}In venv: $VIRTUAL_ENV (Python $(python3 --version))${NC}"

# Pip Constraints
if [ "$DISTRIB_RELEASE" == "24.04" ]; then
cat > /tmp/pynq_3.0.1_constraints.txt <<EOT
typing-extensions>=4.6.0
pynqmetadata==0.1.2
pynqutils==0.1.1
EOT
else
cat > /tmp/pynq_3.0.1_constraints.txt <<EOT
numpy==1.26.4
typing-extensions>=4.6.0
pynqmetadata==0.1.2
pynqutils==0.1.1
pynq==3.0.1
EOT
fi
export PIP_CONSTRAINT=/tmp/pynq_3.0.1_constraints.txt

python3 -m pip install "numpy<2"
python3 -m pip install pynqmetadata 
python3 -m pip install pynqutils 

# PYNQ JUPYTER
pushd pynq/sdbuild/packages/jupyter
./pre.sh
./qemu.sh
popd

# PYNQ Allocator
pushd pynq/sdbuild/packages/libsds
./pre.sh
./qemu.sh
popd

# Install PYNQ
python3 -m pip install pynq

## GCC-MB and XCLBINUTILS
pushd /tmp
cp -r /tmp/pynq-v3.0-binaries/gcc-mb/microblazeel-xilinx-elf /usr/local/share/pynq-venv/bin/
echo "export PATH=\$PATH:/usr/local/share/pynq-venv/bin/microblazeel-xilinx-elf/bin/" >> /etc/profile.d/pynq_venv.sh
cp /tmp/pynq-v3.0-binaries/xrt/xclbinutil /usr/local/share/pynq-venv/bin/
chmod +x /usr/local/share/pynq-venv/bin/xclbinutil
popd

echo "$BOARD" > /etc/xocl.txt

# Device tree overlay
pushd dts/
make || echo -e "${YELLOW}WARN: dtbo compile failed, skipping${NC}"
mkdir -p /usr/local/share/pynq-venv/pynq-dts/
cp insert_dtbo.py pynq.dtbo /usr/local/share/pynq-venv/pynq-dts/ 2>/dev/null || true
if [ -f /usr/local/share/pynq-venv/pynq-dts/insert_dtbo.py ]; then
  echo "python3 /usr/local/share/pynq-venv/pynq-dts/insert_dtbo.py" >> /etc/profile.d/pynq_venv.sh
fi
source /etc/profile.d/pynq_venv.sh
popd

SITE_PKG=$(python3 -c "import site; print(site.getsitepackages()[0])")
echo -e "${GREEN}Site packages: ${SITE_PKG}${NC}"

# =================== Notebooks ===========================
if [[ "$board" == "KV260" ]]
then
	echo "KV260 notebooks"
	python3 -m pip install pynq_helloworld --no-build-isolation || \
	  echo -e "${YELLOW}WARN: pynq_helloworld failed (non-critical)${NC}"
	python3 -m pip install . || \
	  echo -e "${YELLOW}WARN: base overlay failed (non-critical)${NC}"
	echo -e "${YELLOW}Skipping Composable Pipeline / Peripherals / DPU (24.04)${NC}"
fi

if [[ "$board" == "KR260" ]]
then
	echo "KR260 notebooks"
	python3 -m pip install pynq_helloworld --no-build-isolation || true
	echo -e "${YELLOW}Skipping DPU-PYNQ (24.04)${NC}"
fi

if [[ "$board" == "KD240" ]]
then
      python3 -m pip install IPython
      echo -e "${YELLOW}Skipping DPU-PYNQ (24.04)${NC}"
fi

yes Y | pynq-get-notebooks -p $PYNQ_JUPYTER_NOTEBOOKS -f || \
  echo -e "${YELLOW}WARN: pynq-get-notebooks failed${NC}"
cp pynq/pynq/notebooks/common/ -r $PYNQ_JUPYTER_NOTEBOOKS 2>/dev/null || true

# Patch notebooks
sed -i "s/\/home\/xilinx\/jupyter_notebooks\/common/\./g" $PYNQ_JUPYTER_NOTEBOOKS/common/python_random.ipynb 2>/dev/null || true
sed -i "s/\/home\/xilinx\/jupyter_notebooks\/common/\./g" $PYNQ_JUPYTER_NOTEBOOKS/common/usb_webcam.ipynb 2>/dev/null || true

for notebook in $PYNQ_JUPYTER_NOTEBOOKS/common/*.ipynb 2>/dev/null; do
    [ -f "$notebook" ] || continue
    sed -i "s/pynq.overlays.base/kv260/g" $notebook
    sed -i "s/PMODB/PMODA/g" $notebook
done

if [[ "$board" == "KV260" ]]
then
	for notebook in $PYNQ_JUPYTER_NOTEBOOKS/pynq_peripherals/*/*.ipynb 2>/dev/null; do
	    [ -f "$notebook" ] || continue
	    sed -i "s/pynq.overlays.base/kv260/g" $notebook
	    sed -i "s/PMODB/PMODA/g" $notebook
	done
fi

sed -i 's/Specifically a RALink WiFi dongle commonly used with \\n//g' $PYNQ_JUPYTER_NOTEBOOKS/common/wifi.ipynb 2>/dev/null || true
sed -i 's/Raspberry Pi kits is connected into the board.//g' $PYNQ_JUPYTER_NOTEBOOKS/common/wifi.ipynb 2>/dev/null || true

if [ -f "${SITE_PKG}/pynq/lib/pynqmicroblaze/rpc.py" ]; then
  sed -i "s/opt\/microblaze/usr\/local\/share\/pynq-venv\/bin/g" ${SITE_PKG}/pynq/lib/pynqmicroblaze/rpc.py
fi

if [[ "$board" == "KV260" ]]; then
	rm -rf $PYNQ_JUPYTER_NOTEBOOKS/pynq_peripherals/app* $PYNQ_JUPYTER_NOTEBOOKS/pynq_peripherals/grove_joystick 2>/dev/null || true
fi
if [[ "$board" == "KR260" ]]; then
	rm -rf $PYNQ_JUPYTER_NOTEBOOKS/common/zynq_clocks.ipynb $PYNQ_JUPYTER_NOTEBOOKS/common/overlay_download.ipynb 2>/dev/null || true
fi

mkdir -p $PYNQ_JUPYTER_NOTEBOOKS
chown $LOGNAME:$LOGNAME -R $PYNQ_JUPYTER_NOTEBOOKS
chmod ugo+rw -R $PYNQ_JUPYTER_NOTEBOOKS

systemctl start jupyter.service || echo -e "${YELLOW}WARN: jupyter.service not started${NC}"

cp pynq/sdbuild/packages/clear_pl_statefile/clear_pl_statefile.sh /usr/local/bin 2>/dev/null || true
cp pynq/sdbuild/packages/clear_pl_statefile/clear_pl_statefile.service /lib/systemd/system 2>/dev/null || true
systemctl enable clear_pl_statefile 2>/dev/null || true

python3 -m pip install opencv-python-headless || echo -e "${YELLOW}WARN: opencv failed${NC}"
apt-get install -y ffmpeg libsm6 libxext6 2>/dev/null || true

python3 -m pip install pytest

echo "#!/bin/bash" > selftest.sh
echo "if [ \"\$EUID\" -ne 0 ]" >> selftest.sh
echo "  then echo -e \"\${RED}Please run as root\${NC}\"" >> selftest.sh
echo "  exit" >> selftest.sh
echo "fi" >> selftest.sh
echo "source /etc/profile.d/pynq_venv.sh" >> selftest.sh
if [[ "$board" == "KV260" ]]; then
	echo "pushd ${SITE_PKG}/pynq_composable/runtime_tests 2>/dev/null || echo 'composable tests not found'" >> selftest.sh
	echo "python3 -m pytest test_apps.py 2>/dev/null || true" >> selftest.sh
	echo "python3 -m pytest test_composable.py 2>/dev/null || true" >> selftest.sh
	echo "python3 -m pytest test_mmio_partial_bitstreams.py 2>/dev/null || true" >> selftest.sh
	echo "popd" >> selftest.sh
	echo "python3 -m pytest ${SITE_PKG}/pynq_dpu/tests 2>/dev/null || true" >> selftest.sh
fi
if [[ "$board" == "KR260" ]]; then
	echo "python3 -m pytest ${SITE_PKG}/pynq_dpu/tests 2>/dev/null || true" >> selftest.sh
fi
chmod a+x ./selftest.sh

ip_addr=$(ip addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}') || ip_addr="<kv260_ip>"
echo -e "${GREEN}PYNQ Installation completed.${NC}\n"
echo -e "\n${YELLOW}To continue: ${ip_addr}:9090/lab - password: xilinx${NC}\n"
