import Foundation

/// One row in the structured view of a JSON, XML or property-list file. Branches have `children`,
/// leaves have a `value`. Ids are path-derived: unique in the tree and stable across re-parses.
struct ConfigNode: Identifiable, Equatable, Sendable {
    let id: String
    let key: String
    let value: String?
    let children: [ConfigNode]

    var isLeaf: Bool { children.isEmpty }

    /// Nesting past this depth becomes a leaf that says so, instead of overflowing the stack.
    static let maxDepth = 100
}

// MARK: - JSON and property lists

extension ConfigNode {
    static func parseJSON(_ data: Data) -> ConfigNode? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return objectNode(key: "root", value: object, path: "", depth: 0, sortKeys: true)
    }

    /// XML or binary plists.
    static func parsePropertyList(_ data: Data) -> ConfigNode? {
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return nil }
        return objectNode(key: "root", value: object, path: "", depth: 0, sortKeys: true)
    }

    private static func objectNode(key: String, value: Any, path: String, depth: Int, sortKeys: Bool) -> ConfigNode {
        let id = path.isEmpty ? key : "\(path).\(key)"
        guard depth < maxDepth else { return ConfigNode(id: id, key: key, value: "（嵌套过深，未展开）", children: []) }
        if let dict = value as? [String: Any] {
            let children = dict.keys.sorted().map { objectNode(key: $0, value: dict[$0]!, path: id, depth: depth + 1, sortKeys: sortKeys) }
            return ConfigNode(id: id, key: key, value: nil, children: children)
        }
        if let array = value as? [Any] {
            let children = array.enumerated().map {
                objectNode(key: "[\($0.offset)]", value: $0.element, path: id, depth: depth + 1, sortKeys: sortKeys)
            }
            return ConfigNode(id: id, key: key, value: nil, children: children)
        }
        return ConfigNode(id: id, key: key, value: leafText(value), children: [])
    }

    private static func leafText(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let string = value as? String { return "\"\(string)\"" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        if let date = value as? Date { return date.ISO8601Format() }
        if let data = value as? Data { return "<\(data.count) 字节>" }
        return String(describing: value)
    }
}

// MARK: - XML

extension ConfigNode {
    static func parseXML(_ data: Data) -> ConfigNode? {
        let builder = XMLTreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse() else { return nil }
        return builder.root
    }
}

/// SAX → tree. Attributes become `@name` children; text next to child elements becomes a `#text`
/// child instead of being dropped (old app fix).
private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    private struct Frame {
        let key: String
        let id: String
        var children: [ConfigNode]
        var text: String
    }

    private var stack: [Frame] = []
    private(set) var root: ConfigNode?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if stack.count >= ConfigNode.maxDepth {
            parser.abortParsing()
            return
        }
        let parentID = stack.last?.id ?? ""
        let index = stack.last?.children.count ?? 0
        let id = parentID.isEmpty ? elementName : "\(parentID).\(index).\(elementName)"
        let attributeNodes = attributes.keys.sorted().map {
            ConfigNode(id: "\(id)@\($0)", key: "@\($0)", value: attributes[$0], children: [])
        }
        stack.append(Frame(key: elementName, id: id, children: attributeNodes, text: ""))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        guard let frame = stack.popLast() else { return }
        let text = frame.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var children = frame.children
        if !children.isEmpty, !text.isEmpty {
            children.append(ConfigNode(id: "\(frame.id)#text", key: "#text", value: text, children: []))
        }
        let node = ConfigNode(id: frame.id, key: frame.key, value: children.isEmpty ? (text.isEmpty ? nil : text) : nil,
                              children: children)
        if stack.isEmpty { root = node } else { stack[stack.count - 1].children.append(node) }
    }
}
