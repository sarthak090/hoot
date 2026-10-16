import os

/// `log stream --predicate 'subsystem == "io.github.sarthak090.hoot"' --level debug`
/// Never logs commands, file contents or tokens: only event types and outcomes.
enum Log {
    static let server = Logger(subsystem: "io.github.sarthak090.hoot", category: "server")
    static let attention = Logger(subsystem: "io.github.sarthak090.hoot", category: "attention")
    static let ui = Logger(subsystem: "io.github.sarthak090.hoot", category: "ui")
}
