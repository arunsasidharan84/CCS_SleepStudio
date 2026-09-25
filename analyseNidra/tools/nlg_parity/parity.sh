#!/bin/bash
RS=${RS:-../../target/release/examples/nlg_dump}
mkdir -p runs; : > parity.txt
for f in AS_CNT_08_Night1 AS_CNT_08_Night2 AS_CNT_10_Night1 AS_CNT_10_Night2; do
 E=${PSG_DIR:-.}/$f.edf
 for ch in "2 F3" "3 F4" "4 C3" "5 C4" "6 O1" "7 O2"; do set -- $ch
  for band in "sw 1 1.5 1.8" "sigma 14 3.5 1.8" "alpha 10 3.5 1.8"; do set -- $ch $band
   for rate in 0.01666 0.01; do
    tag=${f}_$2_$3_$rate
    mono ${REF:-nlgref.exe} $E $1 runs/ref_$tag.edf $4 $5 $6 $rate > runs/ref_$tag.log 2>&1
    $RS $E $2 runs/rs_$tag.edf $4 $5 $6 $rate > runs/rs_$tag.log 2>&1
    python3 cmp_edf.py runs/ref_$tag.edf runs/rs_$tag.edf >> parity.txt 2>&1
    rm -f runs/ref_$tag.edf runs/rs_$tag.edf
   done
  done
 done
done
echo DONE >> parity.txt
