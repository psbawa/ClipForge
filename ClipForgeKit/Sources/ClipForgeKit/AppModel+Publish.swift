import Foundation
import SwiftData

extension AppModel {
    public func signInYouTube() async {
        do {
            try await auth.signIn()
            await (publisher as? PublishService)?.clearChannel()
            youtubeChannel = try await publisher.channel()
            notify("Connected to YouTube channel “\(youtubeChannel!.title)”.", .info)
        } catch { notify(error.localizedDescription) }
    }

    public func signOutYouTube() async {
        await auth.signOut()
        await (publisher as? PublishService)?.clearChannel()
        youtubeChannel = nil
    }

    public func loadYouTubeChannel() async {
        guard await auth.isSignedIn else { return }
        youtubeChannel = try? await publisher.channel()
    }

    /// Uploads one clip. Manual publish requires `.ready`/`.approved`; RightsGuard always applies.
    public func publish(_ rec: ClipRecord, auto: Bool = false) async {
        guard [.ready, .approved, .downloaded].contains(rec.status), let file = rec.videoURL, let src = rec.source else { return }
        let channel: Channel
        do { channel = try await publisher.channel() } catch {
            rec.lastError = "Not published: \(error.localizedDescription)"; save()
            return notify(error.localizedDescription)
        }
        youtubeChannel = channel
        if let reason = RightsGuard.canPublish(src, to: channel) {
            rec.lastError = "Not published: \(reason)"; save()
            return notify(reason, .warning)
        }

        let req = UploadRequest(file: file, title: rec.title, description: rec.fullDescription, tags: rec.tags, privacy: settings.privacyStatus)
        let prevStage = stage
        stage = .publishing
        rec.status = .publishing
        save()
        defer { stage = runningSourceID == nil ? .idle : prevStage == .publishing ? .watching : prevStage }
        let log = PublishLogEntry(clipID: rec.id, sourceTitle: src.title, title: rec.title, requestedPrivacy: req.privacy,
                                  result: "", rightsBasis: RightsGuard.basis(src, channel: channel) + (auto ? " · auto" : " · manual"))
        context.insert(log)
        do {
            // Persist the session before sending bytes so a crash can resume instead of re-uploading.
            let session: URL
            if let s = rec.uploadSessionURL.flatMap(URL.init(string:)) { session = s } else { session = try await publisher.startSession(req) }
            rec.uploadSessionURL = session.absoluteString
            save()
            let r = try await publisher.upload(req, session: session)
            markPublished(rec, r, log: log)
            if r.privacy == "private", req.privacy != "private" {
                notify("YouTube set “\(rec.title)” to private. Uploads from unverified API projects (created after July 28, 2020) are locked to private until the project passes YouTube's API Services compliance audit. Request one at https://support.google.com/youtube/contact/yt_api_form — until then, publish manually from YouTube Studio.", .warning)
            }
        } catch {
            if (error as? PublishError) == .sessionExpired { rec.uploadSessionURL = nil }
            rec.status = .failed
            rec.failure = .publish
            rec.lastError = error.localizedDescription
            log.result = "Failed: \(error.localizedDescription)"
            save()
            notify(error.localizedDescription)
        }
    }

    func markPublished(_ rec: ClipRecord, _ r: UploadResult, log: PublishLogEntry) {
        rec.status = .published
        rec.failure = nil
        rec.videoID = r.videoID
        rec.publishedAt = .now
        rec.uploadSessionURL = nil
        rec.lastError = nil
        log.videoID = r.videoID
        log.returnedPrivacy = r.privacy
        log.result = "Published"
        save()
    }

    public func publishApproved(_ source: Source) async {
        for rec in source.clips.filter({ $0.status == .approved }).sorted(by: { $0.createdAt < $1.createdAt }) {
            await publish(rec)
            if rec.status != .published { break }
        }
    }

    /// After a crash/quit mid-upload: ask YouTube what happened. Never re-POST automatically.
    func reconcileInterruptedUploads() async {
        // Clips rejected before rejecting meant deleting: delete them now.
        for rec in ((try? context.fetch(FetchDescriptor<ClipRecord>())) ?? []) where rec.status == .rejected {
            reject(rec, reason: rec.rejectReason)
        }
        let all = (try? context.fetch(FetchDescriptor<ClipRecord>())) ?? []
        // Skip anything belonging to a run that is already going (user pressed Start right after launch).
        for rec in all where rec.status == .rendering && rec.source?.id != runningSourceID {
            rec.status = .failed
            rec.lastError = "Rendering was interrupted. Open the clip and Re-render."
        }
        for s in (try? context.fetch(FetchDescriptor<Source>())) ?? [] where s.wasRunning && s.id != runningSourceID {
            notify("ClipForge stopped while processing “\(s.title)”. Select it and press Resume.", .info)
        }
        let stuck = ((try? context.fetch(FetchDescriptor<ClipRecord>())) ?? []).filter { $0.status == .publishing }
        for rec in stuck {
            guard let s = rec.uploadSessionURL.flatMap(URL.init(string:)), let file = rec.videoURL,
                  let size = try? PublishService.size(file),
                  let state = try? await publisher.status(session: s, size: size) else {
                rec.status = .approved
                rec.lastError = "Upload was interrupted. Check YouTube Studio before publishing again."
                continue
            }
            switch state {
            case .complete(let r):
                let log = PublishLogEntry(clipID: rec.id, sourceTitle: rec.source?.title ?? "", title: rec.title,
                                          requestedPrivacy: settings.privacyStatus, result: "", rightsBasis: "recovered after restart")
                context.insert(log)
                markPublished(rec, r, log: log)
            case .partial:
                rec.status = .approved
                rec.lastError = "Upload was interrupted; Publish will resume it."
            case .gone:
                rec.status = .approved
                rec.uploadSessionURL = nil
                rec.lastError = "Upload session expired before finishing. Check YouTube Studio before publishing again."
            }
        }
        save()
    }

