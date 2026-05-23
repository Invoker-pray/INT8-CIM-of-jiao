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
