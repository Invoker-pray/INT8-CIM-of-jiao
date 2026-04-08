rm -rf bitstream\&hwh .git
rm -rf sw/fw_hex_batch* sw/.venv
rm -rf picorv32/vivado_proj
rm -rf picorv32/fw/data picorv32/fw/small_mlp_data*
cd picorv32/fw
make clean
cd ../../
rm -rf clean_onlycode.sh
rm -rf img
