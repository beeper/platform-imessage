import Foundation
import CoreGraphics
import CWindowControl

extension ProcessSerialNumber {
    public init(pid: pid_t) throws {
        var psn = ProcessSerialNumber()
        let err = TXTGetProcessForPID(pid, &psn)
        if err != kOSReturnSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }
        self = psn
    }
}

public struct GraphicsConnection {
    public struct Error: Swift.Error, CustomStringConvertible {
        public let code: CGError
        public let file: StaticString
        public let line: UInt

        public init(_ code: CGError, file: StaticString = #fileID, line: UInt = #line) {
            self.code = code
            self.file = file
            self.line = line
        }

        public var description: String {
            switch code {
            case .success: return "success"
            case .failure: return "failure"
            case .illegalArgument: return "illegalArgument"
            case .invalidConnection: return "invalidConnection"
            case .invalidContext: return "invalidContext"
            case .cannotComplete: return "cannotComplete"
            case .notImplemented: return "notImplemented"
            case .rangeCheck: return "rangeCheck"
            case .typeCheck: return "typeCheck"
            case .invalidOperation: return "invalidOperation"
            case .noneAvailable: return "noneAvailable"
            @unknown default: return "unknown"
            }
        }
    }

    public let raw: CGSConnectionID

    public static let main = Self(raw: CGSMainConnectionID())

    static func check(_ code: CGError, file: StaticString = #fileID, line: UInt = #line) throws {
        guard code != .success else { return }
        throw Error(code, file: file, line: line)
    }

    public func connection(for pid: pid_t) throws -> GraphicsConnection {
        var psn = try ProcessSerialNumber(pid: pid)
        var cid: CGSConnectionID = 0
        try Self.check(CGSGetConnectionIDForPSN(raw, &psn, &cid))
        return GraphicsConnection(raw: cid)
    }
}
