//
//  JSONTextView.swift
//  JSONExport
//
//  Text view for the raw JSON input. It can fold {...} / [...] blocks and highlights the line of a syntax error.
//  Folding hides the block's characters at the glyph level, so the text itself (and what gets parsed) never changes.
//

import Cocoa

class JSONTextView: NSTextView, NSLayoutManagerDelegate {

    //Character index of the beginning of each line
    private(set) var lineStarts: [Int] = [0]

    //Multi-line blocks that can be folded, keyed by the line their opening bracket is on
    private(set) var foldRegionsByLine: [Int: JSONFoldRegion] = [:]

    //Currently folded blocks, keyed by the location of their opening bracket
    private var foldedRegions: [Int: JSONFoldRegion] = [:]

    //Sorted, non overlapping ranges of hidden characters (nested folds are merged into their outer fold)
    private var hiddenRanges: [NSRange] = []

    //Location of the first hidden character of each visible fold, rendered as a "⋯" placeholder
    private var placeholderLocations: Set<Int> = []

    private let placeholderWidth: CGFloat = 26

    //Set after each parse. Highlights the line of the error
    var syntaxError: JSONSyntaxError? {
        didSet {
            if let error = syntaxError {
                unfoldRegions(containing: error.location)
            }
            needsDisplay = true
            gutterView?.needsDisplay = true
        }
    }

    var gutterView: JSONGutterView? {
        return enclosingScrollView?.verticalRulerView as? JSONGutterView
    }

    var isFoldable: Bool {
        return !foldRegionsByLine.isEmpty
    }

    //MARK: - Setup

