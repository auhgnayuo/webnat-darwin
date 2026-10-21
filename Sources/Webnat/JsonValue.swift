import Foundation

/// 将业务层的 JSON 兼容 Swift 值转为 Foundation JSON 值。
/// 支持 nil、String、Bool、有限数字、字符串键字典和数组（值 / 元素可为 Optional）。
/// NSNull 仅用于内部编码；业务输入不接受 NSNull、Foundation 容器、Set、Date 或自定义对象。
/// 非法值明确抛出 SERIALIZATION_FAILED，不做字符串兜底，也不丢弃元素。
func toJsonValue(_ value: Any?) throws -> Any {
    guard let value else { return NSNull() }
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional {
        return try toJsonValue(mirror.children.first?.value)
    }
    if value is NSNull || type(of: value) is NSDictionary.Type || type(of: value) is NSArray.Type {
        throw NSError.serializationFailed("Foundation null / containers are not business JSON values")
    }
    if let string = value as? String { return string }
    if let number = value as? NSNumber {
        guard number.doubleValue.isFinite else { throw NSError.serializationFailed("Non-finite number") }
        return number
    }
    if let dictionary = value as? [String: Any?] {
        return try dictionary.mapValues { try toJsonValue($0) }
    }
    if let array = value as? [Any?] {
        return try array.map { try toJsonValue($0) }
    }
    throw NSError.serializationFailed("Unsupported JSON value type: \(type(of: value))")
}

/// 将 Foundation JSON 值转为业务层 Swift 值。
/// JSON null / 缺失值转为 nil；字典和数组分别为 [String: Sendable?] 和 [Sendable?]。
/// Optional 字典值使用 .some(nil) 保留空值字段，数组保留空值位置。
/// 未识别值、非字符串键、非有限数字和循环引用明确失败，不静默跳过。
func fromJsonValue(_ value: Any?) throws -> Sendable? {
    var ancestors = Set<ObjectIdentifier>()
    func convert(_ value: Any?) throws -> Sendable? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional { return try convert(mirror.children.first?.value) }
        if let string = value as? String { return string }
        // 数字 0 / 1 不能用 as? Bool 判断；保留现有整数精度修复。
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            guard number.doubleValue.isFinite else { throw NSError.deserializationFailed("Non-finite number") }
            switch String(cString: number.objCType) {
            case "f", "d": return number.doubleValue
            case "C", "S", "I", "L", "Q":
                if let value = Int(exactly: number.uint64Value) { return value }
                return number.uint64Value
            default:
                if let value = Int(exactly: number.int64Value) { return value }
                return number.int64Value
            }
        }
        // 在桥接为 Swift 集合前检查 Foundation 容器，避免循环引用导致递归桥接崩溃。
        if type(of: value) is NSDictionary.Type, let dictionary = value as? NSDictionary {
            let id = ObjectIdentifier(dictionary)
            guard ancestors.insert(id).inserted else { throw NSError.deserializationFailed("Circular dictionary") }
            defer { ancestors.remove(id) }
            var result: [String: Sendable?] = [:]
            for (key, child) in dictionary {
                guard let key = key as? String else { throw NSError.deserializationFailed("Object keys must be strings") }
                result[key] = .some(try convert(child))
            }
            return result
        }
        if type(of: value) is NSArray.Type, let array = value as? NSArray {
            let id = ObjectIdentifier(array)
            guard ancestors.insert(id).inserted else { throw NSError.deserializationFailed("Circular array") }
            defer { ancestors.remove(id) }
            return try (0..<array.count).map { try convert(array.object(at: $0)) }
        }
        if let dictionary = value as? [String: Any?] {
            return try dictionary.mapValues { try convert($0) }
        }
        if let array = value as? [Any?] { return try array.map { try convert($0) } }
        throw NSError.deserializationFailed("Unsupported JSON value type: \(type(of: value))")
    }
    return try convert(value)
}
