# KV260 xck26 EV variant does not expose VCU on the SOM
# Remove hwcodecs which pulls in libvcu-omxil (requires 'vcu' MACHINE_FEATURE)
IMAGE_FEATURES:remove = "hwcodecs"
MACHINE_HWCODECS = ""
