//===--- ClangIncludePaths.cpp --------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#include "ClangIncludePaths.h"
#include "swift/AST/ASTContext.h"
#include "swift/AST/DiagnosticEngine.h"
#include "swift/AST/DiagnosticsClangImporter.h"
#include "swift/Basic/Platform.h"
#include "swift/ClangImporter/ClangImporter.h"
#include "clang/Driver/Driver.h"
#include "clang/Driver/ToolChain.h"
#include "clang/Frontend/CompilerInstance.h"
#include "clang/Lex/Lexer.h"
#include "llvm/ADT/StringSwitch.h"
#include "llvm/WindowsDriver/MSVCPaths.h"

using namespace swift;

using Path = SmallString<128>;

/// Highest armv7 iOS deployment major the legacy backport tree serves. The
/// toolchain cannot emit armv7 at iOS 11+, and every backported family is
/// native by iOS 9 (anchors/guides/stack) or 10, so 5..10 is the useful range.
static const unsigned LegacyMaxDeploymentMajor = 10;

static bool isLegacyArmDevice(const llvm::Triple &triple) {
  return triple.isiOS() && !triple.isTvOS() && !triple.isSimulatorEnvironment() &&
         !triple.isMacCatalystEnvironment() && !triple.isOSVersionLT(5) &&
         triple.isOSVersionLT(LegacyMaxDeploymentMajor + 1);
}

unsigned swift::legacyDeploymentMajor(const ASTContext &ctx) {
  return ctx.LangOpts.Target.getiOSVersion().getMajor();
}

/// iOS 5 only: PSTCollectionView stands in for the (iOS 6) UICollectionView.
bool swift::usesLegacyCollectionDeclarations(const ASTContext &ctx) {
  const auto &triple = ctx.LangOpts.ClangTarget
                           ? *ctx.LangOpts.ClangTarget : ctx.LangOpts.Target;
  return ctx.LangOpts.LegacyIOS5ClassMarking && isLegacyArmDevice(triple) &&
         triple.isOSVersionLT(6);
}

/// armv7 iOS 5..10 with the explicit legacy opt-in: UIKit declarations newer
/// than the deployment target are served by the backport tree.
bool swift::usesLegacyUIKitBackportDeclarations(const ASTContext &ctx) {
  const auto &deployment = ctx.LangOpts.Target;
  const auto &target = ctx.LangOpts.ClangTarget
      ? *ctx.LangOpts.ClangTarget : deployment;
  return ctx.LangOpts.LegacyIOS5ClassMarking && isLegacyArmDevice(deployment) &&
      isLegacyArmDevice(target) &&
      (target.getSubArch() == llvm::Triple::ARMSubArch_v7 ||
       target.getSubArch() == llvm::Triple::ARMSubArch_v7s);
}

