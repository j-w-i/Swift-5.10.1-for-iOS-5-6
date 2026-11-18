//===--- LegacyDispatchBridging.h - dispatch_*_t <-> Dispatch classes -----===//
//
// Legacy iOS toolchain. The legacy Dispatch overlay (swift-corelibs-libdispatch's)
// wraps libdispatch's handles in Swift classes on every slice, so the stock
// importing of dispatch_queue_t as DispatchQueue (by naming the Objective-C class
// OS_dispatch_queue DispatchQueue) does not apply: the iOS 5 slice has no
// dispatch classes at all, and on the iOS 7 slices the overlay's DispatchQueue is
// not OS_dispatch_queue. Instead, with -enable-legacy-ios5-runtime:
//
//  * ClangImporter imports the SDK's dispatch_{queue,group,semaphore,source,io}_t
//    in bridgeable positions (C and Objective-C parameters, results, properties,
//    block parameters) as the overlay classes DispatchQueue, DispatchGroup, ...
//    The libdispatch C API itself keeps its raw types (the overlay wraps it).
//  * SIL type lowering maps such a class back to the raw handle type when the
//    original Clang type is the dispatch typedef. The raw type is the result
//    type of the overlay's _convert<Class>ToRaw function, so it is whatever the
//    slice's headers make it (OpaquePointer on armv7 at iOS 5, OS_dispatch_queue
//    and friends on armv7s/arm64).
//  * SILGen converts with the overlay's _convert<Class>ToRaw (borrowed handle,
//    +0 on iOS 5) and _convertRawTo<Class> (retains the handle it wraps).
//
//===----------------------------------------------------------------------===//

#ifndef SWIFT_CLANGIMPORTER_LEGACYDISPATCHBRIDGING_H
#define SWIFT_CLANGIMPORTER_LEGACYDISPATCHBRIDGING_H

#include "swift/AST/ASTContext.h"
#include "swift/AST/Decl.h"
#include "swift/AST/Module.h"
#include "swift/AST/ParameterList.h"
#include "swift/AST/Types.h"
#include "clang/AST/Decl.h"
#include "clang/AST/Type.h"
#include "clang/Basic/Module.h"
#include "llvm/ADT/StringSwitch.h"

namespace swift {

/// The Dispatch overlay class a libdispatch handle typedef imports as, or "".
inline StringRef legacyDispatchClassNameForTypedef(StringRef typedefName) {
  return llvm::StringSwitch<StringRef>(typedefName)
      .Case("dispatch_queue_t", "DispatchQueue")
      .Case("dispatch_group_t", "DispatchGroup")
      .Case("dispatch_semaphore_t", "DispatchSemaphore")
      .Case("dispatch_source_t", "DispatchSource")
      .Case("dispatch_io_t", "DispatchIO")
      .Default("");
}

/// The libdispatch handle typedef a Dispatch overlay class stands for, or "".
inline StringRef legacyDispatchTypedefForClassName(StringRef className) {
  return llvm::StringSwitch<StringRef>(className)
      .Case("DispatchQueue", "dispatch_queue_t")
      .Case("DispatchGroup", "dispatch_group_t")
      .Case("DispatchSemaphore", "dispatch_semaphore_t")
      .Case("DispatchSource", "dispatch_source_t")
      .Case("DispatchIO", "dispatch_io_t")
      .Default("");
}

/// If \p type is spelled with one of the SDK Dispatch module's handle typedefs
/// (directly, through nullability or other sugar, or through a user typedef of
/// it), the overlay class name it bridges to; otherwise "".
inline StringRef legacyDispatchClassNameForClangType(const clang::Type *type) {
  while (type) {
    auto typedefType = type->getAs<clang::TypedefType>();
    if (!typedefType)
      return "";
    auto decl = typedefType->getDecl();
    auto name = legacyDispatchClassNameForTypedef(decl->getName());
    if (!name.empty()) {
      auto module = decl->getOwningModule();
      return module && module->getTopLevelModule()->Name == "Dispatch"
                 ? name : "";
    }
    type = decl->getUnderlyingType().getTypePtrOrNull();
  }
  return "";
}

/// The overlay class declaration \p type names, when it is one of the bridged
/// Dispatch classes and the legacy runtime is enabled.
inline ClassDecl *legacyDispatchBridgedClass(ASTContext &ctx, Type type) {
  if (!ctx.LangOpts.LegacyIOS5Backports || !type)
    return nullptr;
  auto cls = type->getClassOrBoundGenericClass();
  // The overlay's Swift class, not the SDK's Objective-C class of the same
  // name (OS_dispatch_group is DispatchGroup to Swift on iOS 7 slices).
  if (!cls || cls->hasClangNode() ||
      cls->getParentModule()->getName().str() != "Dispatch")
    return nullptr;
  if (legacyDispatchTypedefForClassName(cls->getName().str()).empty())
    return nullptr;
  return cls;
}

/// The legacy Dispatch overlay's own class named \p name, if that module is
/// loaded (it is whenever the SDK's Dispatch module is imported).
inline ClassDecl *legacyDispatchOverlayClass(ASTContext &ctx, StringRef name) {
  auto module = ctx.getLoadedModule(ctx.getIdentifier("Dispatch"));
  if (!module)
    return nullptr;
  SmallVector<ValueDecl *, 2> results;
  module->lookupValue(ctx.getIdentifier(name), NLKind::QualifiedLookup,
                      results);
  for (auto *result : results)
    if (auto *cls = dyn_cast<ClassDecl>(result))
      if (legacyDispatchBridgedClass(ctx, cls->getDeclaredInterfaceType()))
        return cls;
  return nullptr;
}

/// The overlay's conversion function for \p cls: _convert<Class>ToRaw when
/// \p toRaw, else _convertRawTo<Class>. Null if the overlay lacks it.
inline FuncDecl *legacyDispatchBridgingFunction(ClassDecl *cls, bool toRaw) {
  auto &ctx = cls->getASTContext();
  std::string name = toRaw
      ? ("_convert" + cls->getName().str() + "ToRaw").str()
      : ("_convertRawTo" + cls->getName().str()).str();
  SmallVector<ValueDecl *, 2> results;
  cls->getParentModule()->lookupValue(ctx.getIdentifier(name),
                                      NLKind::UnqualifiedLookup, results);
  for (auto *result : results)
    if (auto *fn = dyn_cast<FuncDecl>(result))
      if (fn->getParameters()->size() == 1 && !fn->isGeneric())
        return fn;
  return nullptr;
}

/// The raw handle type that \p type lowers to at a C or Objective-C boundary,
/// or null when no bridging applies. \p clangType is the boundary's original
/// Clang type when there is one (imported declarations, overrides of them);
/// Swift @objc declarations have none and always use the handle, which is how
/// they are declared in the generated header.
inline Type legacyDispatchLoweredRawType(ASTContext &ctx, Type type,
                                         const clang::Type *clangType) {
  auto cls = legacyDispatchBridgedClass(ctx, type);
  if (!cls || (clangType && legacyDispatchClassNameForClangType(clangType) !=
                                cls->getName().str()))
    return Type();
  auto fn = legacyDispatchBridgingFunction(cls, /*toRaw=*/true);
  return fn ? fn->getResultInterfaceType() : Type();
}

} // end namespace swift

#endif
