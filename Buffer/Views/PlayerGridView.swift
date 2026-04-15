import SwiftUI

/// Multi-view grid: one cell per slot, hosted in a stable `ForEach` with
/// absolute positioning. Each cell contains an `MPVMetalView` that mounts
/// the slot's `CAMetalLayer`. Layout changes only recompute each cell's
/// `.frame` + `.offset` — the cells themselves and their layers are never
/// destroyed by a layout switch.
///
/// Used for both single (one full-window cell) and multi (N positioned
/// cells) so there is exactly one rendering code path.
struct PlayerGridView: View {
    let session: PlayerSession

    private let gap: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let rects = computeRects(in: proxy.size)
            ZStack(alignment: .topLeading) {
                ForEach(session.slots, id: \.id) { slot in
                    let rect = rects[slot.id] ?? .zero
                    PlayerSlotCell(
                        slot: slot,
                        isFocused: slot.id == session.focusedSlotID,
                        canRemove: session.slots.count > 1,
                        showCellChrome: session.isMulti,
                        onFocus: { session.focus(slotID: slot.id) },
                        onRemove: { session.removeSlot(id: slot.id) }
                    )
                    .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                    .offset(x: rect.origin.x, y: rect.origin.y)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    // MARK: - Layout math

    private func computeRects(in size: CGSize) -> [UUID: CGRect] {
        var result: [UUID: CGRect] = [:]
        for (index, slot) in session.slots.enumerated() {
            result[slot.id] = frame(at: index, slotID: slot.id, in: size)
        }
        return result
    }

    private func frame(at index: Int, slotID: UUID, in size: CGSize) -> CGRect {
        switch session.layout {
        case .single:
            return CGRect(origin: .zero, size: size)

        case .oneTwo:
            return oneTwoFrame(index: index, in: size)

        case .twoByTwo:
            return gridFrame(index: index, cols: 2, rows: 2, in: size)

        case .threeByThree:
            return gridFrame(index: index, cols: 3, rows: 3, in: size)

        case .focusedThumbnails:
            return focusedThumbnailsFrame(slotID: slotID, in: size)
        }
    }

    private func oneTwoFrame(index: Int, in size: CGSize) -> CGRect {
        let sideWidth = max(size.width * 0.3, 200)
        let mainWidth = max(size.width - sideWidth - gap, 1)
        if index == 0 {
            return CGRect(x: 0, y: 0, width: mainWidth, height: size.height)
        }
        let visibleSides = min(max(session.slots.count - 1, 1), 2)
        let sideHeight = (size.height - CGFloat(visibleSides - 1) * gap) / CGFloat(visibleSides)
        let sideIndex = index - 1
        let y = CGFloat(sideIndex) * (sideHeight + gap)
        return CGRect(x: mainWidth + gap, y: y, width: sideWidth, height: sideHeight)
    }

    private func gridFrame(index: Int, cols: Int, rows: Int, in size: CGSize) -> CGRect {
        let col = index % cols
        let row = index / cols
        if row >= rows {
            return CGRect(x: -10000, y: -10000, width: 1, height: 1)
        }
        let cellW = (size.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let cellH = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        return CGRect(
            x: CGFloat(col) * (cellW + gap),
            y: CGFloat(row) * (cellH + gap),
            width: cellW,
            height: cellH
        )
    }

    private func focusedThumbnailsFrame(slotID: UUID, in size: CGSize) -> CGRect {
        let thumbs = session.slots.filter { $0.id != session.focusedSlotID }
        let thumbHeight = max(min(size.height * 0.2, 160), 100)
        let focusHeight = max(size.height - thumbHeight - gap, 1)

        if slotID == session.focusedSlotID {
            return CGRect(x: 0, y: 0, width: size.width, height: focusHeight)
        }
        guard let tIdx = thumbs.firstIndex(where: { $0.id == slotID }) else {
            return .zero
        }
        let count = max(thumbs.count, 1)
        let thumbW = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
        return CGRect(
            x: CGFloat(tIdx) * (thumbW + gap),
            y: focusHeight + gap,
            width: thumbW,
            height: thumbHeight
        )
    }
}