/// Modify only declaration linkage, never SDK signatures or availability.
/// Raw lexing skips comments/strings and distinguishes definitions from forward
/// declarations and categories. Apply edits backwards to retain token offsets.
static std::string legacyCollectionHeader(StringRef text, bool backportFacades,
                                          bool foundationFacades = false,
                                          unsigned deploymentMajor = 5) {
  // Rewrites apply only below the version at which the SDK's own class is real.
  const bool collections = deploymentMajor < 6;
  struct Edit { size_t offset; std::string text; };
  SmallVector<Edit, 16> edits;
  clang::LangOptions opts;
  opts.ObjC = true;
  clang::Lexer lexer(clang::SourceLocation::getFromRawEncoding(1), opts,
                     text.begin(), text.begin(), text.end());
  SmallVector<clang::Token, 256> tokens;
  clang::Token token;
  do {
    lexer.LexFromRawLexer(token);
    if (!token.is(clang::tok::comment))
      tokens.push_back(token);
  } while (!token.is(clang::tok::eof));
  auto spelling = [](const clang::Token &t) -> StringRef {
    return t.is(clang::tok::raw_identifier) ? t.getRawIdentifier() : StringRef();
  };
  for (size_t i = 0; i + 3 < tokens.size(); ++i) {
    if (tokens[i].is(clang::tok::at)) {
      auto kind = spelling(tokens[i + 1]);
      auto name = spelling(tokens[i + 2]);
      bool interface = kind == "interface";
      bool protocol = kind == "protocol";
      if ((!interface && !protocol) || tokens[i + 3].is(clang::tok::l_paren) ||
          tokens[i + 3].is(clang::tok::semi) || tokens[i + 3].is(clang::tok::comma))
        continue;
      if (foundationFacades) {
        // Preserve SDK declarations and Swift API notes; only bind class
        // references to the source-built missing-native Foundation facades.
        // Delegate protocols deliberately retain Apple's runtime identity.
        StringRef runtime = interface ? llvm::StringSwitch<StringRef>(name)
            .Case("NSURLComponents", "FBPURLComponents")
            .Case("NSURLQueryItem", "FBPURLQueryItem")
            .Case("NSISO8601DateFormatter", "FBPISO8601DateFormatter")
            .Case("NSURLSession", "FBPURLSession")
            .Case("NSURLSessionConfiguration", "FBPURLSessionConfiguration")
            .Case("NSURLSessionTask", "FBPURLSessionTask")
            .Case("NSURLSessionDataTask", "FBPURLSessionDataTask")
            .Case("NSURLSessionUploadTask", "FBPURLSessionUploadTask")
            .Case("NSURLSessionDownloadTask", "FBPURLSessionDownloadTask")
            .Case("NSHashTable", "FBPHashTable")
            .Case("NSPointerFunctions", "FBPPointerFunctions")
            .Default("") : StringRef();
        if (!runtime.empty())
          edits.push_back({tokens[i].getLocation().getRawEncoding() - 1,
              "__attribute__((objc_runtime_name(\"" + runtime.str() + "\"))) "});
        continue;
      }
      bool supported = collections && (interface
          ? (name == "UICollectionView" || name == "UICollectionViewCell" ||
             name == "UICollectionReusableView" || name == "UICollectionViewLayout" ||
             name == "UICollectionViewFlowLayout" ||
             name == "UICollectionViewLayoutAttributes" ||
             name == "UICollectionViewController" || name == "UICollectionViewUpdateItem")
          : (name == "UICollectionViewDataSource" || name == "UICollectionViewDelegate" ||
             name == "UICollectionViewDelegateFlowLayout"));
      if (supported) {
        std::string runtime = "PST" + name.drop_front(2).str();
        edits.push_back({tokens[i].getLocation().getRawEncoding() - 1,
            "__attribute__((objc_runtime_name(\"" + runtime + "\"))) "});
      } else if (backportFacades) {
        // Static facade symbols shipped by UIKitBackports. NSLayoutConstraint
        // deliberately retains its existing runtime registration contract.
        // A class is bound to its backport facade only while the deployment
        // target predates the version that introduced it natively.
        StringRef runtime = llvm::StringSwitch<StringRef>(name)
            .Case("UILayoutGuide", deploymentMajor < 9 ? "UICLayoutGuide" : "")
            .Case("NSLayoutAnchor", deploymentMajor < 9 ? "UICLayoutAnchor" : "")
            .Case("NSLayoutXAxisAnchor", deploymentMajor < 9 ? "UICXAxisAnchor" : "")
            .Case("NSLayoutYAxisAnchor", deploymentMajor < 9 ? "UICYAxisAnchor" : "")
            .Case("NSLayoutDimension", deploymentMajor < 9 ? "UICLayoutDimension" : "")
            .Case("UIRefreshControl", deploymentMajor < 6 ? "UICRefreshControl" : "")
            .Case("UIStackView", deploymentMajor < 9 ? "UICStackView" : "")
            .Default("");
        std::string runtimeName = interface ? runtime.str() : std::string();
        // Verified IBP capability contract: fourteen public interfaces and
        // three protocol identities. Never bind the internal classes that
        // happen to have the Container/Environment protocol names.
        bool compositional = interface
            ? llvm::StringSwitch<bool>(name)
                .Cases("UICollectionViewCompositionalLayout", "UICollectionViewCompositionalLayoutConfiguration", true)
                .Cases("NSCollectionLayoutSection", "NSCollectionLayoutItem", "NSCollectionLayoutGroup", true)
                .Cases("NSCollectionLayoutGroupCustomItem", "NSCollectionLayoutDimension", true)
                .Cases("NSCollectionLayoutSize", "NSCollectionLayoutSpacing", "NSCollectionLayoutEdgeSpacing", true)
                .Cases("NSCollectionLayoutSupplementaryItem", "NSCollectionLayoutBoundarySupplementaryItem", true)
                .Cases("NSCollectionLayoutDecorationItem", "NSCollectionLayoutAnchor", true)
                .Default(false)
            : (name == "NSCollectionLayoutContainer" ||
               name == "NSCollectionLayoutEnvironment" ||
               name == "NSCollectionLayoutVisibleItem");
        if (compositional) runtimeName = "IBP" + name.str();
        if (!runtimeName.empty())
          edits.push_back({tokens[i].getLocation().getRawEncoding() - 1,
              "__attribute__((objc_runtime_name(\"" + runtimeName + "\"))) "});
      }
    }
    auto name = spelling(tokens[i]);
    if (backportFacades && deploymentMajor < 6 && name == "UIViewNoIntrinsicMetric" && i &&
        spelling(tokens[i - 1]) == "CGFloat")
      edits.push_back({tokens[i].getLocation().getRawEncoding() - 1 + name.size(),
          " __asm__(\"_SwiftLegacyUIViewNoIntrinsicMetric\")"});
    // iOS 11 exposes `safeAreaLayoutGuide` with the native guide class, but the
    // legacy configuration surfaces the backport guide instead. Preprocessor
    // guards hide that one declaration so the overlay can provide the same API
    // name and availability with the backport's own guide type.
    if (backportFacades && name == "safeAreaLayoutGuide") {
      size_t attribute = i;
      while (attribute > 0 &&
             !(tokens[attribute].is(clang::tok::at) &&
               spelling(tokens[attribute + 1]) == "property"))
        --attribute;
      size_t semicolon = i;
      while (semicolon < tokens.size() &&
             !tokens[semicolon].is(clang::tok::semi))
        ++semicolon;
      if (attribute < i && semicolon < tokens.size()) {
        edits.push_back({tokens[attribute].getLocation().getRawEncoding() - 1,
                         std::string("#if 0 /* legacy: backport guide */\n")});
        edits.push_back({tokens[semicolon].getLocation().getRawEncoding() - 1 +
                             tokens[semicolon].getLength(),
                         std::string("\n#endif\n")});
      }
    }
    // Genuine UIKit attribute-name constants (iOS 6) with the identical CoreText
    // string values, provided by the SDK runtime on iOS 5.
    if (backportFacades && deploymentMajor < 6 && i && spelling(tokens[i - 1]) == "const" &&
        (name == "NSFontAttributeName" ||
         name == "NSForegroundColorAttributeName" ||
         name == "NSUnderlineStyleAttributeName"))
      edits.push_back({tokens[i].getLocation().getRawEncoding() - 1 + name.size(),
          " __asm__(\"_SwiftLegacy" + name.str() + "\")"});
    if (backportFacades && name == "NSDirectionalEdgeInsetsZero" && i &&
        spelling(tokens[i - 1]) == "NSDirectionalEdgeInsets")
      edits.push_back({tokens[i].getLocation().getRawEncoding() - 1 + name.size(),
          " __asm__(\"_IBPNSDirectionalEdgeInsetsZero\")"});
    if (collections && (name == "UICollectionElementKindSectionHeader" ||
         name == "UICollectionElementKindSectionFooter") && i &&
        spelling(tokens[i - 1]) == "const") {
      edits.push_back({tokens[i].getLocation().getRawEncoding() - 1 + name.size(),
          " __asm__(\"_PST" + name.drop_front(2).str() + "\")"});
    }
  }
  std::string result = text.str();
  llvm::sort(edits, [](const Edit &a, const Edit &b) { return a.offset > b.offset; });
  for (const auto &edit : edits)
    result.insert(edit.offset, edit.text);
  return result;
}

