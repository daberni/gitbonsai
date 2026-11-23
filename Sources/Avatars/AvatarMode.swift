/// What an author's node and the detail panel show, and which services learn about the authors for it.
public enum AvatarMode: String, Sendable, CaseIterable {
    /// Plain initials only; nothing goes over the network.
    case initialsOnly
    /// Pictures from the host of the repository's remote, with the generated stand-in for authors without one.
    case remoteHost
    /// Pictures from the remote host, then Gravatar.
    case remoteHostAndGravatar

    /// The services asked for pictures; nil with initials only.
    public var sources: AvatarSources? {
        switch self {
        case .initialsOnly: nil
        case .remoteHost: .remoteHost
        case .remoteHostAndGravatar: .remoteHostAndGravatar
        }
    }

    public var showsPictures: Bool { sources != nil }

    /// The stored choice, migrating the earlier keys: the on/off `avatarsEnabled`, the `pictures` value of this key and the separate `avatarSources`. `nil` means nothing was chosen yet.
    public static func stored(_ raw: String?, legacyEnabled: Bool?, legacySources: String?) -> AvatarMode? {
        if let mode = raw.flatMap(AvatarMode.init(rawValue:)) { return mode }
        let pictures = raw == "pictures" || (raw == nil && legacyEnabled == true)
        if pictures { return legacySources == AvatarSources.remoteHostAndGravatar.rawValue ? .remoteHostAndGravatar : .remoteHost }
        if raw != nil || legacyEnabled == false { return .initialsOnly }
        return nil
    }
}
