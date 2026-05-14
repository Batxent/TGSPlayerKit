import Foundation

public enum TGSPlayerState: Equatable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case failed(TGSPlayerError)
}

struct TGSPlayerStateMachine {
    private(set) var source: TGSSource?
    private(set) var state: TGSPlayerState = .idle
    private(set) var generation: UInt64 = 0

    mutating func setSource(_ source: TGSSource) {
        generation &+= 1
        self.source = source
        state = .loading
    }

    mutating func markReady() {
        state = .ready
    }

    mutating func play() {
        guard source != nil else {
            state = .failed(.invalidSource)
            return
        }
        state = .playing
    }

    mutating func pause() {
        guard state == .playing else {
            return
        }
        state = .paused
    }

    mutating func stop() {
        guard source != nil else {
            state = .idle
            return
        }
        state = .ready
    }

    mutating func fail(_ error: TGSPlayerError) {
        state = .failed(error)
    }

    mutating func prepareForReuse() {
        generation &+= 1
        source = nil
        state = .idle
    }
}
