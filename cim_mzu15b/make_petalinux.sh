docker build -t petalinux-builder:22.04 .

# 挂载时要保证宿主机路径名称和docker container一致
docker run --rm \
	--user 1000:1000 \
	-v /path/to/petalinux:/path/to/petalinux:ro \
	-v $(pwd):$(pwd) \
	-w $(pwd) \
	petalinux-builder:22.04 \
	bash $(pwd)/petalinux_build.sh
