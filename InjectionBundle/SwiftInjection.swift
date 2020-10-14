//
//  SwiftInjection.swift
//  InjectionBundle
//
//  Created by John Holdsworth on 05/11/2017.
//  Copyright © 2017 John Holdsworth. All rights reserved.
//
//  $Id: //depot/ResidentEval/InjectionBundle/SwiftInjection.swift#84 $
//
//  Cut-down version of code injection in Swift. Uses code
//  from SwiftEval.swift to recompile and reload class.
//

#if arch(x86_64) || arch(i386) || arch(arm64) // simulator/macOS only
import Foundation
import SwiftTrace

/** pointer to a function implementing a Swift method */
public typealias SIMP = SwiftTrace.SIMP
public typealias ClassMetadataSwift = SwiftTrace.TargetClassMetadata

#if swift(>=3.0)
public func _stdlib_demangleName(_ mangledName: String) -> String {
    return mangledName.withCString {
        SwiftTrace.demangle(symbol: $0) ?? mangledName }
}
#endif

private let debugSweep = getenv("DEBUG_SWEEP") != nil

@objc public protocol SwiftInjected {
    @objc optional func injected()
}

#if os(iOS) || os(tvOS)
import UIKit

extension UIViewController {

    /// inject a UIView controller and redraw
    public func injectVC() {
        inject()
        for subview in self.view.subviews {
            subview.removeFromSuperview()
        }
        if let sublayers = self.view.layer.sublayers {
            for sublayer in sublayers {
                sublayer.removeFromSuperlayer()
            }
        }
        viewDidLoad()
    }
}
#else
import Cocoa
#endif

extension NSObject {

    public func inject() {
        if let oldClass: AnyClass = object_getClass(self) {
            SwiftInjection.inject(oldClass: oldClass, classNameOrFile: "\(oldClass)")
        }
    }

    @objc
    public class func inject(file: String) {
        SwiftInjection.inject(oldClass: nil, classNameOrFile: file)
    }
}

@objc
public class SwiftInjection: NSObject {

    static let testQueue = DispatchQueue(label: "INTestQueue")

    @objc
    public class func inject(oldClass: AnyClass?, classNameOrFile: String) {
        do {
            let tmpfile = try SwiftEval.instance.rebuildClass(oldClass: oldClass,
                                    classNameOrFile: classNameOrFile, extra: nil)
            try inject(tmpfile: tmpfile)
        }
        catch {
        }
    }

    @objc
    public class func replayInjections() -> Int {
        var injectionNumber = 0
        do {
            func mtime(_ path: String) -> time_t {
                return SwiftEval.instance.mtime(URL(fileURLWithPath: path))
            }
            let execBuild = mtime(Bundle.main.executablePath!)

            while true {
                let tmpfile = "/tmp/eval\(injectionNumber+1)"
                if mtime("\(tmpfile).dylib") < execBuild {
                    break
                }
                try inject(tmpfile: tmpfile)
                injectionNumber += 1
            }
        }
        catch {
        }
        return injectionNumber
    }

