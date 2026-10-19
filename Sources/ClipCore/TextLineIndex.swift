import Foundation

public struct TextLineIndex: Sendable {
    public let starts: [Int]
    public let utf16Count: Int
    public var showsNumbers: Bool { starts.count >= 8 || utf16Count >= 800 }

    public init(_ text: String) {
        let units = Array(text.utf16)
        utf16Count = units.count
        var result = [0], index = 0
        while index < units.count {
            let unit = units[index]
            if unit == 13, index + 1 < units.count, units[index + 1] == 10 { index += 1 }
            if [UInt16(10), 13, 0x85, 0x2028, 0x2029].contains(unit) { result.append(index + 1) }
            index += 1
        }
        starts = result
    }
    public func line(atUTF16 offset: Int) -> Int {
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1)
    }
}
