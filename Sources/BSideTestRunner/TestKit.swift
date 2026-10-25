// BSideTestRunner — minimal deterministic test harness (ADR-009).
// The CLT-only toolchain on this machine has no XCTest / Swift Testing modules, so the gate
// runs this executable instead. Every check prints a labeled failure; exit code gates commits.
// If a full Xcode is later installed, these suites migrate mechanically to XCTest/@Test.

import Foundation

struct TestContext {
    var failures: [String] = []

    mutating func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        if !condition() { failures.append(label) }
    }

    mutating func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        if actual != expected { failures.append("\(label): got \(actual), want \(expected)") }
    }

    mutating func expectNear(_ actual: Double, _ expected: Double, _ label: String, eps: Double = 0.0001) {
        if abs(actual - expected) > eps { failures.append("\(label): got \(actual), want ~\(expected)") }
    }

    mutating func expectNotNil<T>(_ value: T?, _ label: String) {
        if value == nil { failures.append(label) }
    }

    mutating func expectNil<T>(_ value: T?, _ label: String) {
        if value != nil { failures.append("\(label): expected nil, got \(String(describing: value))") }
    }

    mutating func expectThrows(_ label: String, _ body: () throws -> Void) {
        do { try body(); failures.append("\(label): expected an error, none thrown") }
        catch { /* expected */ }
    }
}

var suiteTotal = 0
var suiteFailed = 0
var failureCount = 0

func run(_ name: String, _ body: (inout TestContext) -> Void) {
    var ctx = TestContext()
    body(&ctx)
    suiteTotal += 1
    if ctx.failures.isEmpty {
        print("pass  \(name)")
    } else {
        suiteFailed += 1
        failureCount += ctx.failures.count
        print("FAIL  \(name)")
        for failure in ctx.failures { print("      - \(failure)") }
    }
}
