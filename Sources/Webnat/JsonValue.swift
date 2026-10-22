import Foundation

/// 将业务层的 Swift 值转换为 JSON 值。
/// nil 表示顶层缺失 / 对象键缺失；数组中的 nil 转为 NSNull；NSNull 表示显式 JSON null。
/// 仅接受 String、Bool、有限数字、字符串键字典和数组；不调用 toJSON / toString。
func toJsonValue(_ value: Any?) throws -> Any? {
    guard let value else { return nil }
    if value is NSNull { return NSNull() }
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional { return try toJsonValue(mirror.children.first?.value) }
    if type(of: value) is NSDictionary.Type || type(of: value) is NSArray.Type {
        throw NSError.serializationFailed("Foundation containers are not business JSON values")
    }
    if let string = value as? String { return string }
    if let number = value as? NSNumber {
        guard number.doubleValue.isFinite else { throw NSError.serializationFailed("Non-finite number") }
        return number
    }
    if let dictionary = value as? [String: Any?] {
        var result: [String: Any] = [:]
        for (key, child) in dictionary {
            if let encoded = try toJsonValue(child) { result[key] = encoded }
        }
        return result
    }
    if let array = value as? [Any?] {
        return try array.map { try toJsonValue($0) ?? NSNull() }
    }
    throw NSError.serializationFailed("Unsupported JSON value type: \(type(of: value))")
}

/// 将 Foundation JSON 值转为业务层 Swift 值。缺失为 nil，显式 JSON null 保持为 NSNull。
/// 字典与数组递归复制；数组空位保留为 NSNull，不改变位置。
func fromJsonValue(_ value: Any?) throws -> Sendable? {
    var ancestors = Set<ObjectIdentifier>()
    func convert(_ value: Any?) throws -> Sendable? {
        guard let value else { return nil }
        if value is NSNull { return NSNull() }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional { return try convert(mirror.children.first?.value) }
        if let string = value as? String { return string }
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
            return try (0..<array.count).map { try convert(array.object(at: $0)) ?? NSNull() }
        }
        if let dictionary = value as? [String: Any?] {
            var result: [String: Sendable?] = [:]
            for (key, child) in dictionary {
                if let decoded = try convert(child) { result[key] = .some(decoded) }
            }
            return result
        }
        if let array = value as? [Any?] { return try array.map { try convert($0) ?? NSNull() } }
        throw NSError.deserializationFailed("Unsupported JSON value type: \(type(of: value))")
    }
    return try convert(value)
}
