#ifndef TGSLottieInstance_h
#define TGSLottieInstance_h

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

typedef NS_ENUM(int32_t, TGSLottieFitzModifier) {
    TGSLottieFitzModifierNone,
    TGSLottieFitzModifierType12,
    TGSLottieFitzModifierType3,
    TGSLottieFitzModifierType4,
    TGSLottieFitzModifierType5,
    TGSLottieFitzModifierType6
};

NS_ASSUME_NONNULL_BEGIN

@interface TGSLottieInstance : NSObject

@property(nonatomic, readonly) int32_t frameCount;
@property(nonatomic, readonly) int32_t frameRate;
@property(nonatomic, readonly) CGSize dimensions;

- (nullable instancetype)initWithData:(NSData *)data
                         fitzModifier:(TGSLottieFitzModifier)fitzModifier
                    colorReplacements:(nullable NSDictionary<NSNumber *, NSNumber *> *)colorReplacements
                             cacheKey:(NSString *)cacheKey;

- (void)renderFrameWithIndex:(int32_t)index
                        into:(uint8_t *)buffer
                       width:(int32_t)width
                      height:(int32_t)height
                 bytesPerRow:(int32_t)bytesPerRow;

@end

NS_ASSUME_NONNULL_END

#endif
