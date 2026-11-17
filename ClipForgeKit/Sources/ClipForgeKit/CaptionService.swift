import AppKit
import Foundation

/// Karaoke captions rendered as transparent 1080×1920 PNG frames (one per active word),
/// stitched with an ffconcat timeline and overlaid by ffmpeg. Works without libass.
/// Where a caption layer sits on the 1080×1920 canvas.
public enum CaptionPlacement: Sendable {
    /// Highlight clips (original layout).
    case clip
    /// Story Shorts speech subtitles: lower middle, clear of the bottom 20% and the right-edge platform buttons.
    case subtitle
    /// Story Shorts narrative text: upper third, inside the same side margins.
    case narrative

    /// Text rect in CoreGraphics coordinates (origin bottom-left) for a block of `height` points.
    public func rect(height: Double, W: Double = 1080, H: Double = 1920) -> CGRect {
        switch self {
        case .clip: return CGRect(x: (W - min(960, W - 120)) / 2, y: H * 0.26, width: min(960, W - 120), height: height)
        case .subtitle: return CGRect(x: StoryConfig.safeLeft, y: H * StoryConfig.subtitleBottom, width: W - StoryConfig.safeLeft - StoryConfig.safeRight, height: height)
        case .narrative: return CGRect(x: StoryConfig.safeLeft, y: H * StoryConfig.narrativeTop - height, width: W - StoryConfig.safeLeft - StoryConfig.safeRight, height: height)
        }
    }
}

public enum CaptionService {
    struct Group { var words: [Word] }

    /// Short caption lines (≤ 4 words / 24 chars), broken at sentence ends. Times are clip-relative.
    static func groups(_ words: [Word], clipStart: Double, clipEnd: Double) -> [Group] {
        var out: [Group] = [], cur: [Word] = []
        for w in words where w.end > clipStart && w.start < clipEnd {
            let rel = Word(w.text, max(0, w.start - clipStart), min(clipEnd, w.end) - clipStart)
            // New line at a cut (words overlap across a crossfade) or after a long pause.
            if let last = cur.last, rel.start < last.end - 0.05 || rel.start - last.end > 1.0 { out.append(Group(words: cur)); cur = [] }
            cur.append(rel)
            let chars = cur.map(\.text.count).reduce(0, +) + cur.count
            if rel.endsSentence || cur.count >= 4 || chars >= 24 { out.append(Group(words: cur)); cur = [] }
        }
        if !cur.isEmpty { out.append(Group(words: cur)) }
        return out
    }

