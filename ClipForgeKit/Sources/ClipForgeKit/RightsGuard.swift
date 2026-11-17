import Foundation

/// Gatekeeper for what may be processed and published. Pure functions over persisted confirmations.
public enum RightsGuard {
    public static let ownershipStatement = "I own this content or have permission from the rights holder to clip and republish it."

    /// nil = OK to ingest/clip; otherwise the reason it's blocked.
    @MainActor public static func canProcess(_ s: Source) -> String? {
        s.ownershipConfirmedAt == nil ? "Confirm that you own this content or have permission before processing it." : nil
    }

    /// Local files have no channel; their ownership was confirmed when they were added.
    @MainActor public static func isForeign(_ s: Source, channel: Channel) -> Bool { !s.url.hasPrefix("file://") && s.channelID != channel.id }

    /// Uploads only ever go to the authenticated channel. A source from a different channel
    /// needs an explicit, stored permission confirmation — for manual and auto publishing alike.
    @MainActor public static func canPublish(_ s: Source, to channel: Channel) -> String? {
        if let r = canProcess(s) { return r }
        if isForeign(s, channel: channel), s.permissionConfirmedAt == nil {
            return "“\(s.title)” is from \(s.channelName.isEmpty ? "another channel" : s.channelName), not your channel “\(channel.title)”. Record the rights holder's permission on the source dashboard before publishing."
        }
        return nil
    }

    @MainActor public static func basis(_ s: Source, channel: Channel) -> String {
        if s.url.hasPrefix("file://") { return "Local footage, ownership confirmed \(s.ownershipConfirmedAt?.formatted(date: .abbreviated, time: .omitted) ?? "")" }
        guard isForeign(s, channel: channel) else { return "Owner (source channel = \(channel.title))" }
        let when = s.permissionConfirmedAt?.formatted(date: .abbreviated, time: .omitted) ?? "—"
        return "Permission from \(s.channelName) confirmed \(when)" + (s.permissionNote.isEmpty ? "" : ": \(s.permissionNote)")
    }
}
