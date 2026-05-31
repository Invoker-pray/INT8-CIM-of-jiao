set -e

cd "$(dirname "$0")"

for svg in pics/*.svg; do
	base=$(basename "$svg" .svg)
	echo "Exporting $svg → pics/${base}.png"
	inkscape "$svg" --export-type=png --export-area-drawing --export-dpi=400 \
		--export-png-color-mode=RGBA_16 \
		--export-png-compression=0 \
		--export-filename="pics/${base}.png"
done

cd pics

source ~/python_venv/bin/activate && python energy_per_op.py && rm -rf energy_per_op.pdf && mv energy_per_op.png 1-2.png

#echo "Done. $(ls pics/*.svg | wc -l) files exported."

cd ..

python convert_images.py

xelatex paper.tex && biber paper && xelatex paper.tex && xelatex paper.tex