    @objc
    public class func inject(tmpfile: String) throws {
        let newClasses = try SwiftEval.instance.loadAndInject(tmpfile: tmpfile)
        let oldClasses = //oldClass != nil ? [oldClass!] :
            newClasses.map { objc_getClass(class_getName($0)) as! AnyClass }
        var testClasses = [AnyClass]()
        for i in 0..<oldClasses.count {
            let oldClass: AnyClass = oldClasses[i], newClass: AnyClass = newClasses[i]

            // old-school swizzle Objective-C class & instance methods
            injection(swizzle: object_getClass(newClass), onto: object_getClass(oldClass))
            injection(swizzle: newClass, onto: oldClass)

            // overwrite Swift vtable of existing class with implementations from new class
            let existingClass = unsafeBitCast(oldClass, to:
                UnsafeMutablePointer<SwiftTrace.TargetClassMetadata>.self)
            let classMetadata = unsafeBitCast(newClass, to:
                UnsafeMutablePointer<SwiftTrace.TargetClassMetadata>.self)

            // Is this a Swift class?
            // Reference: https://github.com/apple/swift/blob/master/include/swift/ABI/Metadata.h#L1195
            let oldSwiftCondition = classMetadata.pointee.Data & 0x1 == 1
            let newSwiftCondition = classMetadata.pointee.Data & 0x3 != 0
            let isSwiftClass = newSwiftCondition || oldSwiftCondition
            if isSwiftClass {
                // Old mechanism for Swift equivalent of "Swizzling".
                if classMetadata.pointee.ClassSize != existingClass.pointee.ClassSize {
                    print("💉 ⚠️ Adding or removing methods on Swift classes is not supported. Your application will likely crash. ⚠️")
                }

                #if false // replaced by "interpose" code below
                func byteAddr<T>(_ location: UnsafeMutablePointer<T>) -> UnsafeMutablePointer<UInt8> {
                    return location.withMemoryRebound(to: UInt8.self, capacity: 1) { $0 }
                }

                let vtableOffset = byteAddr(&existingClass.pointee.IVarDestroyer) - byteAddr(existingClass)

                #if false
                // original injection implementaion for Swift.
                let vtableLength = Int(existingClass.pointee.ClassSize -
                    existingClass.pointee.ClassAddressPoint) - vtableOffset

                memcpy(byteAddr(existingClass) + vtableOffset,
                       byteAddr(classMetadata) + vtableOffset, vtableLength)
                #else
                // untried version only copying function pointers.
                let newTable = (byteAddr(classMetadata) + vtableOffset)
                    .withMemoryRebound(to: SwiftTrace.SIMP.self, capacity: 1) { $0 }

                SwiftTrace.iterateMethods(ofClass: oldClass) {
                    (name, slotIndex, vtableSlot, stop) in
                    vtableSlot.pointee = newTable[slotIndex]
                }
                #endif
                #endif
            }

            print("💉 Injected '\(oldClass)'")

            if let XCTestCase = objc_getClass("XCTestCase") as? AnyClass,
                newClass.isSubclass(of: XCTestCase) {
                testClasses.append(newClass)
//                if ( [newClass isSubclassOfClass:objc_getClass("QuickSpec")] )
//                [[objc_getClass("_TtC5Quick5World") sharedWorld]
//                setCurrentExampleMetadata:nil];
            }
        }

        #if true
        // new mechanism for injection of Swift functions,
        // using "interpose" API from dynamic loader along
        // with -Xlinker -interposable other linker flags.

        let main = dlopen(nil, RTLD_NOW)
        var interposes = Array<dyld_interpose_tuple>()

        // Find all definitions of Swift functions and ...
        // SwiftUI body properties defined in the new dylib.
        for suffix in SwiftTrace.swiftFunctionSuffixes {
            findSwiftSymbols("\(tmpfile).dylib", suffix) {
                (loadedFunc, symbol, _, _) in
                guard let existing = dlsym(main, symbol) else { return }
                // has this symbol already been interposed?
                let current = SwiftTrace.interposed[existing] ?? existing
                let tuple = dyld_interpose_tuple(
                    replacement: loadedFunc, replacee: current)
                interposes.append(tuple)
                // record functions that have beeen interposed
                SwiftTrace.interposed[existing] = loadedFunc
                SwiftTrace.interposed[current] = loadedFunc
//                print("💉 Replacing \(demangle(symbol))")
            }
        }

        // Using array of new interpose structs
        interposes.withUnsafeBufferPointer {
            interps in

            var mostRecentlyLoaded = true
            // Apply interposes to all images in the app bundle
            // as well as the most recently loaded "new" dylib.
            appBundleImages { image, header in
                if mostRecentlyLoaded {
                    // Need to apply all previous interposes
                    // to the newly loaded dylib as well.
                    var previous = Array<dyld_interpose_tuple>()
                    for (replacee, replacement) in SwiftTrace.interposed {
                        previous.append(dyld_interpose_tuple(
                                replacement: replacement, replacee: replacee))
                    }
                    previous.withUnsafeBufferPointer {
                        interps in
                        dyld_dynamic_interpose(header,
                                           interps.baseAddress!, interps.count)
                    }
                    mostRecentlyLoaded = false
                }
                // patch out symbols defined by new dylib.
                dyld_dynamic_interpose(header,
                                       interps.baseAddress!, interps.count)
//                print("Patched \(String(cString: image))")
            }
        }
        #endif

