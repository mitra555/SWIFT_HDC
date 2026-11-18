| Run | Top | Lane | Clock (ns) | Timing (slack ps) | Cells | Flops | Logic area (mm²) | SRAM | SRAM area (mm²) | Total area (mm²) | Power (mW) | Energy over VCD window (uJ) | Power source | Unresolved |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| hdcu_10p0 | hdcu_top | 16 | 10.0 | MET (1.0) | 2723 | 258 | 0.0232 | 4x1kbyte_1rw1r_32x256_8 | 0.7629 | 0.7861 | 17.2358 | 2.449 (142.1 us) | VCD | 0 |
| nov16_10p0 | nov_top | 16 | 10.0 | MET (0.0) | 24004 | 1577 | 0.1850 | 2x2kbyte_1rw1r_32x512_8 + 16x4kbyte_1rw1r_32x1024_8 | 7.9954 | 8.1804 | 0.5441 | 0.957 (1758.68 us) | VCD | 0 |
| nov16_10p5 | nov_top | 16 | 10.5 | MET (0.0) | 24196 | 1577 | 0.1836 | 2x2kbyte_1rw1r_32x512_8 + 16x4kbyte_1rw1r_32x1024_8 | 7.9954 | 8.179 | 0.544 |  | VCD | 0 |
| nov32_10p0 | nov_top | 32 | 10.0 | MET (0.0) | 56892 | 2875 | 0.3769 | 2x2kbyte_1rw1r_32x512_8 + 32x4kbyte_1rw1r_32x1024_8 | 15.4218 | 15.7987 | 0.887 | 2.986 (3366.52 us) | VCD | 0 |
| nov32_10p5 | nov_top | 32 | 10.5 | MET (0.0) | 50403 | 2875 | 0.3475 | 2x2kbyte_1rw1r_32x512_8 + 32x4kbyte_1rw1r_32x1024_8 | 15.4218 | 15.7693 | 0.887 |  | VCD | 0 |
| soc16_10p0 | hdc_soc_top | 16 | 10.0 | MET (0.0) | 35500 | 3773 | 0.2997 | 4x1kbyte_1rw1r_32x256_8 + 2x2kbyte_1rw1r_32x512_8 + 16x4kbyte_1rw1r_32x1024_8 + 2x8kbyte_1rw1r_32x2048_8 | 10.3345 | 10.6342 | 6.3612 | 12.152 (1910.32 us) | VCD | 0 |
| soc32_10p0 | hdc_soc_top | 32 | 10.0 | VIOLATED (-1.3) | 66961 | 5071 | 0.4901 | 4x1kbyte_1rw1r_32x256_8 + 2x2kbyte_1rw1r_32x512_8 + 32x4kbyte_1rw1r_32x1024_8 + 2x8kbyte_1rw1r_32x2048_8 | 17.7608 | 18.251 | 6.3638 | 22.389 (3518.16 us) | VCD | 0 |
| vfe_10p0 | video_frontend_top | 16 | 10.0 | MET (0.0) | 657957 | 261779 | 9.2929 | none | 0.0000 | 9.2929 | 289.908 |  | vectorless | 0 |
