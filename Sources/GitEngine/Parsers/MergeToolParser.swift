import Foundation

/// A tool `git mergetool` can open: one of git's built-in backends or one the user defined with `mergetool.<name>.cmd`.
public struct MergeTool: Sendable, Hashable, Identifiable {
    public let name: String
    /// git's description, such as "Use FileMerge"; the command line for a user-defined tool.
    public let summary: String
    /// The tool opens a window of its own; the others need a terminal, which the app does not have.
    public let isGraphical: Bool
    /// git found the tool on this system.
    public let isAvailable: Bool
    public let isUserDefined: Bool

    public var id: String { name }

    public init(name: String, summary: String, isGraphical: Bool, isAvailable: Bool, isUserDefined: Bool) {
        self.name = name
        self.summary = summary
        self.isGraphical = isGraphical
        self.isAvailable = isAvailable
        self.isUserDefined = isUserDefined
    }
}

/// Reads `git mergetool --tool-help`, which has no machine format. git prints it in the C locale here; tools are the lines indented by two tabs,
/// built-in ones as name and description, user-defined ones under "user-defined:" as `<name>.cmd <command>`. Tools after the line about tools that are "not currently available" are missing on this system.
enum MergeToolParser {
    private static let graphicalMarker = "(requires a graphical session)"

    static func parseToolHelp(_ output: String) -> [MergeTool] {
        var tools: [MergeTool] = []
        var isAvailable = true
        var isUserDefined = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if !line.hasPrefix("\t") {
                if line.contains("not currently available") { isAvailable = false }
                isUserDefined = false
                continue
            }
            guard line.hasPrefix("\t\t") else {
                isUserDefined = line.trimmingCharacters(in: .whitespaces) == "user-defined:"
                continue
            }
            let entry = line.dropFirst(2)
            let name = String(entry.prefix { !$0.isWhitespace })
            let rest = entry.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            if isUserDefined {
                // A user-defined tool may run anything; git cannot tell whether it opens a window, and the user set it up on purpose.
                let toolName = name.hasSuffix(".cmd") ? String(name.dropLast(4)) : name
                tools.append(MergeTool(name: toolName, summary: rest, isGraphical: true, isAvailable: isAvailable, isUserDefined: true))
            } else {
                tools.append(MergeTool(name: name, summary: rest.replacingOccurrences(of: " " + graphicalMarker, with: ""), isGraphical: rest.contains(graphicalMarker), isAvailable: isAvailable, isUserDefined: false))
            }
        }
        return tools
    }
}
