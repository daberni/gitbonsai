import Foundation

extension Repository {
    /// Tags `commit` with `name`. A message makes it an annotated tag carrying tagger and date. Fails when the tag exists.
    public func createTag(_ name: String, at commit: String, message: String? = nil) async throws {
        if let message {
            _ = try await runner.runWrite(["tag", "-a", name, "-F", "-", commit], stdin: Data(message.utf8))
        } else {
            _ = try await runner.runWrite(["tag", name, commit])
        }
    }
}
