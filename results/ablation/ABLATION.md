# Hypervector generator ablation (16-bit lanes, retraining, dot search)

Accuracy (%) mean +- std over seed sets; difference to the chip's generator, paired over seed sets.

| Benchmark | chip | naive_level | rot_pos | naive_both | tables |
|---|---|---|---|---|---|
| KTH 5c notebook | 73.6 +- 3.4 | 61.4 +- 3.4 | 75.1 +- 3.5 | 61.3 +- 2.4 | 74.5 +- 3.2 |
| KTH 5c official | 66.7 +- 1.8 | 52.3 +- 2.2 | 67.0 +- 2.6 | 52.5 +- 1.9 | 67.4 +- 2.5 |
| KTH 6c official | 56.3 +- 2.3 | 44.4 +- 2.6 | 56.3 +- 3.2 | 44.6 +- 2.4 | 56.5 +- 2.0 |
| isolet | 91.9 +- 0.5 | 72.6 +- 0.4 | 92.1 +- 0.5 | 72.1 +- 1.4 | 92.4 +- 0.4 |
| ucihar | 91.6 +- 0.4 | 82.0 +- 0.3 | 91.2 +- 0.9 | 82.1 +- 1.7 | 90.9 +- 0.9 |

| Benchmark | naive_level - chip (p) | rot_pos - chip (p) | naive_both - chip (p) | tables - chip (p) |
|---|---|---|---|---|
| KTH 5c notebook | -12.3 (8.8e-05) | +1.5 (0.18) | -12.4 (8.8e-05) | +0.8 (0.26) |
| KTH 5c official | -14.4 (8.8e-05) | +0.2 (0.87) | -14.3 (8.8e-05) | +0.7 (0.37) |
| KTH 6c official | -11.9 (8.8e-05) | -0.0 (0.86) | -11.7 (8.8e-05) | +0.2 (0.63) |
| isolet | -19.3 (4.6e-07) | +0.2 (0.66) | -19.8 (4.2e-06) | +0.6 (0.21) |
| ucihar | -9.5 (3.2e-06) | -0.4 (0.33) | -9.5 (0.00018) | -0.6 (0.31) |
