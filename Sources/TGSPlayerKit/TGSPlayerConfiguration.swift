import CoreGraphics
import Foundation

public struct TGSPlayerConfiguration: Equatable {
    public var playbackMode: TGSAnimatedStickerPlaybackMode
    public var mode: TGSAnimatedStickerMode
    public var automaticallyLoadFirstFrame: Bool
    public var automaticallyLoadLastFrame: Bool
    public var playToCompletionOnStop: Bool
    public var useMetalRendererWhenAvailable: Bool

    public init(
        playbackMode: TGSAnimatedStickerPlaybackMode = .loop,
        mode: TGSAnimatedStickerMode = .direct(cachePathPrefix: nil),
        automaticallyLoadFirstFrame: Bool = false,
        automaticallyLoadLastFrame: Bool = false,
        playToCompletionOnStop: Bool = false,
        useMetalRendererWhenAvailable: Bool = false
    ) {
        self.playbackMode = playbackMode
        self.mode = mode
        self.automaticallyLoadFirstFrame = automaticallyLoadFirstFrame
        self.automaticallyLoadLastFrame = automaticallyLoadLastFrame
        self.playToCompletionOnStop = playToCompletionOnStop
        self.useMetalRendererWhenAvailable = useMetalRendererWhenAvailable
    }
}
