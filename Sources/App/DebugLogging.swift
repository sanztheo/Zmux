#if DEBUG
import ZMUXDebugLog

@inline(__always)
func zmuxDebugLog(_ message: @autoclosure () -> String) {
    ZMUXDebugLog.logDebugEvent(message())
}
#endif
