//
//  AppEnvironment.swift
//  PageFlow
//
//  Environment variables the app reads. `GLOSSA_*` is the canonical namespace;
//  `PAGEFLOW_*` is a temporary compatibility alias for scripts written before
//  the rename. Callers ask for the name without a prefix (`"QA_RUN_ID"`).
//

import Foundation

nonisolated struct AppEnvironment: Sendable {
    static let canonicalPrefix = "GLOSSA_"
    /// Compatibility alias, to be removed in a later release.
    static let legacyPrefix = "PAGEFLOW_"

    /// The process environment, read at the time of the call.
    static var current: AppEnvironment { AppEnvironment(ProcessInfo.processInfo.environment) }

    private let variables: [String: String]

    /// The variables are injected so that tests never depend on the real environment.
    init(_ variables: [String: String]) {
        self.variables = variables
    }

    /// The value of `GLOSSA_<name>` if that variable is present, else of `PAGEFLOW_<name>`.
    /// Presence decides, not content: a canonical variable that is set to an empty string
    /// still wins, and its empty value is returned. The legacy variable is only a fallback
    /// for when the canonical one is absent.
    func value(_ name: String) -> String? {
        if let canonical = variables[Self.canonicalPrefix + name] { return canonical }
        return variables[Self.legacyPrefix + name]
    }

    /// Whether either variable is present, whatever its value (empty included).
    func isSet(_ name: String) -> Bool { value(name) != nil }

    /// Whether any QA variable of either namespace is present: a name that starts with
    /// `GLOSSA_` or `PAGEFLOW_` and contains `QA`.
    var hasQAVariable: Bool {
        variables.keys.contains { key in
            (key.hasPrefix(Self.canonicalPrefix) || key.hasPrefix(Self.legacyPrefix)) && key.contains("QA")
        }
    }
}
