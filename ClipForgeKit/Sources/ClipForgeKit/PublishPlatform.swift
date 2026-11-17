import Foundation

/// Where a clip can go. YouTube Shorts is wired (PublishService); the others are placeholders
/// until their APIs are connected — `setup` says what's needed.
public enum PublishPlatform: String, CaseIterable, Identifiable, Sendable {
    case youtube, instagram, tiktok
    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .youtube: "YouTube Shorts"
        case .instagram: "Instagram Reels"
        case .tiktok: "TikTok"
        }
    }

    public var isIntegrated: Bool { self == .youtube }

    public var setup: String {
        switch self {
        case .youtube:
            "Connected through the YouTube Data API. Add a Google “Desktop app” OAuth client in Settings → Accounts and sign in. Uploads from unverified API projects stay private until Google's compliance audit."
        case .instagram:
            "Needs: an Instagram Business or Creator account linked to a Facebook Page; a Meta developer app with the instagram_business_content_publish permission (requires Meta App Review); Facebook Login (OAuth) for a long-lived token; and a public HTTPS URL for each video, because Instagram downloads the file itself (e.g. S3/Cloudflare R2 upload first). Rate limit: 50 posts per 24 h."
        case .tiktok:
            "Needs: a TikTok for Developers app with the Content Posting API and the video.publish scope; Login Kit (OAuth 2.0 with PKCE) per user; and TikTok's audit before posts can be public — unaudited apps can only post privately. Files can be uploaded directly (chunked), no hosting required."
        }
    }
}