        // Thanks https://github.com/johnno1962/injectionforxcode/pull/234
        if !testClasses.isEmpty {
            testQueue.async {
                testQueue.suspend()
                let timer = Timer(timeInterval: 0, repeats:false, block: { _ in
                    for newClass in testClasses {
                        NSObject.runXCTestCase(newClass)
                    }
                    testQueue.resume()
                })
                RunLoop.main.add(timer, forMode: RunLoop.Mode.common)
            }
        } else {
            var injectedClasses = [AnyClass]()
            let injectedSEL = #selector(SwiftInjected.injected)
            typealias ClassIMP = @convention(c) (AnyClass, Selector) -> ()
            for cls in oldClasses {
                if let classMethod = class_getClassMethod(cls, injectedSEL) {
                    let classIMP = method_getImplementation(classMethod)
                    unsafeBitCast(classIMP, to: ClassIMP.self)(cls, injectedSEL)
                }
                if class_getInstanceMethod(cls, injectedSEL) != nil {
                    injectedClasses.append(cls)
                    print("""
                        💉 As class \(cls) has an @objc injected() method, \
                        InjectionIII will perform a "sweep" of all live \
                        instances to determine which objects to message. \
                        If this fails, subscribe to the notification \
                        "INJECTION_BUNDLE_NOTIFICATION" instead.
                        """)
                    let kvoName = "NSKVONotifying_" + NSStringFromClass(cls)
                    if let kvoCls = NSClassFromString(kvoName) {
                        injectedClasses.append(kvoCls)
                    }
                }
            }

            // implement -injected() method using sweep of objects in application
            if !injectedClasses.isEmpty {
                #if os(iOS) || os(tvOS)
                let app = UIApplication.shared
                #else
                let app = NSApplication.shared
                #endif
                let seeds: [Any] =  [app.delegate as Any] + app.windows
                SwiftSweeper(instanceTask: {
                    (instance: AnyObject) in
                    if injectedClasses.contains(where: { $0 == object_getClass(instance) }) {
                        let proto = unsafeBitCast(instance, to: SwiftInjected.self)
                        if SwiftEval.sharedInstance().vaccineEnabled {
                            performVaccineInjection(instance)
                            proto.injected?()
                            return
                        }

                        proto.injected?()

                        #if os(iOS) || os(tvOS)
                        if let vc = instance as? UIViewController {
                            flash(vc: vc)
                        }
                        #endif
                    }
                }).sweepValue(seeds)
            }

            let notification = Notification.Name("INJECTION_BUNDLE_NOTIFICATION")
            NotificationCenter.default.post(name: notification, object: oldClasses)
        }
    }

    @objc(vaccine:)
    public class func performVaccineInjection(_ object: AnyObject) {
        let vaccine = Vaccine()
        vaccine.performInjection(on: object)
    }

    #if os(iOS) || os(tvOS)
    @objc(flash:)
    public class func flash(vc: UIViewController) {
        DispatchQueue.main.async {
            let v = UIView(frame: vc.view.frame)
            v.backgroundColor = .white
            v.alpha = 0.3
            vc.view.addSubview(v)
            UIView.animate(withDuration: 0.2,
                           delay: 0.0,
                           options: UIView.AnimationOptions.curveEaseIn,
                           animations: {
                            v.alpha = 0.0
            }, completion: { _ in v.removeFromSuperview() })
        }
    }
    #endif

    static func injection(swizzle newClass: AnyClass?, onto oldClass: AnyClass?) {
        var methodCount: UInt32 = 0
        if let methods = class_copyMethodList(newClass, &methodCount) {
            for i in 0 ..< Int(methodCount) {
                class_replaceMethod(oldClass, method_getName(methods[i]),
                                    method_getImplementation(methods[i]),
                                    method_getTypeEncoding(methods[i]))
            }
            free(methods)
        }
    }

