import Foundation
import MeetingCore

func checkCaptionDisplay() throws {
    var assertions = 0
    func expect(_ condition: Bool, _ message: String) throws {
        assertions += 1
        if !condition { throw MeetingError.message(message) }
    }
    // Translation and source events arrive independently: the first translated words must be visible.
    var reducer = LiveTranslationReducer(source: .system, connectionID: "caption-display-check")
    let early = reducer.receive(["type": "session.output_transcript.delta", "delta": "大家好", "elapsed_ms": 100.0])[0]
    try expect(early.hasCaptionText, "Translation arriving before its source must appear in the overlay")
    try expect(early.primaryText == "大家好", "Early translation must lead the caption")
    try expect(early.secondaryText == nil, "An absent source must not reserve an empty second line")
    let complete = reducer.receive(["type": "session.input_transcript.delta", "delta": "Hello everyone", "elapsed_ms": 100.0])[0]
    try expect(complete.primaryText == "大家好" && complete.secondaryText == "Hello everyone", "Late source must join its translation")
    let blankTranslation = TranscriptSegment(id: "blank", source: .system, start: 0, end: 1, text: "Hello", translation: "  ")
    try expect(blankTranslation.primaryText == "Hello" && blankTranslation.secondaryText == nil, "Blank translation must preserve readable source text")
    let empty = TranscriptSegment(id: "empty", source: .system, start: 0, end: 1, text: " ", translation: "\n")
    try expect(!empty.hasCaptionText, "Whitespace-only segments must stay hidden")
    print("Caption display: \(assertions) assertions, 0 failures")
}