static llvm::Optional<Path> getActualModuleMapPath(
    StringRef name, SearchPathOptions &Opts, const llvm::Triple &triple,
    bool isArchSpecific,
    const llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem> &vfs) {
  StringRef platform = swift::getPlatformNameForTriple(triple);
  StringRef arch = swift::getMajorArchitectureName(triple);

  Path result;

  StringRef SDKPath = Opts.getSDKPath();
  if (!SDKPath.empty()) {
    result.append(SDKPath.begin(), SDKPath.end());
    llvm::sys::path::append(result, "usr", "lib", "swift");
    llvm::sys::path::append(result, platform);
    if (isArchSpecific) {
      llvm::sys::path::append(result, arch);
    }
    llvm::sys::path::append(result, name);

    // Only specify the module map if that file actually exists.  It may not;
    // for example in the case that `swiftc -target x86_64-unknown-linux-gnu
    // -emit-ir` is invoked using a Swift compiler not built for Linux targets.
    if (vfs->exists(result))
      return result;
  }

  if (!Opts.RuntimeResourcePath.empty()) {
    result.clear();
    result.append(Opts.RuntimeResourcePath.begin(),
                  Opts.RuntimeResourcePath.end());
    llvm::sys::path::append(result, platform);
    if (isArchSpecific) {
      llvm::sys::path::append(result, arch);
    }
    llvm::sys::path::append(result, name);

    // Only specify the module map if that file actually exists.  It may not;
    // for example in the case that `swiftc -target x86_64-unknown-linux-gnu
    // -emit-ir` is invoked using a Swift compiler not built for Linux targets.
    if (vfs->exists(result))
      return result;
  }

  return llvm::None;
}

/// Given an include path directory, returns a path to inject the module map to.
/// If a module map already exists, returns `None`.
static llvm::Optional<Path> getInjectedModuleMapPath(
    const Path &dir,
    const llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem> &vfs) {
  Path legacyPath(dir);
  llvm::sys::path::append(legacyPath, "module.map");
  if (vfs->exists(legacyPath))
    return llvm::None;

  Path path(dir);
  llvm::sys::path::append(path, "module.modulemap");
  if (vfs->exists(path))
    return llvm::None;

  return path;
}

/// Finds the glibc.modulemap file relative to the provided resource dir.
///
/// Note that the module map used for Glibc depends on the target we're
/// compiling for, and is not included in the resource directory with the other
/// implicit module maps. It's at {freebsd|linux}/{arch}/glibc.modulemap.
static llvm::Optional<Path> getGlibcModuleMapPath(
    SearchPathOptions &Opts, const llvm::Triple &triple,
    const llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem> &vfs) {
  return getActualModuleMapPath("glibc.modulemap", Opts, triple,
                                /*isArchSpecific*/ true, vfs);
}

static llvm::Optional<Path> getLibStdCxxModuleMapPath(
    SearchPathOptions &opts, const llvm::Triple &triple,
    const llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem> &vfs) {
  return getActualModuleMapPath("libstdcxx.modulemap", opts, triple,
                                /*isArchSpecific*/ false, vfs);
}

