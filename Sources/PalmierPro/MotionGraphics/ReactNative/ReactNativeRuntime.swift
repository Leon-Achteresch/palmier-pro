#if REACT_NATIVE

import Foundation
import PalmierRNHost

enum ReactNativeRuntime {
    static func evaluate(_ source: String) throws -> String {
        try PalmierRNHost.evaluateScript(source)
    }
}

#endif
