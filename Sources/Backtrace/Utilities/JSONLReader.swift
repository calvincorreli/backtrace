import Foundation

enum JSONLReader {
    static func sampledObjects(
        at url: URL,
        prefixBytes: Int = 98_304,
        suffixBytes: Int = 65_536
    ) throws -> [[String: Any]] {
        let data = try SessionFileData.read(url)
        guard !data.isEmpty else { return [] }

        if data.count <= prefixBytes + suffixBytes {
            return objects(in: data)
        }

        var result = objects(in: Data(data.prefix(prefixBytes)), dropIncompleteLastLine: true)
        let suffixStart = max(prefixBytes, data.count - suffixBytes)
        var alignedStart = suffixStart
        while alignedStart < data.count, data[alignedStart] != 0x0A {
            alignedStart += 1
        }
        if alignedStart < data.count {
            let suffix = Data(data[(alignedStart + 1)...])
            result.append(contentsOf: objects(in: suffix))
        }
        return result
    }

    static func objects(
        at url: URL,
        until shouldStop: ([String: Any], Int) -> Bool = { _, _ in false }
    ) throws -> ([[String: Any]], Bool) {
        try Task.checkCancellation()
        let data = try SessionFileData.read(url)
        try Task.checkCancellation()
        var values: [[String: Any]] = []
        var lineStart = data.startIndex
        var lineNumber = 0

        while lineStart < data.endIndex {
            try Task.checkCancellation()
            let lineEnd = data[lineStart...].firstIndex(of: 0x0A) ?? data.endIndex
            if lineEnd > lineStart {
                let line = Data(data[lineStart..<lineEnd])
                if let object = JSONValue.object(from: line) {
                    values.append(object)
                    if shouldStop(object, lineNumber) {
                        return (values, lineEnd < data.endIndex)
                    }
                }
            }
            lineNumber += 1
            if lineEnd == data.endIndex { break }
            lineStart = data.index(after: lineEnd)
        }
        return (values, false)
    }

    private static func objects(in data: Data, dropIncompleteLastLine: Bool = false) -> [[String: Any]] {
        var working = data
        if dropIncompleteLastLine,
           let lastNewline = working.lastIndex(of: 0x0A),
           lastNewline < working.endIndex {
            working = Data(working[..<lastNewline])
        }

        return working.split(separator: 0x0A).compactMap { line in
            JSONValue.object(from: Data(line))
        }
    }
}