llvm::Optional<SmallString<128>>
swift::getCxxShimModuleMapPath(SearchPathOptions &opts,
                               const llvm::Triple &triple) {
  return getActualModuleMapPath("libcxxshim.modulemap", opts, triple,
                                /*isArchSpecific*/ false,
                                llvm::vfs::getRealFileSystem());
}

static llvm::opt::InputArgList
parseClangDriverArgs(const clang::driver::Driver &clangDriver,
                     const ArrayRef<const char *> args) {
  unsigned unused1, unused2;
  return clangDriver.getOpts().ParseArgs(args, unused1, unused2);
}

static clang::driver::Driver
createClangDriver(const ASTContext &ctx,
                  const llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem> &vfs) {
  auto clangDiags = clang::CompilerInstance::createDiagnostics(
      new clang::DiagnosticOptions());
  clang::driver::Driver clangDriver(ctx.ClangImporterOpts.clangPath,
                                    ctx.LangOpts.Target.str(), *clangDiags,
                                    "clang LLVM compiler", vfs);
  return clangDriver;
}

/// Given a list of include paths and a list of file names, finds the first
/// include path that contains files with all the names. This is useful for
/// finding the include path for a specific library among a list of include
/// paths.
///
/// \return a path without dots (`../`, './').
static llvm::Optional<Path> findFirstIncludeDir(
    const llvm::opt::InputArgList &args,
    const ArrayRef<const char *> expectedFileNames,
    const llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem> &vfs) {
  // C++ stdlib paths are added as `-internal-isystem`.
  std::vector<std::string> includeDirs =
      args.getAllArgValues(clang::driver::options::OPT_internal_isystem);
  // C stdlib paths are added as `-internal-externc-isystem`.
  llvm::append_range(includeDirs,
                     args.getAllArgValues(
                         clang::driver::options::OPT_internal_externc_isystem));

  for (const auto &includeDir : includeDirs) {
    Path dir(includeDir);
    bool allExpectedExist = true;
    for (auto expectedFileName : expectedFileNames) {
      Path expectedFile(dir);
      llvm::sys::path::append(expectedFile, expectedFileName);
      if (!vfs->exists(expectedFile)) {
        allExpectedExist = false;
        break;
      }
    }

    if (allExpectedExist) {
      // VFS does not allow mapping paths that contain `../` or `./`.
      llvm::sys::path::remove_dots(dir, /*remove_dot_dot=*/true);
      return dir;
    }
  }
  return llvm::None;
}

static llvm::opt::InputArgList
createClangArgs(const ASTContext &ctx, clang::driver::Driver &clangDriver) {
  // Flags passed to Swift with `-Xcc` might affect include paths.
  std::vector<const char *> clangArgs;
  for (const auto &each : ctx.ClangImporterOpts.ExtraArgs) {
    clangArgs.push_back(each.c_str());
  }
  llvm::opt::InputArgList clangDriverArgs =
      parseClangDriverArgs(clangDriver, clangArgs);
  // If an SDK path was explicitly passed to Swift, make sure to pass it to
  // Clang driver as well. It affects the resulting include paths.
  auto sdkPath = ctx.SearchPathOpts.getSDKPath();
  if (!sdkPath.empty())
    clangDriver.SysRoot = sdkPath.str();
  return clangDriverArgs;
}

static bool shouldInjectGlibcModulemap(const llvm::Triple &triple) {
  return triple.isOSGlibc() || triple.isOSOpenBSD() || triple.isOSFreeBSD() ||
         triple.isAndroid();
}

static SmallVector<std::pair<std::string, std::string>, 2> getGlibcFileMapping(
    ASTContext &ctx,
    const llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem> &vfs) {
  const llvm::Triple &triple = ctx.LangOpts.Target;
  if (!shouldInjectGlibcModulemap(triple))
    return {};

  // Extract the Glibc path from Clang driver.
  auto clangDriver = createClangDriver(ctx, vfs);
  auto clangDriverArgs = createClangArgs(ctx, clangDriver);

  llvm::opt::ArgStringList includeArgStrings;
  const auto &clangToolchain =
      clangDriver.getToolChain(clangDriverArgs, triple);
  clangToolchain.AddClangSystemIncludeArgs(clangDriverArgs, includeArgStrings);
  auto parsedIncludeArgs = parseClangDriverArgs(clangDriver, includeArgStrings);

  // Find the include path that contains Glibc headers. We use three arbitrarily
  // chosen headers to determine if the include path actually contains Glibc.
  // Ideally we would check that all of the headers referenced from the
  // modulemap are present.
  Path glibcDir;
  if (auto dir = findFirstIncludeDir(
          parsedIncludeArgs, {"inttypes.h", "unistd.h", "stdint.h"}, vfs)) {
    glibcDir = dir.value();
  } else {
    ctx.Diags.diagnose(SourceLoc(), diag::glibc_not_found, triple.str());
    return {};
  }

  Path actualModuleMapPath;
  if (auto path = getGlibcModuleMapPath(ctx.SearchPathOpts, triple, vfs))
    actualModuleMapPath = path.value();
  else
    // FIXME: Emit a warning of some kind.
    return {};

  // TODO: remove the SwiftGlibc.h header and reference all Glibc headers
  // directly from the modulemap.
  Path actualHeaderPath = actualModuleMapPath;
  llvm::sys::path::remove_filename(actualHeaderPath);
  llvm::sys::path::append(actualHeaderPath, "SwiftGlibc.h");

  Path injectedModuleMapPath(glibcDir);
  llvm::sys::path::append(injectedModuleMapPath, "module.modulemap");

  Path injectedHeaderPath(glibcDir);
  llvm::sys::path::append(injectedHeaderPath, "SwiftGlibc.h");

  return {
      {std::string(injectedModuleMapPath), std::string(actualModuleMapPath)},
      {std::string(injectedHeaderPath), std::string(actualHeaderPath)},
  };
}

