#include <cstdint>

namespace {

static inline std::uint8_t TGSAlpha(std::uint32_t value) {
    return static_cast<std::uint8_t>(value >> 24);
}

static inline std::uint32_t TGSSourceOver(std::uint32_t source, std::uint32_t destination) {
    const std::uint32_t sourceAlpha = TGSAlpha(source);
    if (sourceAlpha == 255) {
        return source;
    }
    if (sourceAlpha == 0) {
        return destination;
    }

    const std::uint32_t inverseAlpha = 255 - sourceAlpha;
    const std::uint32_t sourceRB = source & 0x00ff00ff;
    const std::uint32_t sourceG = source & 0x0000ff00;
    const std::uint32_t destinationRB = destination & 0x00ff00ff;
    const std::uint32_t destinationG = destination & 0x0000ff00;
    const std::uint32_t destinationA = destination >> 24;

    const std::uint32_t outA = sourceAlpha + ((destinationA * inverseAlpha + 127) / 255);
    const std::uint32_t outRB = (sourceRB + (((destinationRB * inverseAlpha) + 0x00800080) >> 8)) & 0x00ff00ff;
    const std::uint32_t outG = (sourceG + (((destinationG * inverseAlpha) + 0x00008000) >> 8)) & 0x0000ff00;
    return (outA << 24) | outRB | outG;
}

}

extern "C" void pixman_composite_src_n_8888_asm_neon(
    std::int32_t width,
    std::int32_t height,
    std::uint32_t *destination,
    std::int32_t destinationStride,
    std::uint32_t source
) {
    if (width <= 0 || height <= 0 || destination == nullptr || destinationStride <= 0) {
        return;
    }

    for (std::int32_t y = 0; y < height; y++) {
        std::uint32_t *row = destination + y * destinationStride;
        for (std::int32_t x = 0; x < width; x++) {
            row[x] = source;
        }
    }
}

extern "C" void pixman_composite_over_n_8888_asm_neon(
    std::int32_t width,
    std::int32_t height,
    std::uint32_t *destination,
    std::int32_t destinationStride,
    std::uint32_t source
) {
    if (width <= 0 || height <= 0 || destination == nullptr || destinationStride <= 0) {
        return;
    }

    for (std::int32_t y = 0; y < height; y++) {
        std::uint32_t *row = destination + y * destinationStride;
        for (std::int32_t x = 0; x < width; x++) {
            row[x] = TGSSourceOver(source, row[x]);
        }
    }
}
