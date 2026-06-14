import Foundation

public struct MobileSubtitleCue: Codable, Sendable, Equatable, Identifiable {
    public var index: Int
    public var startTime: String
    public var endTime: String
    public var text: String

    public var id: String { String(index) }

    public init(index: Int, startTime: String, endTime: String, text: String) {
        self.index = index
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

public struct MobileSubtitleDocument: Codable, Sendable, Equatable {
    public enum TranslationStyle: String, Codable, Sendable, Equatable, CaseIterable {
        case translatedOnly
        case bilingual
    }

    public var cues: [MobileSubtitleCue]

    public init(cues: [MobileSubtitleCue]) {
        self.cues = cues
    }

    public static func parseSRT(_ raw: String) -> MobileSubtitleDocument {
        var text = raw
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        struct Anchor {
            var lineIndex: Int
            var start: String
            var end: String
            var explicitIndex: Int?
            var hasIndexLine: Bool
        }

        var anchors: [Anchor] = []
        for (index, line) in lines.enumerated() {
            guard let times = parseSRTTimeLine(line) else { continue }
            let explicitIndex = index > 0
                ? Int(lines[index - 1].trimmingCharacters(in: .whitespacesAndNewlines))
                : nil
            anchors.append(Anchor(
                lineIndex: index,
                start: times.start,
                end: times.end,
                explicitIndex: explicitIndex,
                hasIndexLine: explicitIndex != nil
            ))
        }

        var cues: [MobileSubtitleCue] = []
        var nextIndex = 1
        for (anchorIndex, anchor) in anchors.enumerated() {
            var textEnd = lines.count
            if anchorIndex + 1 < anchors.count {
                let next = anchors[anchorIndex + 1]
                textEnd = next.hasIndexLine ? next.lineIndex - 1 : next.lineIndex
            }
            let textStart = anchor.lineIndex + 1
            guard textStart <= textEnd else { continue }
            let textLines = lines[textStart..<textEnd]
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !textLines.isEmpty else { continue }

            let cueIndex = anchor.explicitIndex ?? nextIndex
            cues.append(MobileSubtitleCue(
                index: cueIndex,
                startTime: anchor.start,
                endTime: anchor.end,
                text: textLines.joined(separator: "\n")
            ))
            nextIndex = cueIndex + 1
        }

        return MobileSubtitleDocument(cues: cues)
    }

    public func cleanedForTranslation() -> MobileSubtitleDocument {
        guard !cues.isEmpty else { return self }

        var timed: [Timed] = cues.enumerated().compactMap { offset, cue in
            guard let start = Self.seconds(fromSRTTime: cue.startTime),
                  let end = Self.seconds(fromSRTTime: cue.endTime) else {
                return nil
            }
            return Timed(start: start, end: max(start, end), text: cue.text, order: offset)
        }
        guard !timed.isEmpty else { return self }
        timed.sort { lhs, rhs in
            lhs.start == rhs.start ? lhs.order < rhs.order : lhs.start < rhs.start
        }

        let textRepeatRatio = Self.textRepeatRatio(in: timed.map(\.text))
        if textRepeatRatio > 0.3 {
            timed = Self.dedupRollingText(timed)
        }
        let overlapRatio = Self.overlapRatio(in: timed)
        let isRolling = overlapRatio > 0.5 || textRepeatRatio > 0.3

        timed = Self.trimOverlaps(timed)
        let output = isRolling ? Self.mergeRollingCues(timed) : timed
        return MobileSubtitleDocument(cues: Self.makeCues(output))
    }

    public func translationRequest(context: TranslationContext) -> MobileTranslationRequest {
        MobileTranslationRequest(
            segments: cues.map {
                MobileTranslationSegment(
                    id: String($0.index),
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    text: $0.text
                )
            },
            context: context
        )
    }

    public func applying(
        _ translation: MobileTranslationResult,
        style: TranslationStyle
    ) -> MobileSubtitleDocument {
        var translations: [String: String] = [:]
        for segment in translation.segments {
            translations[segment.id] = segment.text
        }
        return MobileSubtitleDocument(cues: cues.map { cue in
            let translated = translations[String(cue.index)] ?? cue.text
            let text: String
            switch style {
            case .translatedOnly:
                text = translated
            case .bilingual:
                text = translated == cue.text ? translated : "\(translated)\n\(cue.text)"
            }
            return MobileSubtitleCue(
                index: cue.index,
                startTime: cue.startTime,
                endTime: cue.endTime,
                text: text
            )
        })
    }

    public func serializedSRT() -> String {
        cues
            .map { "\($0.index)\n\($0.startTime) --> \($0.endTime)\n\($0.text)" }
            .joined(separator: "\n\n") + "\n"
    }

    private static func parseSRTTimeLine(_ line: String) -> (start: String, end: String)? {
        let pattern = #"(\d{1,2}:\d{2}:\d{2}[,\.]\d{1,3})\s*-->\s*(\d{1,2}:\d{2}:\d{2}[,\.]\d{1,3})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let startRange = Range(match.range(at: 1), in: line),
              let endRange = Range(match.range(at: 2), in: line) else {
            return nil
        }
        return (String(line[startRange]), String(line[endRange]))
    }

    private static func seconds(fromSRTTime value: String) -> Double? {
        let normalized = value.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":")
        guard parts.count == 3,
              let hours = Int(parts[0]),
              let minutes = Int(parts[1]),
              let seconds = Double(parts[2]) else {
            return nil
        }
        return Double(hours) * 3_600 + Double(minutes) * 60 + seconds
    }

    private static func srtTime(from seconds: Double) -> String {
        let totalMilliseconds = Int((max(0, seconds) * 1000).rounded())
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let secondsPart = totalSeconds % 60
        let minutesPart = (totalSeconds / 60) % 60
        let hoursPart = totalSeconds / 3_600
        return String(format: "%02d:%02d:%02d,%03d", hoursPart, minutesPart, secondsPart, milliseconds)
    }

    private static func overlapRatio(in timed: [Timed]) -> Double {
        guard timed.count >= 2 else { return 0 }
        let overlaps = (1..<timed.count).filter { timed[$0].start < timed[$0 - 1].end }.count
        return Double(overlaps) / Double(timed.count - 1)
    }

    private static func textRepeatRatio(in texts: [String]) -> Double {
        guard texts.count >= 2 else { return 0 }
        let pairs = (1..<texts.count).filter { index in
            overlapPrefixCount(
                previous: texts[index - 1].components(separatedBy: "\n"),
                current: texts[index].components(separatedBy: "\n")
            ) > 0
        }.count
        return Double(pairs) / Double(texts.count - 1)
    }

    private static func overlapPrefixCount(previous: [String], current: [String]) -> Int {
        var count = min(previous.count, current.count)
        while count > 0 {
            if Array(previous.suffix(count)) == Array(current.prefix(count)) {
                return count
            }
            count -= 1
        }
        return 0
    }

    private static func dedupRollingText(_ timed: [Timed]) -> [Timed] {
        var output: [Timed] = []
        var previousOriginalLines: [String] = []
        for item in timed {
            let currentLines = item.text.components(separatedBy: "\n")
            let duplicateCount = overlapPrefixCount(previous: previousOriginalLines, current: currentLines)
            previousOriginalLines = currentLines
            let newLines = Array(currentLines.dropFirst(duplicateCount))
            guard !newLines.isEmpty else { continue }
            var copy = item
            copy.text = newLines.joined(separator: "\n")
            output.append(copy)
        }
        return output.isEmpty ? timed : output
    }

    private static func trimOverlaps(_ timed: [Timed]) -> [Timed] {
        var output = timed
        let minimumDuration = 0.3
        for index in output.indices {
            let nextStart = output.index(after: index) < output.endIndex
                ? output[output.index(after: index)].start
                : nil
            if let nextStart {
                output[index].end = min(output[index].end, nextStart)
            }
            if output[index].end - output[index].start < minimumDuration {
                var compensated = output[index].start + minimumDuration
                if let nextStart {
                    compensated = min(compensated, nextStart)
                }
                output[index].end = compensated
            }
        }
        return output
    }

    private static func mergeRollingCues(_ timed: [Timed]) -> [Timed] {
        var output: [Timed] = []
        var currentText = ""
        var currentStart = 0.0
        var currentEnd = 0.0
        var hasCurrent = false

        func normalized(_ text: String) -> String {
            text.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        func endsSentence(_ text: String) -> Bool {
            let trailingAllowed: Set<Character> = ["\"", "'", "”", "’", ")", "）", "」", "』", "]"]
            let sentenceEnders: Set<Character> = [".", "!", "?", "。", "！", "？"]
            var characters = Array(text)
            while let last = characters.last, trailingAllowed.contains(last) || last == " " {
                characters.removeLast()
            }
            return characters.last.map { sentenceEnders.contains($0) } ?? false
        }

        func flush() {
            guard hasCurrent else { return }
            output.append(Timed(start: currentStart, end: currentEnd, text: currentText, order: output.count))
            currentText = ""
            hasCurrent = false
        }

        for item in timed {
            let text = normalized(item.text)
            guard !text.isEmpty else { continue }
            if !hasCurrent {
                hasCurrent = true
                currentStart = item.start
                currentText = text
            } else {
                currentText += " " + text
            }
            currentEnd = item.end

            if endsSentence(currentText) || currentEnd - currentStart >= 6 || currentText.count >= 84 {
                flush()
            }
        }
        flush()

        return output.count >= timed.count ? timed : output
    }

    private static func makeCues(_ timed: [Timed]) -> [MobileSubtitleCue] {
        timed.enumerated().map { offset, item in
            MobileSubtitleCue(
                index: offset + 1,
                startTime: srtTime(from: item.start),
                endTime: srtTime(from: item.end),
                text: item.text
            )
        }
    }
}

private struct Timed {
    var start: Double
    var end: Double
    var text: String
    var order: Int
}
