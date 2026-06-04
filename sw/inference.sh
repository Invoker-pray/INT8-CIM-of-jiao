# DATA_DIR mlp_data_* small_mlp_data_* lenet5_data* 
# MODEL mlp(include mlp & small mlp) lenet5
# BITSTREAM ???

export DATA_DIR='small_mlp_data_41'
export MODEL='mlp'
export BITSTREAM='cim_soc_80mhz.xsa'
export FREQ='80'

#python benchmark_e2e.py --model $MODEL --data_dir $DATA_DIR --use-dma --batch --bitstream $BITSTREAM
#
#python benchmark_e2e.py --model $MODEL --data_dir $DATA_DIR --use-dma --batch --no-fusion --bitstream $BITSTREAM
#
#python benchmark_e2e.py --model $MODEL --data_dir $DATA_DIR --use-dma --bitstream $BITSTREAM
#
#
#python benchmark_e2e.py --model $MODEL --data_dir $DATA_DIR --bitstream $BITSTREAM
#
#DATA_DIR='small_mlp_data_42'
#python benchmark_e2e.py --model $MODEL --data_dir $DATA_DIR --use-dma --batch --bitstream $BITSTREAM
#
#python benchmark_e2e.py --model $MODEL --data_dir $DATA_DIR --use-dma --batch --no-fusion --bitstream $BITSTREAM
#
#python benchmark_e2e.py --model $MODEL --data_dir $DATA_DIR --use-dma --bitstream $BITSTREAM
#
#
#python benchmark_e2e.py --model $MODEL --data_dir $DATA_DIR --bitstream $BITSTREAM
#
#DATA_DIR='mlp_data_41'
#python benchmark_e2e.py --model $MODEL --data_dir $DATA_DIR --use-dma --batch --bitstream $BITSTREAM
#
#python benchmark_e2e.py --model $MODEL --data_dir $DATA_DIR --use-dma --batch --no-fusion --bitstream $BITSTREAM
#
#python benchmark_e2e.py --model $MODEL --data_dir $DATA_DIR --use-dma --bitstream $BITSTREAM
#
#
#python benchmark_e2e.py --model $MODEL --data_dir $DATA_DIR --bitstream $BITSTREAM
#
#DATA_DIR='mlp_data_42'
#
#python benchmark_e2e.py --model $MODEL --data_dir $DATA_DIR --use-dma --batch --bitstream $BITSTREAM
#
#python benchmark_e2e.py --model $MODEL --data_dir $DATA_DIR --use-dma --batch --no-fusion --bitstream $BITSTREAM
#
#python benchmark_e2e.py --model $MODEL --data_dir $DATA_DIR --use-dma --bitstream $BITSTREAM
#
#
#python benchmark_e2e.py --model $MODEL --data_dir $DATA_DIR --bitstream $BITSTREAM
#
#DATA_DIR='lenet5_data_41'
MODEL='lenet5'
#python benchmark_e2e.py --model $MODEL --data_dir $DATA_DIR --use-dma --batch --bitstream $BITSTREAM
#
#python benchmark_e2e.py --model $MODEL --data_dir $DATA_DIR --use-dma --batch --no-fusion --bitstream $BITSTREAM
#
#python benchmark_e2e.py --model $MODEL --data_dir $DATA_DIR --use-dma --bitstream $BITSTREAM
#
#
#python benchmark_e2e.py --model $MODEL --data_dir $DATA_DIR --bitstream $BITSTREAM
DATA_DIR='lenet5_data_42'
python benchmark_e2e.py --model $MODEL --data_dir $DATA_DIR --use-dma --batch --bitstream $BITSTREAM

python benchmark_e2e.py --model $MODEL --data_dir $DATA_DIR --use-dma --batch --no-fusion --bitstream $BITSTREAM

python benchmark_e2e.py --model $MODEL --data_dir $DATA_DIR --use-dma --bitstream $BITSTREAM


python benchmark_e2e.py --model $MODEL --data_dir $DATA_DIR --bitstream $BITSTREAM


#python benchmark_sw_baseline.py --model mlp --data-dir mlp_data_41 --hw-csv-dir results --freq $FREQ --bitstream $BITSTREAM
#
#python benchmark_sw_baseline.py --model mlp --data-dir mlp_data_42 --hw-csv-dir results --freq $FREQ --bitstream $BITSTREAM
#
#python benchmark_sw_baseline.py --model small_mlp --data-dir small_mlp_data_41 --hw-csv-dir results --freq $FREQ --bitstream $BITSTREAM
#
#
#python benchmark_sw_baseline.py --model small_mlp --data-dir small_mlp_data_42 --hw-csv-dir results --freq $FREQ --bitstream $BITSTREAM
#
#
#python benchmark_sw_baseline.py --model lenet5 --data-dir lenet5_data_41 --hw-csv-dir results --freq $FREQ --bitstream $BITSTREAM


python benchmark_sw_baseline.py --model lenet5 --data-dir lenet5_data_42 --hw-csv-dir results --freq $FREQ --bitstream $BITSTREAM


