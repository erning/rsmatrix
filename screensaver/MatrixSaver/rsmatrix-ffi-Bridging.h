#ifndef rsmatrix_ffi_Bridging_h
#define rsmatrix_ffi_Bridging_h

#include <stdint.h>

typedef struct RsMatrixSimulation RsMatrixSimulation;

typedef struct {
    uint32_t codepoint;
    uint8_t r;
    uint8_t g;
    uint8_t b;
} RsMatrixCell;

RsMatrixSimulation* _Nonnull rsmatrix_create(uint32_t width, uint32_t height);
void rsmatrix_destroy(RsMatrixSimulation* _Nonnull sim);
void rsmatrix_tick(RsMatrixSimulation* _Nonnull sim, uint32_t delta_ms);
void rsmatrix_resize(RsMatrixSimulation* _Nonnull sim, uint32_t width, uint32_t height);
const RsMatrixCell* _Nonnull rsmatrix_get_grid(const RsMatrixSimulation* _Nonnull sim);
uint32_t rsmatrix_grid_width(const RsMatrixSimulation* _Nonnull sim);
uint32_t rsmatrix_grid_height(const RsMatrixSimulation* _Nonnull sim);
void rsmatrix_set_charset(uint32_t mode);

#endif