    /**
     Configures the text view for editing JSON and installs the line numbers / folding gutter
     */
    func setUpJSONEditor() {
        font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textColor = NSColor.textColor
        backgroundColor = NSColor.textBackgroundColor
        enclosingScrollView?.backgroundColor = NSColor.textBackgroundColor
        textContainerInset = NSSize(width: 4, height: 6)
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false

        layoutManager?.delegate = self
        if let storage = textStorage {
            NotificationCenter.default.addObserver(self, selector: #selector(sourceTextDidProcessEditing(_:)), name: NSTextStorage.didProcessEditingNotification, object: storage)
        }

        if let scrollView = enclosingScrollView {
            let gutter = JSONGutterView(textView: self)
            scrollView.hasHorizontalRuler = false
            scrollView.hasVerticalRuler = true
            scrollView.verticalRulerView = gutter
            scrollView.rulersVisible = true
        }
        rebuildStructure()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    //MARK: - Tracking edits

    @objc private func sourceTextDidProcessEditing(_ notification: Notification) {
        guard let storage = textStorage, storage.editedMask.contains(.editedCharacters) else { return }
        let edited = storage.editedRange
        let delta = storage.changeInLength
        //Edited range before the edit, in the old coordinates
        let oldStart = edited.location
        let oldEnd = edited.location + edited.length - delta

        var dropped = [JSONFoldRegion]()
        var adjusted = [Int: JSONFoldRegion]()
        for region in foldedRegions.values {
            if oldEnd <= region.openLocation {
                let moved = JSONFoldRegion(openLocation: region.openLocation + delta, closeLocation: region.closeLocation + delta, depth: region.depth)
                adjusted[moved.openLocation] = moved
            } else if oldStart > region.closeLocation {
                adjusted[region.openLocation] = region
            } else {
                //Editing inside or on the edge of a folded block unfolds it
                dropped.append(region)
            }
        }
        foldedRegions = adjusted
        syntaxError = nil
        rebuildStructure()

        if !dropped.isEmpty {
            //Glyphs can't be invalidated while the text storage is processing an edit
            DispatchQueue.main.async {
                self.invalidateFoldLayout(for: dropped)
            }
        }
    }

    /**
     Recomputes the line starts and the foldable blocks, and drops folds whose brackets no longer match
     */
    private func rebuildStructure() {
        let chars = Array(string.utf16)
        var starts = [0]
        for (index, char) in chars.enumerated() where char == 0x0A {
            starts.append(index + 1)
        }
        lineStarts = starts

        var byLine = [Int: JSONFoldRegion]()
        var byOpenLocation = [Int: JSONFoldRegion]()
        for region in JSONSyntax.foldRegions(in: chars) {
            byOpenLocation[region.openLocation] = region
            let line = lineIndex(forCharacterAt: region.openLocation)
            guard line != lineIndex(forCharacterAt: region.closeLocation) else { continue }
            //When a line opens several blocks, i.e "[{", fold the outermost one
            if let existing = byLine[line], existing.openLocation < region.openLocation {
                continue
            }
            byLine[line] = region
        }
        foldRegionsByLine = byLine
        foldedRegions = foldedRegions.filter { byOpenLocation[$0.key]?.closeLocation == $0.value.closeLocation }
        rebuildHiddenRanges()
        gutterView?.invalidateLineNumbers()
    }

    /**
     Returns the index of the line containing the passed character index
     */
    func lineIndex(forCharacterAt location: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= location {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    //MARK: - Folding

    func isFolded(_ region: JSONFoldRegion) -> Bool {
        return foldedRegions[region.openLocation] != nil
    }

    func isHiddenCharacter(at location: Int) -> Bool {
        return hiddenRange(containing: location) != nil
    }

    func toggleFold(_ region: JSONFoldRegion) {
        if isFolded(region) {
            foldedRegions[region.openLocation] = nil
        } else {
            foldedRegions[region.openLocation] = region
            moveSelectionOutOfHiddenText(region)
        }
        rebuildHiddenRanges()
        invalidateFoldLayout(for: [region])
    }

    /**
     Folds every block except the root, so the top level keys stay visible
     */
    @objc func collapseAllBlocks(_ sender: Any?) {
        var folded = [Int: JSONFoldRegion]()
        for region in foldRegionsByLine.values where region.depth > 0 {
            folded[region.openLocation] = region
        }
        foldedRegions = folded
        rebuildHiddenRanges()
        if let outer = foldRegionsByLine.values.min(by: { $0.openLocation < $1.openLocation }) {
            moveSelectionOutOfHiddenText(outer)
        }
        invalidateFoldLayout(for: nil)
    }

    @objc func expandAllBlocks(_ sender: Any?) {
        foldedRegions.removeAll()
        rebuildHiddenRanges()
        invalidateFoldLayout(for: nil)
    }

    //Folds or unfolds the innermost block around the insertion point
    @objc func toggleFoldAtSelection(_ sender: Any?) {
        let location = selectedRange().location
        let candidates = foldRegionsByLine.values.filter { $0.openLocation <= location && location <= $0.closeLocation + 1 }
        if let region = candidates.max(by: { $0.openLocation < $1.openLocation }) {
            toggleFold(region)
        }
    }

    private func unfoldRegions(containing location: Int) {
        let containing = foldedRegions.values.filter { $0.openLocation < location && location < $0.closeLocation }
        guard !containing.isEmpty else { return }
        for region in containing {
            foldedRegions[region.openLocation] = nil
        }
        rebuildHiddenRanges()
        invalidateFoldLayout(for: containing)
    }

    private func moveSelectionOutOfHiddenText(_ region: JSONFoldRegion) {
        let selection = selectedRange()
        if selection.location > region.openLocation && selection.location <= region.closeLocation {
            setSelectedRange(NSRange(location: region.closeLocation + 1, length: 0))
        }
    }

    private func rebuildHiddenRanges() {
        var ranges = [NSRange]()
        for region in foldedRegions.values.sorted(by: { $0.openLocation < $1.openLocation }) {
            let range = region.hiddenRange
            guard range.length > 0 else { continue }
            if let last = ranges.last, NSMaxRange(last) >= NSMaxRange(range) {
                //Nested inside an already hidden block
                continue
            }
            ranges.append(range)
        }
        hiddenRanges = ranges
        placeholderLocations = Set(ranges.map { $0.location })
    }

    private func hiddenRange(containing location: Int) -> NSRange? {
        var low = 0
        var high = hiddenRanges.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = hiddenRanges[mid]
            if location < range.location {
                high = mid - 1
            } else if location >= NSMaxRange(range) {
                low = mid + 1
            } else {
                return range
            }
        }
        return nil
    }

    /**
     Regenerates the glyphs of the passed regions (or of the whole text when nil) so the fold state takes effect
     */
    private func invalidateFoldLayout(for regions: [JSONFoldRegion]?) {
        guard let layoutManager = layoutManager else { return }
        let length = (string as NSString).length
        var range = NSRange(location: 0, length: length)
        if let regions = regions, let first = regions.first {
            range = regions.dropFirst().reduce(NSRange(location: first.openLocation, length: first.closeLocation - first.openLocation + 1)) {
                NSUnionRange($0, NSRange(location: $1.openLocation, length: $1.closeLocation - $1.openLocation + 1))
            }
            range = NSIntersectionRange(range, NSRange(location: 0, length: length))
        }
        layoutManager.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        needsDisplay = true
        gutterView?.needsDisplay = true
    }

    //MARK: - NSLayoutManagerDelegate

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>, properties props: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard !hiddenRanges.isEmpty else { return 0 }
        let count = glyphRange.length
        var modified: [NSLayoutManager.GlyphProperty]?
        for i in 0..<count where isHiddenCharacter(at: charIndexes[i]) {
            if modified == nil {
                modified = Array(UnsafeBufferPointer(start: props, count: count))
            }
            //Hidden characters become control glyphs, their layout action is decided below
            modified![i] = .controlCharacter
        }
        guard let properties = modified else { return 0 }
        properties.withUnsafeBufferPointer { buffer in
            layoutManager.setGlyphs(glyphs, properties: buffer.baseAddress!, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
        }
        return count
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction, forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        if placeholderLocations.contains(charIndex) {
            return .whitespace
        }
        if isHiddenCharacter(at: charIndex) {
            return .zeroAdvancement
        }
        return action
    }

    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int, for textContainer: NSTextContainer, proposedLineFragment proposedRect: NSRect, glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let width = placeholderLocations.contains(charIndex) ? placeholderWidth : 0
        return NSRect(x: glyphPosition.x, y: 0, width: width, height: proposedRect.height)
    }

    //MARK: - Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawSyntaxError(in: rect)
        drawFoldPlaceholders(in: rect)
    }

    private func placeholderRect(at location: Int) -> NSRect? {
        guard let layoutManager = layoutManager, let container = textContainer, location < (string as NSString).length else { return nil }
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: location)
        var rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: container)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        rect.size.width = placeholderWidth
        return rect.insetBy(dx: 3, dy: 2)
    }

    private func drawFoldPlaceholders(in dirtyRect: NSRect) {
        guard !placeholderLocations.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let ellipsis = NSAttributedString(string: "⋯", attributes: attributes)
        for location in placeholderLocations {
            guard let rect = placeholderRect(at: location), rect.intersects(dirtyRect) else { continue }
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            let size = ellipsis.size()
            ellipsis.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }
    }

    private func drawSyntaxError(in dirtyRect: NSRect) {
        guard let error = syntaxError, let layoutManager = layoutManager, let container = textContainer else { return }
        let text = string as NSString
        let location = min(error.location, text.length)
        let origin = textContainerOrigin

        var lineRect: NSRect
        var lineUsedRect: NSRect
        if text.length == 0 || (location == text.length && text.hasSuffix("\n")) {
            lineRect = layoutManager.extraLineFragmentRect
            lineUsedRect = layoutManager.extraLineFragmentUsedRect
        } else {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: min(location, text.length - 1))
            lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            lineUsedRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        }
        lineRect.origin.y += origin.y
        lineUsedRect.origin.x += origin.x
        lineUsedRect.origin.y += origin.y
        //The used rect includes the trailing line break, measure the visible text instead
        let lineCharacters = text.lineRange(for: NSRange(location: location, length: 0))
        var textEnd = lineUsedRect.minX
        let visibleLength = (text.substring(with: lineCharacters) as NSString).trimmingCharacters(in: .newlines).utf16.count
        if visibleLength > 0 {
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: lineCharacters.location, length: visibleLength), actualCharacterRange: nil)
            textEnd = layoutManager.boundingRect(forGlyphRange: glyphs, in: container).maxX + origin.x
        }
        let highlight = NSRect(x: bounds.minX, y: lineRect.minY, width: bounds.width, height: lineRect.height)
        guard highlight.intersects(dirtyRect) else { return }

        NSColor.systemRed.withAlphaComponent(0.14).setFill()
        highlight.fill()
        NSColor.systemRed.setFill()
        NSRect(x: bounds.minX, y: highlight.minY, width: 3, height: highlight.height).fill()

        //Underline the offending character
        if location < text.length {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: location)
            var charRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: container)
            charRect.origin.x += origin.x
            charRect.origin.y += origin.y
            let isLineBreak = text.character(at: location) == 0x0A || text.character(at: location) == 0x0D
            let width = isLineBreak ? 7 : max(charRect.width, 7)
            NSRect(x: charRect.minX, y: lineUsedRect.maxY - 2, width: width, height: 2).fill()
        }

        //Show the message after the end of the line, like Xcode does
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.systemRed
        ]
        let message = NSAttributedString(string: "✕ " + error.message, attributes: attributes)
        let size = message.size()
        let x = max(textEnd + 24, bounds.maxX - size.width - 12)
        if x + size.width <= bounds.maxX - 4 {
            message.draw(at: NSPoint(x: x, y: lineRect.minY + (lineRect.height - size.height) / 2))
        }
    }

    //MARK: - Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for location in placeholderLocations {
            if let rect = placeholderRect(at: location), rect.contains(point), let region = foldedRegions.values.first(where: { $0.openLocation + 1 == location }) {
                toggleFold(region)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard isFoldable else { return menu }
        let items = [
            NSMenuItem(title: "Collapse All Blocks", action: #selector(collapseAllBlocks(_:)), keyEquivalent: ""),
            NSMenuItem(title: "Expand All Blocks", action: #selector(expandAllBlocks(_:)), keyEquivalent: ""),
            NSMenuItem.separator()
        ]
        for (index, item) in items.enumerated() {
            item.target = self
            menu.insertItem(item, at: index)
        }
        return menu
    }

    //⌥⌘← / ⌥⌘→ folds the block around the cursor, adding ⇧ applies to every block (same as Xcode)
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) && flags.contains(.option), let key = event.specialKey else {
            return super.performKeyEquivalent(with: event)
        }
        let allBlocks = flags.contains(.shift)
        switch key {
        case .leftArrow:
            allBlocks ? collapseAllBlocks(nil) : toggleFoldAtSelection(nil)
            return true
        case .rightArrow:
            allBlocks ? expandAllBlocks(nil) : toggleFoldAtSelection(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}
