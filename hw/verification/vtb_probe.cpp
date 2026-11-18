#include "Vvideo_frontend_top.h"
#include "verilated.h"
#include <cstdio>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vvideo_frontend_top* top = new Vvideo_frontend_top;

    top->clk = 0;
    top->rst_n = 0;
    top->start = 0;
    top->ld_frame_we = 0;
    top->ld_frame_idx = 0;
    top->ld_pix_idx = 0;
    top->ld_pix_data = 0;

    vluint64_t t = 0;
    for (int cyc = 0; cyc < 40; cyc++) {
        for (int ph = 0; ph < 2; ph++) {
            top->clk = !top->clk;
            top->eval();
            t++;
            if (top->clk && cyc == 5) top->rst_n = 1;
        }
        if (cyc % 5 == 0) {
            printf("cyc=%d t=%llu busy=%d done=%d\n", cyc, (unsigned long long)t, top->busy, top->done);
            fflush(stdout);
        }
    }
    printf("SURVIVED 40 cycles\n");
    delete top;
    return 0;
}
