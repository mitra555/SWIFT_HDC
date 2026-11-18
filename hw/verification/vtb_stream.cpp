// Streaming harness for video_frontend_top: loads frames 0 and 1, pulses start,
// then feeds every further frame whenever ld_ready is high, while the pipeline
// runs. Also logs every top-level
// FSM transition with its cycle number, and if the top FSM sits in one state
// for STALL_LIMIT cycles, dumps sub-unit FSM states and exits.
#include "Vvideo_frontend_top.h"
#include "Vvideo_frontend_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>

static Vvideo_frontend_top* top;
static void tick() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); }

#define R top->rootp

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    top = new Vvideo_frontend_top;
    const int NUM_FRAMES = 4, PIXW = 32*32;
    const uint64_t CAP = 400000000ULL, STALL_LIMIT = 20000000ULL;

    FILE* fp = fopen("synth_frames.txt", "r");
    if (!fp) { fprintf(stderr, "no synth_frames.txt\n"); return 1; }
    std::vector<int> pix(NUM_FRAMES*PIXW);
    for (int i = 0; i < NUM_FRAMES*PIXW; i++) if (fscanf(fp, "%d", &pix[i]) != 1) return 1;
    fclose(fp);

    top->clk = 0; top->rst_n = 0; top->start = 0; top->ld_frame_we = 0;
    for (int i = 0; i < 5; i++) tick();
    top->rst_n = 1; tick();
    for (int f = 0; f < 2; f++) for (int p = 0; p < PIXW; p++) {      // frames 0 and 1 up front
        top->ld_frame_we = 1; top->ld_frame_idx = f; top->ld_pix_idx = p;
        top->ld_pix_data = pix[f*PIXW+p] & 0xFF; tick();
    }
    top->ld_frame_we = 0; tick();
    top->start = 1; tick(); top->start = 0;
    int next_frame = 2, load_pix = -1;   // -1: not currently loading a frame
    uint64_t frame_wait_cycles = 0;

    uint64_t cyc = 0, since = 0;
    int prev = -1; setvbuf(stdout, NULL, _IOLBF, 0);
    while (!top->done && cyc < CAP) {
        // stream the next frame in as soon as a slot is free
        if (load_pix < 0 && next_frame < NUM_FRAMES && top->ld_ready) load_pix = 0;
        if (load_pix >= 0) {
            top->ld_frame_we = 1; top->ld_frame_idx = next_frame; top->ld_pix_idx = load_pix;
            top->ld_pix_data = pix[next_frame*PIXW + load_pix] & 0xFF;
        } else top->ld_frame_we = 0;
        tick(); cyc++;
        if (load_pix >= 0 && ++load_pix == PIXW) { load_pix = -1; next_frame++; top->ld_frame_we = 0; }
        if (R->video_frontend_top__DOT__state_r == 1) frame_wait_cycles++;   // S_T_WAITFRAME
        int st = R->video_frontend_top__DOT__state_r;
        if (st != prev) {
            printf("cyc=%10llu top_state=%d (held %llu)\n", (unsigned long long)cyc, st, (unsigned long long)since);
            prev = st; since = 0;
        } else if (++since == STALL_LIMIT) {
            printf("STALL: top_state=%d held %llu cycles at cyc=%llu\n", st,
                   (unsigned long long)since, (unsigned long long)cyc);
            printf("  ac  state=%d lag=%d i=%d t=%d\n",
                   R->video_frontend_top__DOT__u_autocorr__DOT__state_r,
                   R->video_frontend_top__DOT__u_autocorr__DOT__lag_r,
                   R->video_frontend_top__DOT__u_autocorr__DOT__i_r,
                   R->video_frontend_top__DOT__u_autocorr__DOT__t_r);
            printf("  pct state=%d  ms state=%d  cn state=%d  hog state=%d  bm state=%d  hof state=%d\n",
                   R->video_frontend_top__DOT__u_pct__DOT__state_r,
                   R->video_frontend_top__DOT__u_meanstd__DOT__state_r,
                   R->video_frontend_top__DOT__u_cellnorm__DOT__state_r,
                   R->video_frontend_top__DOT__u_hog__DOT__state_r,
                   R->video_frontend_top__DOT__u_bm__DOT__state_r,
                   R->video_frontend_top__DOT__u_hof__DOT__state_r);
            fflush(stdout);
            return 3;
        }
        if (cyc % 1000000 == 0) { fprintf(stderr, "cyc=%llu state=%d\n", (unsigned long long)cyc, st); }
    }
    if (!top->done) { printf("CAP reached without done\n"); return 2; }
    printf("DONE after %llu cycles (frames streamed: %d, cycles stalled waiting for frames: %llu)\n",
           (unsigned long long)cyc, next_frame, (unsigned long long)frame_wait_cycles);

    FILE* out = fopen("vft_rtl_output.txt", "w");
    for (int i = 0; i < 904; i++) fprintf(out, "%d ", (int32_t)top->base_norm[i]); fprintf(out, "\n");
    for (int i = 0; i < 32;  i++) fprintf(out, "%d ", (int32_t)top->dx_norm[i]);   fprintf(out, "\n");
    for (int i = 0; i < 32;  i++) fprintf(out, "%d ", (int32_t)top->dy_norm[i]);   fprintf(out, "\n");
    for (int i = 0; i < 16;  i++) fprintf(out, "%d ", (int32_t)top->acd_norm[i]);  fprintf(out, "\n");
    for (int i = 0; i < 16;  i++) fprintf(out, "%d ", (int32_t)top->acx_norm[i]);  fprintf(out, "\n");
    for (int i = 0; i < 10;  i++) fprintf(out, "%d ", (int32_t)top->pct_norm[i]);  fprintf(out, "\n");
    fclose(out);
    printf("wrote vft_rtl_output.txt\n");
    delete top;
    return 0;
}
