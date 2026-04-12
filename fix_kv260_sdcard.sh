sudo tee "/mnt/network-config" << 'EOF'
version: 2
ethernets:
    eth0:
        dhcp4: true
    end0:
        dhcp4: true
EOF

sudo tee "/mnt/meta-data" << 'EOF'
instance-id: kv260-dhcp-1
local-hostname: kria
EOF

