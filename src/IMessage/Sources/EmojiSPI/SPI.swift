import IMessageCore
import EmojiSPIObjc
import Darwin
import Foundation

// using dlopen to avoid linking directly to private frameworks, which would cause us to immediately crash on launch if the symbols changed

public enum SPIError: Error, Hashable {
    case castFailure
    case noClass(name: String)
    // method was missing or returned nil (are we able to differentiate?)
    case nilResponse(method: String)
    case noInstanceMethod
    case noTypeEncoding
    case unexpectedTypeEncoding(expected: String, actual: String)
}

public final class CPKDefaultDataSource {
    public static func localizedName(for character: String) throws(SPIError) -> String? {
        Bundle(path: "/System/Library/PrivateFrameworks/CharacterPicker.framework")?.load()

        // castedClass = NSClassFromString(@"CPKDefaultDataSource");
        let className = "CPKDefaultDataSource"
        guard let `class` = NSClassFromString("CPKDefaultDataSource") else {
            throw .noClass(name: className)
        }
        guard let castedClass = `class` as? NSObject.Type else {
            throw .castFailure
        }

        // name = [castedClass localizedCharacterName:character];
        guard let unmanagedString = castedClass.perform(Selector(("localizedCharacterName:")), with: character as NSString) else {
            return nil
        }

        guard let string = unmanagedString.takeUnretainedValue() as? String else {
            throw .castFailure
        }
        return string
    }
}

public final class EMFEmojiToken {
    private let underlying: NSObject

    public convenience init(character: Character, locale: Locale = .current) throws(SPIError) {
        Bundle(path: "/System/Library/PrivateFrameworks/EmojiFoundation.framework")?.load()

        let className = "EMFEmojiToken"
        guard let `class` = NSClassFromString(className) else {
            throw .noClass(name: className)
        }
        try self.init(character: character, locale: locale, objectClass: `class`)
    }

    init(character: Character, locale: Locale, objectClass: AnyClass) throws(SPIError) {
        guard let objectClass = objectClass as? NSObject.Type else {
            throw .castFailure
        }
        let initMethodName = "initWithString:localeIdentifier:"
        guard objectClass.instancesRespond(to: Selector(initMethodName)) else {
            throw .noInstanceMethod
        }
        guard let token = EmojiSPITokenCreate(objectClass, String(character), locale.identifier) else {
            throw .nilResponse(method: initMethodName)
        }

        underlying = token
    }

    public var supportsSkinToneVariants: Bool {
        get throws(SPIError) {
            // can't use perform because it doesn't return an object
            let supportsSkinToneVariantsSelector = Selector(("supportsSkinToneVariants"))
            guard let method = class_getInstanceMethod(type(of: underlying), supportsSkinToneVariantsSelector) else {
                throw .noInstanceMethod
            }

            // verify that the method has the type we expect
            // FIXME: use `method_getReturnType`, `method_getArgumentType` instead?
            guard let encoding = method_getTypeEncoding(method).map(String.init(cString:)) else {
                throw .noTypeEncoding
            }
            // types are followed by their (absolute) offsets
            // in method type encodings, the return type comes before params
            //
            // "B16" -> bool is returned
            // "@0"  -> first IMP param is ObjC object
            // ":8"  -> second IMP param is ObjC selector
            let expectedTypeEncoding = "B16@0:8"
            guard encoding == expectedTypeEncoding else {
                throw .unexpectedTypeEncoding(expected: expectedTypeEncoding, actual: encoding)
            }

            typealias GetterIMP = @convention(c) (Any, Selector) -> Bool
            return unsafeBitCast(method_getImplementation(method), to: GetterIMP.self)(underlying, supportsSkinToneVariantsSelector)
        }
    }
}

public final class EMFEmojiSearchEngine {
    private let underlying: NSObject

    public convenience init(locale: Locale = .current) throws(SPIError) {
        Bundle(path: "/System/Library/PrivateFrameworks/EmojiFoundation.framework")?.load()

        let className = "EMFEmojiSearchEngine"
        guard let `class` = NSClassFromString(className) else {
            throw .noClass(name: className)
        }
        try self.init(locale: locale, objectClass: `class`)
    }

    init(locale: Locale, objectClass: AnyClass) throws(SPIError) {
        guard let objectClass = objectClass as? NSObject.Type else {
            throw .castFailure
        }
        let methodName = "initWithLocale:"
        guard objectClass.instancesRespond(to: Selector(methodName)) else {
            throw .noInstanceMethod
        }
        guard let engine = EmojiSPISearchEngineCreate(objectClass, locale) else {
            throw .nilResponse(method: methodName)
        }

        underlying = engine
    }

    public func query(_ query: String) throws(SPIError) -> [String] {
        let methodName = "performStringQuery:"
        guard let results = underlying.perform(Selector(methodName), with: query) else {
            throw .nilResponse(method: methodName)
        }
        return results.takeUnretainedValue() as? [String] ?? []
    }
}
