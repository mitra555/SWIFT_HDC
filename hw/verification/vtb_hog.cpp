// Standalone hog_top harness: for each frame in synth_frames.txt, load the
// 32x32 window, run hog_top to done, dump all 324 Q16.16 outputs.
#include "Vhog_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>

static Vhog_top* t;
static void tick() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); }

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    t = new Vhog_top;
    const int NF = 4, PIXW = 1024;
    FILE* fp = fopen("synth_frames.txt", "r");
    if (!fp) return 1;
    std::vector<int> pix(NF * PIXW);
    for (int i = 0; i < NF * PIXW; i++) if (fscanf(fp, "%d", &pix[i]) != 1) return 1;
    fclose(fp);

    FILE* out = fopen("hog_rtl.txt", "w");
    t->clk = 0; t->rst_n = 0; t->start = 0; t->load_we = 0;
    for (int i = 0; i < 5; i++) tick();
    t->rst_n = 1; tick();

    for (int f = 0; f < NF; f++) {
        for (int p = 0; p < PIXW; p++) {
            t->load_we = 1; t->load_addr = p; t->load_data = pix[f * PIXW + p] & 0xFF; tick();
        }
        t->load_we = 0; tick();
        t->start = 1; tick(); t->start = 0;
        uint64_t c = 0;
        while (!t->done && c < 5000000) { tick(); c++; }
        if (!t->done) { fprintf(stderr, "frame %d: no done\n", f); return 2; }
        fprintf(stderr, "frame %d done in %llu cycles\n", f, (unsigned long long)c);
        for (int i = 0; i < 324; i++) fprintf(out, "%d ", (int32_t)t->hog_out_packed[i]);
        fprintf(out, "\n");
        tick(); tick();
    }
    fclose(out);
    delete t;
    return 0;
}
