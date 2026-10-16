import Foundation

/// Minimal test harness: XCTest and swift-testing both need Xcode, which this project does not require.
@MainActor
enum Harness {
    private static var failures = 0
    private static var checks = 0
    private static var current = ""

    static func test(_ name: String, _ body: () throws -> Void) {
        current = name
        do { try body() } catch { record("threw \(error)") }
    }

    /// A thrown error counts as a failed check, so throwing calls can be checked inline.
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
                       file: StaticString = #fileID, line: UInt = #line) {
        checks += 1
        do {
            if try !condition() { record("\(message()) (\(file):\(line))") }
        } catch {
            record("threw \(error) (\(file):\(line))")
        }
    }

    static func expectEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                          file: StaticString = #fileID, line: UInt = #line) {
        checks += 1
        do {
            let (x, y) = (try a(), try b())
            if x != y { record("expected \(y), got \(x) (\(file):\(line))") }
        } catch {
            record("threw \(error) (\(file):\(line))")
        }
    }

    private static func record(_ message: String) {
        failures += 1
        print("FAIL [\(current)] \(message)")
    }

    static func finish() -> Never {
        print(failures == 0 ? "OK: \(checks) checks passed" : "\(failures) of \(checks) checks failed")
        exit(failures == 0 ? 0 : 1)
    }
}
