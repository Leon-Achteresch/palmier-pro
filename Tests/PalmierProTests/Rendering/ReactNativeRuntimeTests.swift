#if REACT_NATIVE

import Testing

@testable import PalmierPro

@Suite struct ReactNativeRuntimeTests {
    @Test func evaluatesJavaScript() throws {
        #expect(try ReactNativeRuntime.evaluate("String(1 + 2)") == "3")
    }

    @Test func runsOnHermesRatherThanJavaScriptCore() throws {
        #expect(try ReactNativeRuntime.evaluate("typeof HermesInternal") == "object")
    }

    @Test func reportsSyntaxErrorsInsteadOfCrashing() {
        #expect(throws: (any Error).self) { try ReactNativeRuntime.evaluate("this is not javascript") }
    }
}

#endif
