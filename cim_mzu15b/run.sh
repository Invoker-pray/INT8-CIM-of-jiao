docker build -t petalinux-builder:22.04 .

## 挂载时要保证宿主机路径名称和docker container一致
docker run --rm \
	--user 1000:1000 \
	-v /home/jiao/xilinx/petalinux:/home/jiao/xilinx/petalinux:ro \
	-v /home/jiao/git/INT8-CIM-of-jiao:/home/jiao/git/INT8-CIM-of-jiao \
	-w /home/jiao/git/INT8-CIM-of-jiao/cim_mzu15b \
	petalinux-builder:22.04 \
	bash /home/jiao/git/INT8-CIM-of-jiao/cim_mzu15b/petalinux_build.sh
