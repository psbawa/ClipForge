import AppKit
import Foundation

/// Claude "watches" the whole video: every few seconds becomes a cell on a 3×3 contact sheet (with its timestamp),
/// Haiku rates each cell for what is happening. The result is a per-second visual-interest signal plus short labels —
/// so a moment that is great to look at but quiet still gets found, not only what the audio/motion signals flag.
enum VideoWatcher {
    struct Cell: Codable, Sendable { var t: Double; var score: Int; var label: String }

    static let model = "claude-haiku-5-5"
    static let grid = 3                     // 3×3 cells per sheet
    static let sheetsPerRequest = 3
    static let concurrency = 4
    static let maxCells = 540               // long videos widen the spacing instead of costing more
    static let minSpacing = 4.0
    static let cellSize = CGSize(width: 320, height: 180)

    static let system = """
    You are watching a video as contact sheets. Each sheet is a 3×3 grid of stills; the white label in each cell's corner is
    its timestamp in seconds. For EVERY cell, rate 0-10 how likely that moment is part of something worth clipping for
    Shorts/TikTok: action, a reveal or result, a big reaction, something impressive, funny or surprising, a clear payoff.
    Menus, loading screens, black frames, static talking with nothing happening, and repetitive filler score 0-3.
    Also give a label of at most 8 words saying what is happening.
    Output ONLY a JSON array: [{"t": 124, "score": 7, "label": "kids cheer as playground opens"}]
    """

    static func spacing(_ duration: Double) -> Double { max(minSpacing, (duration / Double(maxCells)).rounded(.up)) }

    /// Cells for the whole video; failed sheets are skipped (logged), never fatal.
    static func watch(_ scan: VideoScan, client: LLMClient, cost: CostTracker, settings: AppSettings,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> [Cell] {
        guard scan.frames != nil else { return [] }
        let step = spacing(scan.duration)
        let times = stride(from: step / 2, to: scan.duration, by: step).map { $0 }
        let perSheet = grid * grid
        let sheets = stride(from: 0, to: times.count, by: perSheet).map { Array(times[$0..<min($0 + perSheet, times.count)]) }
        let batches = stride(from: 0, to: sheets.count, by: sheetsPerRequest).map { Array(sheets[$0..<min($0 + sheetsPerRequest, sheets.count)]) }
        guard await cost.canSpend(budget: settings.dailyBudgetUSD) else { throw HighlightError.budgetReached }
        var cells: [Cell] = [], finished = 0
        try await withThrowingTaskGroup(of: [Cell].self) { g in
            var next = 0
            func add() {
                guard next < batches.count else { return }
                let b = batches[next]; next += 1
                g.addTask { await rate(b, scan: scan, client: client, cost: cost, settings: settings) }
            }
            for _ in 0..<concurrency { add() }
            while let r = try await g.next() {
                cells += r; finished += 1
                progress(Double(finished) / Double(max(batches.count, 1)))
                add()
            }
        }
        return cells.sorted { $0.t < $1.t }
    }

    static func rate(_ batch: [[Double]], scan: VideoScan, client: LLMClient, cost: CostTracker, settings: AppSettings) async -> [Cell] {
        var content: [LLMContent] = []
        for times in batch { if let jpeg = sheet(times, scan: scan) { content.append(.jpeg(jpeg)) } }
        guard !content.isEmpty else { return [] }
        let all = batch.flatMap { $0 }
        content.append(.text("Cells: \(all.map { String(Int($0)) }.joined(separator: ", ")). Rate every cell. Return the JSON array now."))
        do {
            let r = try await client.complete(model: model, system: system, content: content, maxTokens: 3000, effort: "low")
            await cost.record(r.usage, price: settings.prices[model])
            guard let a = r.text.firstIndex(of: "["), let b = r.text.lastIndex(of: "]"),
                  let parsed = try? JSONDecoder().decode([Cell].self, from: Data(r.text[a...b].utf8)) else { return [] }
            // Keep only cells we actually showed (snap the model's t to the nearest real cell).
            return parsed.compactMap { c in
                guard let t = all.min(by: { abs($0 - c.t) < abs($1 - c.t) }), abs(t - c.t) <= spacing(scan.duration) / 2 + 1 else { return nil }
                return Cell(t: t, score: max(0, min(10, c.score)), label: String(c.label.prefix(80)))
            }
        } catch {
            Log.ai.error("Watch pass sheet failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// 3×3 grid of frames with their timestamps drawn in the corner.
    static func sheet(_ times: [Double], scan: VideoScan) -> Data? {
        let W = cellSize.width * CGFloat(grid), H = cellSize.height * CGFloat(grid)
        let img = NSImage(size: NSSize(width: W, height: H))
        img.lockFocus()
        NSColor.black.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
        for (i, t) in times.enumerated() {
            let col = i % grid, row = i / grid
            let rect = NSRect(x: CGFloat(col) * cellSize.width, y: H - CGFloat(row + 1) * cellSize.height, width: cellSize.width, height: cellSize.height)
            if let f = scan.frame(at: t), let frame = NSImage(contentsOf: f) { frame.draw(in: rect.insetBy(dx: 1, dy: 1)) }
            let label = NSAttributedString(string: " \(Int(t)) ", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .bold),
                                                                                  .foregroundColor: NSColor.white, .backgroundColor: NSColor.black.withAlphaComponent(0.75)])
            label.draw(at: NSPoint(x: rect.minX + 4, y: rect.maxY - 26))
        }
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }

    /// Per-second 0–1 signal from the cells (each cell covers its spacing).
    static func signal(_ cells: [Cell], duration: Double) -> [Double] {
        let n = max(1, Int(duration.rounded(.up)))
        var out = [Double](repeating: 0, count: n)
        let half = spacing(duration) / 2
        for c in cells {
            for s in max(0, Int(c.t - half))..<min(n, Int((c.t + half).rounded(.up))) { out[s] = max(out[s], Double(c.score) / 10) }
        }
        return out
    }

    /// "2:05 builds the playground · 2:13 kids cheer" for one window.
    static func summary(_ cells: [Cell], from a: Double, to b: Double) -> String {
        cells.filter { $0.t >= a && $0.t <= b && $0.score >= 5 }.prefix(6)
            .map { String(format: "%d:%02d ", Int($0.t) / 60, Int($0.t) % 60) + $0.label + " (\($0.score))" }.joined(separator: " · ")
    }
}
