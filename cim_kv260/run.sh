docker build -t petalinux-builder:22.04 .

## Make sure host paths match the container paths
docker run --rm \
	--user 1000:1000 \
	-v /home/jiao/xilinx/petalinux:/home/jiao/xilinx/petalinux:ro \
	-v /home/jiao/git/INT8-CIM-of-jiao:/home/jiao/git/INT8-CIM-of-jiao \
	-w /home/jiao/git/INT8-CIM-of-jiao/cim_kv260 \
	petalinux-builder:22.04 \
	bash /home/jiao/git/INT8-CIM-of-jiao/cim_kv260/petalinux_build.sh
