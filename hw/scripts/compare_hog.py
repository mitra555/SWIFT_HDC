"""Compare hog_top RTL output (Q16.16) against real cv2.HOGDescriptor, per frame."""
import sys
import numpy as np
import cv2

frames_txt, rtl_txt = sys.argv[1], sys.argv[2]
pix = np.array(open(frames_txt).read().split(), dtype=np.int64)
frames = pix.reshape(-1, 32, 32).astype(np.uint8)

hog = cv2.HOGDescriptor(_winSize=(32, 32), _blockSize=(16, 16), _blockStride=(8, 8),
                        _cellSize=(8, 8), _nbins=9)

rows = [l.split() for l in open(rtl_txt) if l.strip()]
all_err = []
for f, row in enumerate(rows):
    rtl = np.array(row, dtype=np.int64) / 65536.0
    ref = hog.compute(frames[f]).flatten().astype(np.float64)
    err = rtl - ref
    lsb = np.abs(np.round(rtl * 65536) - np.round(ref * 65536))
    all_err.append(err)
    worst = int(np.argmax(np.abs(err)))
    print(f"frame {f}: n={len(ref)} max|err|={np.abs(err).max():.6f} ({lsb.max():.0f} LSB)  "
          f"mean|err|={np.abs(err).mean():.6f}  corr={np.corrcoef(rtl, ref)[0,1]:.8f}  "
          f"exact(<=1LSB)={np.mean(lsb <= 1)*100:.1f}%  worst idx={worst} rtl={rtl[worst]:.5f} ref={ref[worst]:.5f}")
e = np.concatenate(all_err)
print(f"ALL: max|err|={np.abs(e).max():.6f}  mean|err|={np.abs(e).mean():.6f}  "
      f"p99|err|={np.percentile(np.abs(e), 99):.6f}  ref range=[{0:.3f}, {np.max(np.abs(e))+0:.3f}]")
