/* The production HDR uniform must keep reference whites finite and within display headroom. */
#define TOTK_HDR_FRONTEND 1
#include "../games/totk/third_party/d2r_gfx/gfx/nvn/totk_hdr.h"
#include <assert.h>
int main(void) {
    assert(sizeof(TotkHDRUniform) == 64);
    for (int enabled=0; enabled<=1; enabled++) {
        for (int h=0; h<=16; h++) {
            TotkHDRUniform u;
            float peak=totk_hdr_uniform_snapshot(&u,(float)h,enabled);
            assert(isfinite(peak) && peak>=1 && peak<=16);
            assert(u.v[0]==enabled);
            assert(u.v[1]>=1 && u.v[2]>0 && u.v[3]>0 && u.v[3]<=peak);
            assert(u.v[4]==1); /* default exposure preserves reference white */
            for (unsigned i=0;i<16;i++) assert(isfinite(u.v[i]));
        }
    }
    return 0;
}
