import Foundation
import IMessageCore

protocol UserDefaultsProtocol {
    // func object(forKey key: String) -> Any?
    // func url(forKey key: String) -> URL?
    // func array(forKey key: String) -> [Any]?
    func dictionary(forKey key: String) -> [String: Any]?
    func string(forKey key: String) -> String?
    // func stringArray(forKey key: String) -> [String]?
    // func data(forKey key: String) -> Data?
    func bool(forKey key: String) -> Bool
    // func integer(forKey key: String) -> Int
    // func float(forKey key: String) -> Float
    // func double(forKey key: String) -> Double

    // func set(_ value: Any?, forKey key: String)
    // func set(_ value: Float, forKey key: String)
    // func set(_ value: Double, forKey key: String)
    func set(_ value: Int, forKey key: String)
    func set(_ value: Bool, forKey key: String)
    // func set(_ url: URL?, forKey key: String)
}

extension UserDefaults: UserDefaultsProtocol {}