static void getLibStdCxxFileMapping(
    ClangInvocationFileMapping &fileMapping, ASTContext &ctx,
    const llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem> &vfs) {
  assert(ctx.LangOpts.EnableCXXInterop &&
         "libstdc++ is only injected if C++ interop is enabled");

  const llvm::Triple &triple = ctx.LangOpts.Target;
  // We currently only need this when building for Linux.
  if (!triple.isOSLinux())
    return;
  // Android uses libc++.
  if (triple.isAndroid())
    return;

  // Extract the libstdc++ installation path from Clang driver.
  auto clangDriver = createClangDriver(ctx, vfs);
  auto clangDriverArgs = createClangArgs(ctx, clangDriver);

  llvm::opt::ArgStringList stdlibArgStrings;
  const auto &clangToolchain =
      clangDriver.getToolChain(clangDriverArgs, triple);
  clangToolchain.AddClangCXXStdlibIncludeArgs(clangDriverArgs,
                                              stdlibArgStrings);
  auto parsedStdlibArgs = parseClangDriverArgs(clangDriver, stdlibArgStrings);

  Path cxxStdlibDir;
  if (auto dir = findFirstIncludeDir(parsedStdlibArgs,
                                     {"cstdlib", "string", "vector"}, vfs)) {
    cxxStdlibDir = dir.value();
  } else {
    ctx.Diags.diagnose(SourceLoc(), diag::libstdcxx_not_found, triple.str());
    return;
  }

  Path actualModuleMapPath;
  if (auto path = getLibStdCxxModuleMapPath(ctx.SearchPathOpts, triple, vfs))
    actualModuleMapPath = path.value();
  else
    return;
  // Only inject the module map if it actually exists. It may not, for example
  // if `swiftc -target x86_64-unknown-linux-gnu -emit-ir` is invoked using
  // a Swift compiler not built for Linux targets.
  if (!vfs->exists(actualModuleMapPath))
    // FIXME: emit a warning of some kind.
    return;
  // TODO: remove the libstdcxx.h header and reference all libstdc++ headers
  // directly from the modulemap.
  Path actualHeaderPath = actualModuleMapPath;
  llvm::sys::path::remove_filename(actualHeaderPath);
  llvm::sys::path::append(actualHeaderPath, "libstdcxx.h");

  // Inject a modulemap into VFS for the libstdc++ directory.
  // Only inject the module map if the module does not already exist at
  // {sysroot}/usr/include/module.{map,modulemap}.
  Path injectedModuleMapPath;
  if (auto path = getInjectedModuleMapPath(cxxStdlibDir, vfs))
    injectedModuleMapPath = path.value();
  else
    return;

  Path injectedHeaderPath(cxxStdlibDir);
  llvm::sys::path::append(injectedHeaderPath, "libstdcxx.h");

  // Add additional headers to the static libstdc++ module map, only when these
  // additional headers are present in libstdc++.
  auto file = vfs->openFileForRead(actualModuleMapPath);
  if (!file) {
    ctx.Diags.diagnose(SourceLoc(), diag::libstdcxx_modulemap_not_found,
                       triple.str());
    return;
  }
  auto buf = (*file)->getBuffer("libstdcxx.modulemap");
  if (!buf) {
    ctx.Diags.diagnose(SourceLoc(), diag::libstdcxx_modulemap_not_found,
                       triple.str());
    return;
  }

  fileMapping.redirectedFiles.push_back(
      {std::string(injectedHeaderPath), std::string(actualHeaderPath)});

  auto contents = (*buf)->getBuffer();
  auto headerInjectionPoint = contents.find("/// additional headers");
  if (headerInjectionPoint == StringRef::npos) {
    fileMapping.redirectedFiles.push_back(
        {std::string(injectedModuleMapPath), std::string(actualModuleMapPath)});
    return;
  }

  StringRef additionalFiles[] = {
      // libstdc++ 4.8.5 bundled with CentOS 7 does not include corecvt.
      "codecvt",
      // C++17 and newer:
      "any", "charconv", "filesystem", "memory_resource", "optional",
      "string_view", "variant", "bits/algorithmfwd.h", "bits/align.h",
      "bits/alloc_traits.h", "bits/allocated_ptr.h", "bits/allocator.h",
      "bits/atomic_base.h", "bits/atomic_futex.h",
      "bits/atomic_lockfree_defines.h", "bits/basic_ios.h",
      "bits/basic_string.h", "bits/c++0x_warning.h", "bits/char_traits.h",
      "bits/charconv.h", "bits/codecvt.h", "bits/concept_check.h",
      "bits/cpp_type_traits.h", "bits/cxxabi_forced.h",
      "bits/cxxabi_init_exception.h", "bits/enable_special_members.h",
      "bits/erase_if.h", "bits/exception.h", "bits/exception_defines.h",
      "bits/exception_ptr.h", "bits/forward_list.h", "bits/fs_dir.h",
      "bits/fs_fwd.h", "bits/fs_ops.h", "bits/fs_path.h", "bits/functexcept.h",
      "bits/functional_hash.h", "bits/gslice.h", "bits/gslice_array.h",
      "bits/hash_bytes.h", "bits/hashtable.h", "bits/hashtable_policy.h",
      "bits/indirect_array.h", "bits/invoke.h", "bits/ios_base.h",
      "bits/iterator_concepts.h", "bits/locale_classes.h", "bits/locale_conv.h",
      "bits/locale_facets.h", "bits/locale_facets_nonio.h", "bits/localefwd.h",
      "bits/mask_array.h", "bits/max_size_type.h", "bits/memoryfwd.h",
      "bits/move.h", "bits/nested_exception.h", "bits/node_handle.h",
      "bits/ostream_insert.h", "bits/parse_numbers.h", "bits/postypes.h",
      "bits/predefined_ops.h", "bits/ptr_traits.h", "bits/quoted_string.h",
      "bits/random.h", "bits/range_access.h", "bits/ranges_algo.h",
      "bits/ranges_algobase.h", "bits/ranges_base.h", "bits/ranges_cmp.h",
      "bits/ranges_uninitialized.h", "bits/ranges_util.h", "bits/refwrap.h",
      "bits/shared_ptr.h", "bits/shared_ptr_atomic.h", "bits/shared_ptr_base.h",
      "bits/slice_array.h", "bits/std_abs.h", "bits/std_function.h",
      "bits/std_mutex.h", "bits/std_thread.h", "bits/stl_algo.h",
      "bits/stl_algobase.h", "bits/stl_bvector.h", "bits/stl_construct.h",
      "bits/stl_deque.h", "bits/stl_function.h", "bits/stl_heap.h",
      "bits/stl_iterator.h", "bits/stl_iterator_base_funcs.h",
      "bits/stl_iterator_base_types.h", "bits/stl_list.h", "bits/stl_map.h",
      "bits/stl_multimap.h", "bits/stl_multiset.h", "bits/stl_numeric.h",
      "bits/stl_pair.h", "bits/stl_queue.h", "bits/stl_raw_storage_iter.h",
      "bits/stl_relops.h", "bits/stl_set.h", "bits/stl_stack.h",
      "bits/stl_tempbuf.h", "bits/stl_tree.h", "bits/stl_uninitialized.h",
      "bits/stl_vector.h", "bits/stream_iterator.h",
      "bits/streambuf_iterator.h", "bits/stringfwd.h",
      "bits/this_thread_sleep.h", "bits/uniform_int_dist.h",
      "bits/unique_lock.h", "bits/unique_ptr.h", "bits/unordered_map.h",
      "bits/unordered_set.h", "bits/uses_allocator.h",
      "bits/uses_allocator_args.h", "bits/valarray_after.h",
      "bits/valarray_array.h", "bits/valarray_before.h"};
  std::string additionalHeaderDirectives;
  llvm::raw_string_ostream os(additionalHeaderDirectives);
  os << contents.substr(0, headerInjectionPoint);
  SmallString<256> filePath;
  auto includeHeaderInModuleMap = [&](StringRef filename) {
    filePath.assign(cxxStdlibDir);
    llvm::sys::path::append(filePath, filename);
    if (vfs->exists(filePath))
      os << "header \"" << filename << "\"\n  ";
  };
  for (StringRef additionalFile : additionalFiles)
    includeHeaderInModuleMap(additionalFile);
  os << contents.substr(headerInjectionPoint);

  fileMapping.overridenFiles.push_back(
      {std::string(injectedModuleMapPath), std::move(os.str())});
}

