import Foundation

@inline(__always)
internal func TGSDebugLog(_ message: @autoclosure () -> String) {
    NSLog("[TGSDBG] %@", message())
}

@inline(__always)
internal func TGSDebugFileName(_ path: String) -> String {
    URL(fileURLWithPath: path).lastPathComponent
}