    public static func srt(_ words: [Word], clipStart: Double, clipEnd: Double) -> String {
        func ts(_ t: Double) -> String {
            let ms = Int((t * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return groups(words, clipStart: clipStart, clipEnd: clipEnd).enumerated().map { i, g in
            "\(i + 1)\n\(ts(g.words.first!.start)) --> \(ts(g.words.last!.end))\n\(g.words.joinedText)\n"
        }.joined(separator: "\n")
    }

    struct Frame: Equatable { var group: Int; var word: Int; var dur: Double }  // group -1 = blank

    /// Frame timeline covering [0, duration]: one frame per active word, blanks in gaps.
    static func timeline(_ groups: [Group], duration: Double) -> [Frame] {
        var out: [Frame] = [], t = 0.0
        func blank(until end: Double) { if end > t + 0.01 { out.append(Frame(group: -1, word: -1, dur: end - t)); t = end } }
        for (gi, g) in groups.enumerated() {
            let nextStart = gi + 1 < groups.count ? groups[gi + 1].words[0].start : duration
            blank(until: g.words[0].start)
            for wi in g.words.indices {
                let until = wi + 1 < g.words.count ? g.words[wi + 1].start : min(nextStart, g.words[wi].end + 0.4)
                let d = max(until - t, 0.04)
                out.append(Frame(group: gi, word: wi, dur: d)); t += d
            }
        }
        blank(until: duration)
        return out
    }

    /// Writes PNGs + ffconcat list into `dir`; returns the list URL.
    public static func renderOverlay(_ words: [Word], clipStart: Double, clipEnd: Double, style: CaptionStyle,
                                     placement: CaptionPlacement = .clip, canvas: CGSize = CGSize(width: 1080, height: 1920),
                                     pop: Bool = false, into dir: URL) throws -> URL {
        let gs = groups(words, clipStart: clipStart, clipEnd: clipEnd)
        let items = timeline(gs, duration: clipEnd - clipStart)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let blank = dir.appendingPathComponent("blank.png")
        try png(nil, style: style, canvas: canvas).write(to: blank)
        var list = "ffconcat version 1.0\n", last = blank
        for (i, it) in items.enumerated() {
            var file = blank
            if it.group >= 0 {
                let words = gs[it.group].words.map(\.text)
                file = dir.appendingPathComponent(String(format: "c%05d.png", i))
                try png((words, it.word), style: style, placement: placement, canvas: canvas).write(to: file)
                // "Pop" animation: the new active word appears 25% bigger for a few frames, then settles.
                if pop, it.dur > 0.15 {
                    let popFile = dir.appendingPathComponent(String(format: "p%05d.png", i))
                    try png((words, it.word), style: style, placement: placement, canvas: canvas, popActive: true).write(to: popFile)
                    list += "file '\(popFile.lastPathComponent)'\nduration 0.080\nfile '\(file.lastPathComponent)'\nduration \(String(format: "%.3f", it.dur - 0.08))\n"
                    last = file
                    continue
                }
            }
            list += "file '\(file.lastPathComponent)'\nduration \(String(format: "%.3f", it.dur))\n"
            last = file
        }
        list += "file '\(last.lastPathComponent)'\n" // concat demuxer needs the final entry repeated
        let url = dir.appendingPathComponent("captions.ffconcat")
        try list.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func png(_ line: (words: [String], active: Int)?, style: CaptionStyle, placement: CaptionPlacement = .clip,
                    canvas: CGSize = CGSize(width: 1080, height: 1920), popActive: Bool = false) throws -> Data {
        let W = Int(canvas.width), H = Int(canvas.height)
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ClipForgeError("Could not create caption canvas") }
        if let line {
            let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = gc
            let text = attributed(line.words, active: line.active, style: style, popActive: popActive)
            let maxWidth = placement.rect(height: 0, W: Double(W), H: Double(H)).width
            let box = text.boundingRect(with: NSSize(width: maxWidth, height: 600), options: [.usesLineFragmentOrigin])
            let rect = placement.rect(height: ceil(box.height), W: Double(W), H: Double(H))
            if style == .boxed {
                let pad = 28.0, bw = min(ceil(box.width) + pad * 2, maxWidth + 40)
                NSColor.black.withAlphaComponent(0.72).setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.midX - bw / 2, y: rect.minY - pad / 2, width: bw, height: rect.height + pad),
                             xRadius: 24, yRadius: 24).fill()
            }
            text.draw(with: rect, options: [.usesLineFragmentOrigin])
            NSGraphicsContext.restoreGraphicsState()
        }
        guard let img = ctx.makeImage(), let data = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
        else { throw ClipForgeError("Could not encode caption frame") }
        return data
    }

    static func attributed(_ words: [String], active: Int, style: CaptionStyle, popActive: Bool = false) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 10
        let (font, base, hi): (NSFont, NSColor, NSColor) = switch style {
        case .pop: (.systemFont(ofSize: 92, weight: .black), .white, NSColor(red: 1, green: 0.9, blue: 0, alpha: 1))
        case .clean: (.systemFont(ofSize: 66, weight: .semibold), .white, NSColor(red: 0.45, green: 0.85, blue: 1, alpha: 1))
        case .boxed: (.systemFont(ofSize: 72, weight: .bold), .white, NSColor(red: 0.3, green: 1, blue: 0.5, alpha: 1))
        }
        let s = NSMutableAttributedString()
        for (i, w) in words.enumerated() {
            let f = popActive && i == active ? NSFont.systemFont(ofSize: font.pointSize * 1.25, weight: style == .pop ? .black : .bold) : font
            var a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: i == active ? hi : base, .paragraphStyle: para]
            if style == .pop { a[.strokeColor] = NSColor.black; a[.strokeWidth] = -6.0 }
            if style != .boxed { a[.shadow] = shadow }
            s.append(NSAttributedString(string: (i > 0 ? " " : "") + (style == .pop ? w.uppercased() : w), attributes: a))
        }
        return s
    }
}
