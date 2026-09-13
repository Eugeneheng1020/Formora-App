import SwiftUI

/// JSON / XML / plist as a collapsible key–value tree. Keys are text people read (Sora); values are
/// data people check (JetBrains Mono), colored like the syntax palette.
struct ConfigTreeView: View {
    let root: ConfigNode

    @State private var collapsed: Set<String> = []

    private struct Row: Identifiable {
        let node: ConfigNode
        let depth: Int
        var id: String { node.id }
    }

    private var rows: [Row] {
        var result: [Row] = []
        func append(_ node: ConfigNode, depth: Int) {
            result.append(Row(node: node, depth: depth))
            guard !node.isLeaf, !collapsed.contains(node.id) else { return }
            for child in node.children { append(child, depth: depth + 1) }
        }
        // A synthetic "root" wrapper is not worth a row of its own.
        if root.key == "root", !root.isLeaf {
            for child in root.children { append(child, depth: 0) }
        } else {
            append(root, depth: 0)
        }
        return result
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    ConfigRow(node: row.node, depth: row.depth, isCollapsed: collapsed.contains(row.id)) {
                        if collapsed.contains(row.id) { collapsed.remove(row.id) } else { collapsed.insert(row.id) }
                    }
                }
            }
            .padding(12)
        }
        .background(Palette.surface.color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files.structured")
    }
}

private struct ConfigRow: View {
    let node: ConfigNode
    let depth: Int
    let isCollapsed: Bool
    let toggle: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            if node.isLeaf {
                Color.clear.frame(width: 12, height: 12)
            } else {
                IconView(Icons.chevronRight, size: 12)
                    .foregroundStyle(Palette.inkFaint.color)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
            }
            Text(node.key)
                .font(FormoraFont.ui(12.5, weight: 500))
                .foregroundStyle(node.key.hasPrefix("@") || node.key.hasPrefix("[") ? Palette.inkMuted.color : Palette.ink.color)
            if let value = node.value {
                Text(value)
                    .font(FormoraFont.mono(12))
                    .foregroundStyle(valueColor(value))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            } else if !node.isLeaf {
                Text("\(node.children.count) 项").font(FormoraFont.mono(10.5)).foregroundStyle(Palette.inkFaint.color)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 16 + 6)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(isHovering ? Palette.surfaceRaised.color : .clear))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { if !node.isLeaf { toggle() } }
    }

    /// Same hues as the syntax palette: strings green, numbers amber, literals accent.
    private func valueColor(_ value: String) -> Color {
        if value.hasPrefix("\"") { return Palette.success.color }
        if value == "true" || value == "false" || value == "null" { return Palette.accent.color }
        if Double(value) != nil { return Color(.sRGB, red: 0xE8 / 255, green: 0xA8 / 255, blue: 0x5C / 255) }
        return Palette.ink.color
    }
}
