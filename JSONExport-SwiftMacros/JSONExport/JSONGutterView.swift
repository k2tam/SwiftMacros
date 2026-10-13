//
//  JSONGutterView.swift
//  JSONExport
//
//  Ruler for JSONTextView: line numbers, fold toggles and a marker on the line of a syntax error.
//

import Cocoa

class JSONGutterView: NSRulerView {

    private weak var jsonTextView: JSONTextView?

    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    private let foldColumnWidth: CGFloat = 14
    private let horizontalPadding: CGFloat = 6

    init(textView: JSONTextView) {
        jsonTextView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = requiredThickness
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        return true
    }

    override var requiredThickness: CGFloat {
        let lineCount = jsonTextView?.lineStarts.count ?? 1
        let digits = max(2, String(lineCount).count)
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: numberFont]).width
        return ceil(CGFloat(digits) * digitWidth + horizontalPadding * 2 + foldColumnWidth)
    }

    /**
     Call after the text changes so the gutter grows with the number of lines
     */
    func invalidateLineNumbers() {
        let thickness = requiredThickness
        if abs(ruleThickness - thickness) > 0.5 {
            ruleThickness = thickness
        }
        needsDisplay = true
    }

    //MARK: - Drawing

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()

        guard let textView = jsonTextView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let text = textView.string as NSString
        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let errorLine = textView.syntaxError.map { textView.lineIndex(forCharacterAt: min($0.location, text.length)) }
        let lineStarts = textView.lineStarts

        var line = textView.lineIndex(forCharacterAt: characterRange.location)
        var lastDrawnY: CGFloat = -.greatestFiniteMagnitude
        while line < lineStarts.count {
            let start = lineStarts[line]
            if start > NSMaxRange(characterRange) {
                break
            }
            defer { line += 1 }
            if textView.isHiddenCharacter(at: start) {
                continue
            }
            var fragment: NSRect
            if start < text.length {
                fragment = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: start), effectiveRange: nil)
            } else {
                fragment = layoutManager.extraLineFragmentRect
            }
            fragment.origin.y += textView.textContainerOrigin.y
            //A line that starts with the closing bracket of a folded block shares the fold's visual line
            if fragment.minY <= lastDrawnY {
                continue
            }
            lastDrawnY = fragment.minY
            let y = convert(NSPoint(x: 0, y: fragment.minY), from: textView).y
            let rowRect = NSRect(x: 0, y: y, width: bounds.width - 1, height: fragment.height)
            guard rowRect.intersects(rect) else { continue }
            drawRow(line: line, in: rowRect, isError: line == errorLine, region: textView.foldRegionsByLine[line], textView: textView)
        }
    }

    private func drawRow(line: Int, in rowRect: NSRect, isError: Bool, region: JSONFoldRegion?, textView: JSONTextView) {
        if isError {
            NSColor.systemRed.withAlphaComponent(0.18).setFill()
            rowRect.fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: isError ? NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold) : numberFont,
            .foregroundColor: isError ? NSColor.systemRed : NSColor.tertiaryLabelColor
        ]
        let label = NSAttributedString(string: "\(line + 1)", attributes: attributes)
        let size = label.size()
        let numberRight = rowRect.maxX - foldColumnWidth - 2
        label.draw(at: NSPoint(x: numberRight - size.width, y: rowRect.minY + (min(rowRect.height, 18) - size.height) / 2))

        guard let region = region else { return }
        let folded = textView.isFolded(region)
        let symbolName = folded ? "chevron.right" : "chevron.down"
        let configuration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: folded ? "Expand" : "Collapse")?.withSymbolConfiguration(configuration) else { return }
        let tint = folded ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
        let tinted = NSImage(size: image.size, flipped: false) { drawRect in
            image.draw(in: drawRect)
            tint.set()
            drawRect.fill(using: .sourceAtop)
            return true
        }
        let lineHeight = min(rowRect.height, 18)
        let imageRect = NSRect(x: rowRect.maxX - foldColumnWidth + (foldColumnWidth - image.size.width) / 2,
                               y: rowRect.minY + (lineHeight - image.size.height) / 2,
                               width: image.size.width, height: image.size.height)
        tinted.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    //MARK: - Events

    private func foldRegion(at event: NSEvent) -> JSONFoldRegion? {
        guard let textView = jsonTextView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return nil }
        let point = textView.convert(convert(event.locationInWindow, from: nil), from: self)
        let containerPoint = NSPoint(x: 0, y: point.y - textView.textContainerOrigin.y)
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: container)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        guard containerPoint.y >= fragment.minY && containerPoint.y < fragment.maxY else { return nil }
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        return textView.foldRegionsByLine[textView.lineIndex(forCharacterAt: characterIndex)]
    }

    override func mouseDown(with event: NSEvent) {
        if let region = foldRegion(at: event) {
            jsonTextView?.toggleFold(region)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let textView = jsonTextView, textView.isFoldable else { return nil }
        let menu = NSMenu()
        let collapse = NSMenuItem(title: "Collapse All Blocks", action: #selector(JSONTextView.collapseAllBlocks(_:)), keyEquivalent: "")
        let expand = NSMenuItem(title: "Expand All Blocks", action: #selector(JSONTextView.expandAllBlocks(_:)), keyEquivalent: "")
        collapse.target = textView
        expand.target = textView
        menu.addItem(collapse)
        menu.addItem(expand)
        return menu
    }
}