    // MARK: Review

    public func approve(_ rec: ClipRecord) {
        guard rec.status == .ready else { return }
        rec.status = .approved
        save()
    }

    /// Rejecting deletes the clip — record and files. Its range is remembered on the source so it isn't cut again.
    public func reject(_ rec: ClipRecord, reason: String?) {
        guard ![.publishing, .published, .rendering].contains(rec.status) else { return }
        let r = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        Log.app.info("Rejected and deleted clip \(Int(rec.start))–\(Int(rec.end)) s\(r.isEmpty ? "" : ": " + r, privacy: .private)")
        if let src = rec.source { src.rejectedRanges.append([rec.start, rec.end]) }
        deleteFiles(of: rec)
        context.delete(rec)
        save()
    }

    func deleteFiles(of rec: ClipRecord) {
        guard let v = rec.videoURL else { return }
        let base = v.deletingPathExtension()
        for url in [v, base.appendingPathExtension("srt"), base.appendingPathExtension("framing.json"),
                    URL(fileURLWithPath: base.path + "-debug.mp4")] + (rec.srtPath.map { [URL(fileURLWithPath: $0)] } ?? []) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func approveAndPublish(_ rec: ClipRecord) async {
        approve(rec)
        await publish(rec)
    }

    /// Approve & Download: the final MP4 + SRT + a text file with title, description and hashtags.
    @discardableResult
    public func download(_ rec: ClipRecord, to dir: URL) -> URL? {
        guard let video = rec.videoURL, FileManager.default.fileExists(atPath: video.path) else {
            notify("Render the clip before downloading it.", .warning); return nil
        }
        if rec.status == .ready { approve(rec) }
        let base = rec.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").prefix(80)
        let out = dir.appendingPathComponent("\(base).mp4")
        do {
            try? FileManager.default.removeItem(at: out)
            try FileManager.default.copyItem(at: video, to: out)
            if let srt = rec.srtPath {
                let dst = out.deletingPathExtension().appendingPathExtension("srt")
                try? FileManager.default.removeItem(at: dst)
                try? FileManager.default.copyItem(at: URL(fileURLWithPath: srt), to: dst)
            }
            let alts = rec.titleOptions.filter(\.supported)
            let meta = "\(rec.title)\n\n\(rec.fullDescription)\n" + (rec.tags.isEmpty ? "" : "\nTags: \(rec.tags.joined(separator: ", "))\n")
                + (alts.isEmpty ? "" : "\nTitle options (fact-checked):\n" + alts.map { "- \($0.title) [\($0.hook)]\($0.recommended ? " ★" : "")" }.joined(separator: "\n") + "\n")
            try meta.write(to: out.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        } catch {
            rec.status = .failed
            rec.failure = .publish
            rec.lastError = "Download failed: \(error.localizedDescription)"
            save()
            return nil
        }
        rec.exportedPath = out.path
        if rec.status != .published { rec.status = .downloaded }
        rec.lastError = nil
        save()
        return out
    }

    /// Retry whatever failed: rendering re-renders, publishing re-publishes (resuming a partial upload).
    public func retry(_ rec: ClipRecord) async {
        guard rec.status == .failed else { return }
        if rec.failure == .publish, rec.videoURL != nil {
            rec.status = .approved
            await publish(rec)
        } else {
            await rerender(rec, start: rec.start, end: rec.end, style: rec.captionStyle)
        }
    }

    public func approveAll(_ recs: [ClipRecord]) { recs.forEach(approve) }
    public func rejectAll(_ recs: [ClipRecord], reason: String?) { recs.forEach { reject($0, reason: reason) } }
    public func publishAll(_ recs: [ClipRecord]) async {
        for r in recs { await approveAndPublish(r); if r.status == .failed, (r.lastError ?? "").contains("quota") { break } }
    }
}

extension AppModel {
    /// Upload any video from this Mac to the signed-in YouTube channel (not just ClipForge clips).
    /// You confirm you own it or have the rights; that confirmation is recorded in the publish log.
    public func uploadLocalFile(_ file: URL, title: String, description: String, tags: [String], privacy: String, rightsConfirmed: Bool) async throws -> String {
        guard rightsConfirmed else { throw ClipForgeError("Confirm that you own this video or have the rights to upload it.") }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 100 else { throw ClipForgeError("The title must be 1–100 characters.") }
        guard FileManager.default.isReadableFile(atPath: file.path) else { throw ClipForgeError("Can't read \(file.lastPathComponent).") }
        let req = UploadRequest(file: file, title: t, description: description, tags: tags, privacy: privacy)
        let basis = "Uploader confirmed they own or have the rights to “\(file.lastPathComponent)” on \(Date().formatted(date: .abbreviated, time: .shortened))"
        let log = PublishLogEntry(clipID: UUID(), sourceTitle: "Mac file: \(file.lastPathComponent)", title: t, requestedPrivacy: privacy, result: "uploading", rightsBasis: basis)
        context.insert(log)
        do {
            let r = try await publisher.upload(req, session: try await publisher.startSession(req))
            log.videoID = r.videoID; log.returnedPrivacy = r.privacy; log.result = "published"
            try? context.save()
            return r.videoID
        } catch {
            log.result = "failed: \(error.localizedDescription)"
            try? context.save()
            throw error
        }
    }
}