    @objc class func dumpStats() {
        print("""

            Sorted elapsed time/invocations by method
            =========================================
            """)
        let invocationCounts =  SwiftTrace.invocationCounts()
        for (method, elapsed) in SwiftTrace.sortedElapsedTimes(onlyFirst: 1000) {
          print("\(String(format: "%.1f", elapsed*1000.0))ms/\(invocationCounts[method] ?? -1)\t\(method)")
        }
    }
}

class SwiftSweeper {

    static var current: SwiftSweeper?

    let instanceTask: (AnyObject) -> Void
    var seen = [UnsafeRawPointer: Bool]()

    init(instanceTask: @escaping (AnyObject) -> Void) {
        self.instanceTask = instanceTask
        SwiftSweeper.current = self
    }

    func sweepValue(_ value: Any) {
        /// Skip values that cannot be cast into `AnyObject` because they end up being `nil`
        /// Fixes a potential crash that the value is not accessible during injection.
        guard value as? AnyObject != nil else { return }

        let mirror = Mirror(reflecting: value)
        if var style = mirror.displayStyle {
            if _typeName(mirror.subjectType).hasPrefix("Swift.ImplicitlyUnwrappedOptional<") {
                style = .optional
            }
            switch style {
            case .set, .collection:
                for (_, child) in mirror.children {
                    sweepValue(child)
                }
                return
            case .dictionary:
                for (_, child) in mirror.children {
                    for (_, element) in Mirror(reflecting: child).children {
                        sweepValue(element)
                    }
                }
                return
            case .class:
                sweepInstance(value as AnyObject)
                return
            case .optional, .enum:
                if let evals = mirror.children.first?.value {
                    sweepValue(evals)
                }
            case .tuple, .struct:
                sweepMembers(value)
            @unknown default:
                break
            }
        }
    }

    func sweepInstance(_ instance: AnyObject) {
        let reference = unsafeBitCast(instance, to: UnsafeRawPointer.self)
        if seen[reference] == nil {
            seen[reference] = true
            if debugSweep {
                print("Sweeping instance \(reference) of class \(type(of: instance))")
            }

            instanceTask(instance)

            sweepMembers(instance)
            instance.legacySwiftSweep?()
        }
    }

    func sweepMembers(_ instance: Any) {
        var mirror: Mirror? = Mirror(reflecting: instance)
        while mirror != nil {
            for (_, value) in mirror!.children {
                sweepValue(value)
            }
            mirror = mirror!.superclassMirror
        }
    }
}

extension NSObject {
    @objc func legacySwiftSweep() {
        var icnt: UInt32 = 0, cls: AnyClass? = object_getClass(self)!
        let object = "@".utf16.first!
        while cls != nil && cls != NSObject.self && cls != NSURL.self {
            let className = NSStringFromClass(cls!)
            if className.hasPrefix("_") {
                return
            }
            #if os(OSX)
            if className.starts(with: "NS") && cls != NSWindow.self {
                return
            }
            #endif
            if let ivars = class_copyIvarList(cls, &icnt) {
                for i in 0 ..< Int(icnt) {
                    if let type = ivar_getTypeEncoding(ivars[i]), type[0] == object {
                        (unsafeBitCast(self, to: UnsafePointer<Int8>.self) + ivar_getOffset(ivars[i]))
                            .withMemoryRebound(to: AnyObject?.self, capacity: 1) {
//                                print("\(self) \(String(cString: ivar_getName(ivars[i])!))")
                                if let obj = $0.pointee {
                                    SwiftSweeper.current?.sweepInstance(obj)
                                }
                        }
                    }
                }
                free(ivars)
            }
            cls = class_getSuperclass(cls)
        }
    }
}

extension NSSet {
    @objc override func legacySwiftSweep() {
        self.forEach { SwiftSweeper.current?.sweepInstance($0 as AnyObject) }
    }
}

extension NSArray {
    @objc override func legacySwiftSweep() {
        self.forEach { SwiftSweeper.current?.sweepInstance($0 as AnyObject) }
    }
}

extension NSDictionary {
    @objc override func legacySwiftSweep() {
        self.allValues.forEach { SwiftSweeper.current?.sweepInstance($0 as AnyObject) }
    }
}
#endif
