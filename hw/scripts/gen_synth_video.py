import numpy as np
import cv2

np.random.seed(99)
FRAME_SIZE = 32
NUM_FRAMES = 4

frames = []
base = (np.random.RandomState(1).uniform(40, 90, size=(FRAME_SIZE, FRAME_SIZE))).astype(np.float32)
for t in range(NUM_FRAMES):
    f = base.copy()
    cy, cx = 8 + t*3, 8 + t*2
    yy, xx = np.meshgrid(np.arange(FRAME_SIZE), np.arange(FRAME_SIZE), indexing='ij')
    blob = 120*np.exp(-(((yy-cy)**2+(xx-cx)**2)/30.0))
    f = f + blob
    f = f + np.random.RandomState(100+t).uniform(-2,2,size=(FRAME_SIZE,FRAME_SIZE))
    f = np.clip(f, 0, 255).astype(np.uint8)
    frames.append(f)

with open("synth_frames.txt","w") as fo:
    for f in frames:
        for v in f.flatten():
            fo.write(f"{int(v)}\n")

print("wrote", NUM_FRAMES, "frames of", FRAME_SIZE, "x", FRAME_SIZE, "to synth_frames.txt")
np.save("synth_frames.npy", np.array(frames))
print("saved synth_frames.npy")
