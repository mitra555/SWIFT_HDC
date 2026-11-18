# Extra experiments

## A. Leave-one-person-out: source of the gap to floating point

Pooled accuracy over 25 folds, mean +- std over seed sets; paired difference to E16 over seed sets.


### 5 classes (5 seed sets)

| Mode | Accuracy (%) | minus E16 | better/worse | p (paired t) |
|---|---|---|---|---|
| E16 | 82.8 +- 1.0 | +0.0 | 0/0 | nan |
| E32 | 82.4 +- 1.5 | -0.4 | 1/4 | 0.32 |
| E16_e80 | 82.8 +- 1.0 | +0.0 | 0/0 | nan |
| FLT_hwf | 85.8 +- 1.1 | +3.0 | 5/0 | 0.0021 |
| E16_flf | 83.0 +- 1.2 | +0.2 | 3/2 | 0.71 |
| D_float | 85.3 +- 1.6 | +2.5 | 4/0 | 0.02 |

### 6 classes (5 seed sets)

| Mode | Accuracy (%) | minus E16 | better/worse | p (paired t) |
|---|---|---|---|---|
| E16 | 70.1 +- 1.6 | +0.0 | 0/0 | nan |
| E32 | 70.1 +- 1.5 | -0.0 | 3/2 | 1 |
| E16_e80 | 70.1 +- 1.6 | +0.0 | 0/0 | nan |
| FLT_hwf | 71.2 +- 0.5 | +1.1 | 3/2 | 0.28 |
| E16_flf | 70.5 +- 1.7 | +0.3 | 3/2 | 0.74 |
| D_float | 72.5 +- 1.2 | +2.4 | 4/1 | 0.069 |

## B. Classes that fit in the existing 1024-row wide SPM

rows = (K+1) * ceil(D/32)

| Dataset | D | K | rows | fits | SWIFT 16-bit (%) | baseline (%) |
|---|---|---|---|---|---|---|
| ucihar | 1184 | 6 | 259 | yes | 87.1 +- 1.1 | 47.4 +- 0.8 |
| ucihar | 4672 | 6 | 1022 | yes | 91.4 +- 0.9 | 61.5 +- 0.9 |
| ucihar | 5024 | 6 | 1099 | no | 91.6 +- 0.4 | 60.6 +- 1.5 |
| isolet | 1184 | 26 | 999 | yes | 87.0 +- 0.7 | 21.5 +- 2.5 |
| isolet | 2048 | 26 | 1728 | no | 90.2 +- 0.3 | 28.1 +- 1.6 |
| isolet | 5024 | 26 | 4239 | no | 91.9 +- 0.5 | 37.0 +- 2.2 |
