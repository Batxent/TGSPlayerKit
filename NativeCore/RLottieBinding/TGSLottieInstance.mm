#import "TGSLottieInstance.h"

#include <algorithm>
#include <cstdint>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "rlottie.h"

namespace {

static rlottie::FitzModifier TGSToRLottieFitzModifier(TGSLottieFitzModifier modifier) {
    switch (modifier) {
        case TGSLottieFitzModifierType12:
            return rlottie::FitzModifier::Type12;
        case TGSLottieFitzModifierType3:
            return rlottie::FitzModifier::Type3;
        case TGSLottieFitzModifierType4:
            return rlottie::FitzModifier::Type4;
        case TGSLottieFitzModifierType5:
            return rlottie::FitzModifier::Type5;
        case TGSLottieFitzModifierType6:
            return rlottie::FitzModifier::Type6;
        case TGSLottieFitzModifierNone:
        default:
            return rlottie::FitzModifier::None;
    }
}

static std::vector<std::pair<std::uint32_t, std::uint32_t>> TGSColorReplacements(NSDictionary<NSNumber *, NSNumber *> *colorReplacements) {
    std::vector<std::pair<std::uint32_t, std::uint32_t>> result;
    if (colorReplacements == nil) {
        return result;
    }

    result.reserve(colorReplacements.count);
    for (NSNumber *sourceColor in colorReplacements) {
        NSNumber *replacementColor = colorReplacements[sourceColor];
        if (replacementColor != nil) {
            result.push_back({sourceColor.unsignedIntValue, replacementColor.unsignedIntValue});
        }
    }
    return result;
}

}

@interface TGSLottieInstance () {
    std::unique_ptr<rlottie::Animation> _animation;
}
@end

@implementation TGSLottieInstance

- (nullable instancetype)initWithData:(NSData *)data
                         fitzModifier:(TGSLottieFitzModifier)fitzModifier
                    colorReplacements:(NSDictionary<NSNumber *, NSNumber *> *)colorReplacements
                             cacheKey:(NSString *)cacheKey {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    std::string json(reinterpret_cast<const char *>(data.bytes), data.length);
    std::string key(cacheKey.UTF8String ?: "");
    std::vector<std::pair<std::uint32_t, std::uint32_t>> colors = TGSColorReplacements(colorReplacements);

    _animation = rlottie::Animation::loadFromData(
        std::move(json),
        key,
        "",
        !key.empty(),
        colors,
        TGSToRLottieFitzModifier(fitzModifier)
    );
    if (_animation == nullptr) {
        return nil;
    }

    _frameCount = std::max<int32_t>(1, static_cast<int32_t>(_animation->totalFrame()));
    _frameRate = std::max<int32_t>(1, static_cast<int32_t>(_animation->frameRate()));

    size_t width = 0;
    size_t height = 0;
    _animation->size(width, height);

    if (width > 1536 || height > 1536) {
        return nil;
    }
    if (_frameRate > 360 || _animation->duration() > 9.0) {
        return nil;
    }

    _dimensions = CGSizeMake(std::max<size_t>(1, width), std::max<size_t>(1, height));
    return self;
}

- (void)renderFrameWithIndex:(int32_t)index
                        into:(uint8_t *)buffer
                       width:(int32_t)width
                      height:(int32_t)height
                 bytesPerRow:(int32_t)bytesPerRow {
    if (_animation == nullptr || buffer == nullptr || width <= 0 || height <= 0 || bytesPerRow <= 0) {
        return;
    }

    rlottie::Surface surface(reinterpret_cast<uint32_t *>(buffer), width, height, bytesPerRow);
    _animation->renderSync(index, surface);
}

@end
