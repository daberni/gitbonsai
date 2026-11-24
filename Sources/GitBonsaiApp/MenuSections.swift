import AppKit

/// The groups every ref and commit menu shares, in the order they show. Ref and commit builders fill the same groups, so a combined menu zips them by meaning instead of stacking one section above the other.
struct MenuSections {
    /// Other refs of the row, each as a pill submenu; they lead the menu.
    var refs: [NSMenuItem] = []
    /// Checkout, Switch to Worktree, Checkout Commit (detached).
    var goThere: [NSMenuItem] = []
    /// Pull, Push, Push Tag.
    var sync: [NSMenuItem] = []
    /// Moves or changes the current branch: Fast-Forward, Merge, Rebase, Cherry-Pick, Reset, Revert.
    var integrate: [NSMenuItem] = []
    /// Delete, Delete Branches…, Drop Commit.
    var remove: [NSMenuItem] = []
    /// Branch, Worktree, Tag.
    var create: [NSMenuItem] = []
    /// Rename, Upstream, Edit Message, Move up/down.
    var change: [NSMenuItem] = []
    /// Copy name, Copy SHA, Save Patch.
    var copy: [NSMenuItem] = []

    var groups: [[NSMenuItem]] { [refs, goThere, sync, integrate, remove, create, change, copy] }

    static func + (lhs: MenuSections, rhs: MenuSections) -> MenuSections {
        MenuSections(refs: lhs.refs + rhs.refs, goThere: lhs.goThere + rhs.goThere, sync: lhs.sync + rhs.sync, integrate: lhs.integrate + rhs.integrate, remove: lhs.remove + rhs.remove, create: lhs.create + rhs.create, change: lhs.change + rhs.change, copy: lhs.copy + rhs.copy)
    }
}