namespace {
std::string
GetWindowsAuxiliaryFile(StringRef modulemap, const SearchPathOptions &Options) {
  StringRef SDKPath = Options.getSDKPath();
  if (!SDKPath.empty()) {
    llvm::SmallString<261> path{SDKPath};
    llvm::sys::path::append(path, "usr", "share", modulemap);
    if (llvm::sys::fs::exists(path))
      return path.str().str();
  }

  if (!Options.RuntimeResourcePath.empty()) {
    llvm::SmallString<261> path{Options.RuntimeResourcePath};
    llvm::sys::path::append(path, "windows", modulemap);
    if (llvm::sys::fs::exists(path))
      return path.str().str();
  }

  return "";
}

SmallVector<std::pair<std::string, std::string>, 2> GetWindowsFileMappings(
    ASTContext &Context,
    const llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem> &driverVFS) {
  const llvm::Triple &Triple = Context.LangOpts.Target;
  const SearchPathOptions &SearchPathOpts = Context.SearchPathOpts;
  SmallVector<std::pair<std::string, std::string>, 2> Mappings;
  std::string AuxiliaryFile;

  if (!Triple.isWindowsMSVCEnvironment())
    return Mappings;

  clang::driver::Driver Driver = createClangDriver(Context, driverVFS);
  const llvm::opt::InputArgList Args = createClangArgs(Context, Driver);
  const clang::driver::ToolChain &ToolChain = Driver.getToolChain(Args, Triple);
  llvm::vfs::FileSystem &VFS = ToolChain.getVFS();

  struct {
    std::string Path;
    std::string IncludeVersion;
    std::string LibraryVersion;
    int MajorVersion;
  } WindowsSDK;
  if (llvm::getWindowsSDKDir(VFS, SearchPathOpts.getWinSDKRoot(),
                             SearchPathOpts.getWinSDKVersion(), {},
                             WindowsSDK.Path, WindowsSDK.MajorVersion,
                             WindowsSDK.IncludeVersion,
                             WindowsSDK.LibraryVersion)) {
    llvm::SmallString<261> WinSDKInjection{WindowsSDK.Path};
    llvm::sys::path::append(WinSDKInjection, "Include");
    if (WindowsSDK.MajorVersion > 8)
      llvm::sys::path::append(WinSDKInjection, WindowsSDK.IncludeVersion, "um");
    llvm::sys::path::append(WinSDKInjection, "module.modulemap");

    AuxiliaryFile = GetWindowsAuxiliaryFile("winsdk.modulemap", SearchPathOpts);
    if (!AuxiliaryFile.empty())
      Mappings.emplace_back(std::string(WinSDKInjection), AuxiliaryFile);
  }

  struct {
    std::string Path;
    std::string Version;
  } UCRTSDK;
  if (llvm::getUniversalCRTSdkDir(VFS, SearchPathOpts.getWinSDKRoot(),
                                  SearchPathOpts.getWinSDKVersion(), {},
                                  UCRTSDK.Path, UCRTSDK.Version)) {
    llvm::SmallString<261> UCRTInjection{UCRTSDK.Path};
    llvm::sys::path::append(UCRTInjection, "Include", UCRTSDK.Version, "ucrt");
    llvm::sys::path::append(UCRTInjection, "module.modulemap");

    AuxiliaryFile = GetWindowsAuxiliaryFile("ucrt.modulemap", SearchPathOpts);
    if (!AuxiliaryFile.empty())
      Mappings.emplace_back(std::string(UCRTInjection), AuxiliaryFile);
  }

  struct {
    std::string Path;
    llvm::ToolsetLayout Layout;
  } VCTools;
  if (llvm::findVCToolChainViaCommandLine(VFS, SearchPathOpts.getVCToolsRoot(),
                                          SearchPathOpts.getVCToolsVersion(),
                                          {}, VCTools.Path, VCTools.Layout) ||
      llvm::findVCToolChainViaEnvironment(VFS, VCTools.Path, VCTools.Layout) ||
      llvm::findVCToolChainViaSetupConfig(VFS,
                                          SearchPathOpts.getVCToolsVersion(),
                                          VCTools.Path, VCTools.Layout)) {
    assert(VCTools.Layout == llvm::ToolsetLayout::VS2017OrNewer &&
           "unsupported toolset layout (VS2017+ required)");

    llvm::SmallString<261> VCToolsInjection{VCTools.Path};
    llvm::sys::path::append(VCToolsInjection, "include");

    llvm::sys::path::append(VCToolsInjection, "module.modulemap");
    AuxiliaryFile =
        GetWindowsAuxiliaryFile("vcruntime.modulemap", SearchPathOpts);
    if (!AuxiliaryFile.empty())
      Mappings.emplace_back(std::string(VCToolsInjection), AuxiliaryFile);

    llvm::sys::path::remove_filename(VCToolsInjection);
    llvm::sys::path::append(VCToolsInjection, "vcruntime.apinotes");
    AuxiliaryFile =
        GetWindowsAuxiliaryFile("vcruntime.apinotes", SearchPathOpts);
    if (!AuxiliaryFile.empty())
      Mappings.emplace_back(std::string(VCToolsInjection), AuxiliaryFile);
  }

  return Mappings;
}

/// Replace the SDK's collection declarations *inside* UIKit, rather than
/// importing a second module (or a bridging header) containing lookalike names.
/// The resource header supplies the public UIKit spelling and the backport's
/// actual Objective-C runtime names. It is shipped with the legacy runtime,
/// not with the SDK, and is only selected for a legacy iOS 5 device invocation.
static void getLegacyCollectionFileMapping(
    ClangInvocationFileMapping &result, ASTContext &ctx,
    const llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem> &vfs) {
  const bool collections = usesLegacyCollectionDeclarations(ctx);   // iOS 5 only
  const bool backports = usesLegacyUIKitBackportDeclarations(ctx);  // iOS 5..10
  if ((!collections && !backports) || ctx.SearchPathOpts.getSDKPath().empty())
    return;
  const unsigned deploymentMajor = legacyDeploymentMajor(ctx);

  Path headers(ctx.SearchPathOpts.getSDKPath());
  llvm::sys::path::append(headers, "System", "Library", "Frameworks");
  llvm::sys::path::append(headers, "UIKit.framework", "Headers");
  Path umbrella(headers);
  llvm::sys::path::append(umbrella, "UIKit.h");
  auto contents = vfs->getBufferForFile(umbrella);
  if (!contents)
    return; // Non-UIKit compilations do not require a UIKit SDK.

  Path resource(ctx.SearchPathOpts.RuntimeResourcePath);
  llvm::sys::path::append(resource, "legacy-collection", "Headers",
                          "UIKitLegacyCollection.h");
  std::string include =
      "\n// Swift legacy iOS 5 UIKit module augmentation.\n#include \"";
  for (char c : resource) {
    if (c == '\\' || c == '"')
      include += '\\';
    include += c;
  }
  include += "\"\n";
  Path nativeCollection(headers);
  llvm::sys::path::append(nativeCollection, "UICollectionView.h");
  if (vfs->exists(nativeCollection)) {
    // Keep native signatures, modern declarations, and API-notes associations.
    // Change only supported Objective-C/C linkage, inside the real UIKit module.
    // Each rewrite is gated per deployment version inside legacyCollectionHeader,
    // so a class the SDK already provides at the target keeps its native identity.
    for (StringRef file : {"UICollectionView.h", "UICollectionViewCell.h",
                          "UICollectionViewLayout.h", "UICollectionViewFlowLayout.h",
                          "UICollectionViewController.h", "UICollectionViewUpdateItem.h",
                          "UILayoutGuide.h", "NSLayoutAnchor.h", "UIRefreshControl.h",
                          "UIStackView.h", "UICollectionViewCompositionalLayout.h",
                          "UIGeometry.h", "UIView.h", "NSAttributedString.h"}) {
      Path path(headers);
      llvm::sys::path::append(path, file);
      if (auto source = vfs->getBufferForFile(path))
        result.overridenFiles.emplace_back(path.str().str(),
            legacyCollectionHeader(source.get()->getBuffer(), backports,
                                   /*foundationFacades=*/false, deploymentMajor));
    }
    // The supplemental collection header exists only for iOS 5 SDK-less cases.
    if (collections) {
      // Fail closed on incomplete toolchain packaging, without including
      // duplicate fallback declarations into a contemporary SDK.
      std::string augmented(contents.get()->getBuffer());
      augmented += "\n#if !__has_include(\"";
      for (char c : resource) {
        if (c == '\\' || c == '"') augmented += '\\';
        augmented += c;
      }
      augmented += "\")\n" + include + "#endif\n";
      result.overridenFiles.emplace_back(umbrella.str().str(), std::move(augmented));
    }
    return;
  }
  if (!collections)
    return;
  std::string augmented(contents.get()->getBuffer());
  augmented += include;
  result.overridenFiles.emplace_back(umbrella.str().str(), std::move(augmented));

  // Original iOS 5 SDKs have no collection declarations; only these use the
  // generated supplemental header, imported as part of UIKit's own umbrella.
}
// The Foundation supplement uses the same target guard as UIKit, but no
// additional client module or bridging header. Native API notes remain intact.
static void getLegacyFoundationFileMapping(
    ClangInvocationFileMapping &result, ASTContext &ctx,
    const llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem> &vfs) {
  if (!usesLegacyUIKitBackportDeclarations(ctx) ||
      ctx.SearchPathOpts.getSDKPath().empty())
    return;
  Path headers(ctx.SearchPathOpts.getSDKPath());
  llvm::sys::path::append(headers, "System", "Library", "Frameworks");
  llvm::sys::path::append(headers, "Foundation.framework", "Headers");
  for (StringRef file : {"NSURL.h", "NSURLComponents.h", "NSURLSession.h",
                        "NSISO8601DateFormatter.h", "NSHashTable.h"}) {
    Path path(headers);
    llvm::sys::path::append(path, file);
    if (auto source = vfs->getBufferForFile(path))
      result.overridenFiles.emplace_back(path.str().str(),
          legacyCollectionHeader(source.get()->getBuffer(), false, true));
  }
}
} // namespace

ClangInvocationFileMapping swift::getClangInvocationFileMapping(
    ASTContext &ctx, llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem> vfs) {
  ClangInvocationFileMapping result;
  if (!vfs)
    vfs = llvm::vfs::getRealFileSystem();
  // Android/BSD/Linux Mappings
  result.redirectedFiles.append(getGlibcFileMapping(ctx, vfs));
  if (ctx.LangOpts.EnableCXXInterop)
    getLibStdCxxFileMapping(result, ctx, vfs);

  result.redirectedFiles.append(GetWindowsFileMappings(ctx, vfs));
  getLegacyCollectionFileMapping(result, ctx, vfs);
  getLegacyFoundationFileMapping(result, ctx, vfs);

  return result;
}
