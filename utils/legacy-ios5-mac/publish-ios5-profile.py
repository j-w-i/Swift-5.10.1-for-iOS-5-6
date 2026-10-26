#!/usr/bin/env python3
"""Publish a static-qualified, opt-in iOS 5 profile; never install/select anything.

Usage (all three paths must be explicit and absolute):
  publish-ios5-profile.py --environment-root ROOT --toolchain TC.xctoolchain \
      --evidence /absolute/qualification.json [--validate-only]

Evidence contract (JSON; duplicate keys and non-finite numbers are rejected):
  schemaVersion: 1
  staticBuildVerified, abiClassMarkingVerified, ios5ArchiveVerified,
  defaultIOS6ArchiveVerified, importsVerified, hostSignaturesVerified: true
    (actual JSON booleans)
  compilerSHA256, driverSHA256, assemblyReceiptSHA256: SHA-256 hex strings
  resourceSHA256: object mapping EXACT toolchain-relative filenames to SHA-256
    hex strings captured when the supplied qualification checks were performed:
    Info.plist
    usr/lib/swift/iphoneos/libswiftCore.dylib (preserved default iOS 6 core)
    usr/lib/swift_ios5/iphoneos/crt1.3.1.o
    usr/lib/swift_ios5/iphoneos/libswiftLegacyIOS5Backports.a
    usr/lib/swift_ios5/legacy-collection/{Headers/UIKitLegacyCollection.h,LICENSE,SNAPSHOT.json}
    usr/lib/swift_ios5/iphoneos/libswift{Core,Darwin,ObjectiveC,CoreFoundation,
      Dispatch,CoreGraphics,Foundation,Metal,QuartzCore,CoreImage,UIKit}.dylib
    usr/lib/swift_ios5/iphoneos/{Swift,Darwin,Dispatch,CoreGraphics,Foundation,
      Metal,QuartzCore,CoreImage,UIKit}.swiftmodule/{armv7,armv7-apple-ios}.swiftmodule
    Braces above describe expansions, NOT literal keys. Each of the nine module
    directories requires at least one listed armv7 spelling; include BOTH when
    both exist. No missing or additional keys are allowed. Hash final assembled
    resources at qualification time, not freshly substituted publication inputs.
  deviceExecution: "pending" or "observed"
  provenance: {
    staticBuild: {logPath: "/.../build.log", artifactPath: "/.../product"},
    abiClassMarking: {logPath: "/.../check.log", artifactPath: "/.../object"},
    ios5Archive: {logPath: "/.../check.log", artifactPath: "/.../Archive.xcarchive"},
    defaultIOS6Archive: {logPath: "/.../check.log", artifactPath: "/.../Archive.xcarchive"},
    imports: {logPath: "/.../check.log", artifactPath: "/.../import-report"},
    deviceExecution: {logPath: "/.../device.log", artifactPath: "/.../result"}
  }
The deviceExecution provenance entry is required only for "observed". Logs must
be nonempty files; artifacts may be nonempty files or nonempty directory trees.
Use preserved, reviewed build/check output, not placeholder files. The publisher
validates and binds supplied evidence; it does NOT run archives or independently
reproduce qualification. No boolean assertion alone is accepted as evidence.

--validate-only validates evidence structure, hashes' syntax and provenance files
without invoking the compiler or any external tool, and NEVER writes a profile.
It does not mean the toolchain is qualified. Normal publication additionally
compares current binaries/resources with the qualification-time expected hashes.
Normal publication also requires the assembly receipt's adhocSignedAndVerified
list to contain exactly usr/bin/{swift-frontend,swift-driver,swiftc,swift}, and
runs codesign --verify --strict on all four current host binaries. The evidence
hostSignaturesVerified assertion is mandatory even for --validate-only, which
checks its structure but does not run codesign or inspect the toolchain.
Signature verification here is an ad-hoc integrity check only: it does NOT claim
cryptographic publisher identity, Developer ID signing, notarization, or trust.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile


TOOLCHAIN_ID = "org.swift.5101.ios5.experimental"
OVERLAYS = ("Dispatch", "CoreGraphics", "Foundation", "Metal", "QuartzCore", "CoreImage", "UIKit")
CHECKS = ("staticBuild", "abiClassMarking", "ios5Archive", "defaultIOS6Archive", "imports")
PROFILE = "ios5-profile.json"
FLAG = "-enable-legacy-ios5-runtime"
HOST_BINARIES = ("swift-frontend", "swift-driver", "swiftc", "swift")
RESOURCE_PREFIX = "usr/lib/swift_ios5/iphoneos/"
COLLECTION_RESOURCES = tuple("usr/lib/swift_ios5/legacy-collection/" + name for name in
                             ("Headers/UIKitLegacyCollection.h", "LICENSE", "SNAPSHOT.json")) + (
    "usr/lib/swift_ios5/legacy-backports/INVENTORY.json",)
FIXED_RESOURCES = ("Info.plist", "usr/lib/swift/iphoneos/libswiftCore.dylib") + COLLECTION_RESOURCES + tuple(
    RESOURCE_PREFIX + name for name in
    ("crt1.3.1.o", "libswiftLegacyIOS5Backports.a") + tuple(
        "libswift" + name + ".dylib"
        for name in ("Core", "Darwin", "ObjectiveC", "CoreFoundation") + OVERLAYS))
MODULE_RESOURCES = tuple(
    tuple(RESOURCE_PREFIX + name + ".swiftmodule/" + arch + ".swiftmodule"
          for arch in ("armv7", "armv7-apple-ios"))
    for name in ("Swift", "Darwin") + OVERLAYS)


class Rejected(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise Rejected(message)


def absolute(value, label):
    require(isinstance(value, str) and value.startswith("/") and
            not any(ord(c) < 32 for c in value), label + " must be an explicit absolute path")
    return Path(value)


def nonempty(path):
    require(path.is_file() and path.stat().st_size > 0,
            "Missing or empty required file: " + str(path))
    return path


def digest(path):
    nonempty(path)
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "Duplicate JSON key: " + key)
        result[key] = value
    return result


def reject_constant(value):
    raise Rejected("Invalid JSON numeric constant: " + value)


def load_json(path):
    nonempty(path)
    raw = path.read_bytes()
    value = json.loads(raw, object_pairs_hook=unique_object, parse_constant=reject_constant)
    require(isinstance(value, dict), "JSON document must be an object: " + str(path))
    return value, hashlib.sha256(raw).hexdigest()


def sha_field(document, key):
    value = document.get(key)
    require(isinstance(value, str) and re.fullmatch(r"[0-9a-fA-F]{64}", value) is not None,
            key + " must be a SHA-256 hex string")
    return value.lower()


def resource_hashes(evidence):
    """Validate the qualification-time inventory without inspecting a toolchain."""
    values = evidence.get("resourceSHA256")
    require(isinstance(values, dict), "Evidence requires resourceSHA256 object")
    allowed = set(FIXED_RESOURCES).union(*(set(group) for group in MODULE_RESOURCES))
    require(set(values) <= allowed, "resourceSHA256 contains unexpected filenames")
    require(set(FIXED_RESOURCES) <= set(values),
            "resourceSHA256 lacks required startup/archive/dylib/default/identity files")
    for group in MODULE_RESOURCES:
        require(any(name in values for name in group),
                "resourceSHA256 lacks rebuilt armv7 module: " + group[0])
    return {name: sha_field(values, name) for name in values}


def artifact_record(path):
    """Hash preserved artifacts, including a directory's complete file inventory."""
    path = path.resolve(strict=True)
    if path.is_file():
        return {"path": str(path), "sha256": digest(path)}
    require(path.is_dir(), "Artifact is not a file/directory: " + str(path))
    entries = []
    # Do not follow directory symlinks (which could silently omit evidence).
    for root, dirs, files in os.walk(path, followlinks=False):
        for name in dirs:
            require(not (Path(root) / name).is_symlink(),
                    "Artifact directory symlink is not supported: " + str(Path(root) / name))
        for name in sorted(files):
            child = Path(root) / name
            require(child.is_file(), "Non-regular artifact: " + str(child))
            resolved = child.resolve(strict=True)
            require(path in resolved.parents, "Artifact symlink escapes tree: " + str(child))
            # Empty archive metadata files are legitimate; the entire tree must
            # contain at least one nonempty file.
            h = hashlib.sha256(child.read_bytes()).hexdigest()
            entries.append((str(child.relative_to(path)), child.stat().st_size, h))
    require(any(size > 0 for _, size, _ in entries), "Empty artifact tree: " + str(path))
    encoded = json.dumps(sorted(entries), separators=(",", ":")).encode("utf-8")
    return {"path": str(path), "treeSHA256": hashlib.sha256(encoded).hexdigest(),
            "fileCount": len(entries)}


def validate_evidence(path):
    evidence, evidence_hash = load_json(path)
    require(type(evidence.get("schemaVersion")) is int and evidence["schemaVersion"] == 1,
            "Evidence schemaVersion must be integer 1")
    for check in CHECKS:
        require(evidence.get(check + "Verified") is True,
                "Evidence requires " + check + "Verified: true")
    require(evidence.get("hostSignaturesVerified") is True,
            "Evidence requires hostSignaturesVerified: true (ad-hoc integrity only)")
    for key in ("compilerSHA256", "driverSHA256", "assemblyReceiptSHA256"):
        sha_field(evidence, key)
    resource_hashes(evidence)
    device = evidence.get("deviceExecution")
    require(isinstance(device, str) and device in ("pending", "observed"),
            'deviceExecution must be "pending" or "observed"; pending is NOT verified')
    provenance = evidence.get("provenance")
    require(isinstance(provenance, dict), "Evidence requires detailed provenance")
    records = {}
    required = CHECKS + (("deviceExecution",) if device == "observed" else ())
    for key in required:
        item = provenance.get(key)
        require(isinstance(item, dict), "Missing provenance for " + key)
        log = absolute(item.get("logPath"), key + ".logPath").resolve(strict=True)
        artifact = absolute(item.get("artifactPath"), key + ".artifactPath")
        records[key] = {"log": {"path": str(log), "sha256": digest(log)},
                        "artifact": artifact_record(artifact)}
    return evidence, evidence_hash, records


def inside_file(toolchain, relative):
    path = toolchain / relative
    resolved = path.resolve(strict=True)
    require(toolchain in resolved.parents, "Toolchain file escapes assembly: " + str(path))
    return nonempty(path)


def check_toolchain(toolchain, evidence):
    require(toolchain.is_dir(), "Toolchain directory does not exist")
    info_path = inside_file(toolchain, "Info.plist")
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    require(isinstance(info, dict) and info.get("CFBundleIdentifier") == TOOLCHAIN_ID,
            "Toolchain must have distinct experimental CFBundleIdentifier " + TOOLCHAIN_ID)
    receipt_path = inside_file(toolchain, "ios5-assembly-receipt.json")
    receipt, receipt_hash = load_json(receipt_path)
    require(receipt_hash == sha_field(evidence, "assemblyReceiptSHA256"),
            "Assembly receipt SHA-256 does not match evidence")
    require(receipt.get("toolchainID") == TOOLCHAIN_ID and
            receipt.get("defaultResourceProfile") == "baseline" and
            receipt.get("ios5ResourceDirectory") == "usr/lib/swift_ios5" and
            receipt.get("runtime515SlotIncluded") is False,
            "Assembly receipt does not describe an isolated opt-in iOS 5 assembly")
    require(isinstance(receipt.get("overlays"), list) and
            set(receipt["overlays"]) == set(OVERLAYS), "Assembly receipt lacks all seven overlays")
    signed = receipt.get("adhocSignedAndVerified")
    expected_signed = {"usr/bin/" + name for name in HOST_BINARIES}
    require(isinstance(signed, list) and all(isinstance(name, str) for name in signed)
            and len(signed) == len(expected_signed) and set(signed) == expected_signed,
            "Assembly receipt must record ad-hoc signing and verification of all four host binaries")
    inputs = receipt.get("inputs")
    require(isinstance(inputs, dict) and len(inputs) >= 4,
            "Assembly receipt requires original input paths and hashes")
    for source, value in inputs.items():
        absolute(source, "assembly input")
        sha_field({"inputSHA256": value}, "inputSHA256")
    # Assembly input hashes precede ad-hoc signing: never compare these to the
    # installed compiler. Evidence must hash the final assembled binaries.
    baseline = absolute(receipt.get("baseline"), "assembly baseline")
    require(baseline.resolve() != toolchain, "Experimental toolchain cannot be its own baseline")
    if (baseline / "Info.plist").is_file():
        with (baseline / "Info.plist").open("rb") as stream:
            baseline_info = plistlib.load(stream)
        require(isinstance(baseline_info, dict) and
                baseline_info.get("CFBundleIdentifier") != TOOLCHAIN_ID,
                "Experimental identity is not distinct from baseline")

    files = {}
    for name, key in (("swift-frontend", "compilerSHA256"), ("swift-driver", "driverSHA256"),
                      ("swiftc", "driverSHA256"), ("swift", "driverSHA256")):
        relative = "usr/bin/" + name
        path = inside_file(toolchain, relative)
        require(os.access(path, os.X_OK), "Compiler is not executable: " + str(path))
        with path.open("rb") as stream:
            header = stream.read(8)
        require(header == b"\xcf\xfa\xed\xfe\x07\x00\x00\x01",
                "Expected assembled thin x86_64 Mach-O compiler, not a wrapper: " + str(path))
        files[relative] = digest(path)
        require(files[relative] == sha_field(evidence, key),
                "Current " + name + " SHA-256 does not match qualification evidence")

    resources = toolchain / "usr/lib/swift_ios5"
    expected_resources = resource_hashes(evidence)
    required = set(FIXED_RESOURCES)
    for group in MODULE_RESOURCES:
        present = {name for name in group if (toolchain / name).exists()}
        require(present, "Missing rebuilt armv7 module: " + group[0])
        required.update(present)
    require(required == set(expected_resources),
            "Current resource inventory does not match qualification-time resourceSHA256")
    for relative in sorted(required):
        files[relative] = digest(inside_file(toolchain, relative))
        require(files[relative] == expected_resources[relative],
                "Current resource SHA-256 does not match qualification evidence: " + relative)
    # The default profile must still exist, independently of opt-in resources.
    default = inside_file(toolchain, "usr/lib/swift/iphoneos/libswiftCore.dylib")
    require(default.resolve() != (resources / "iphoneos/libswiftCore.dylib").resolve(),
            "Default iOS 6 resources alias the opt-in iOS 5 core")
    for name in HOST_BINARIES:
        result = subprocess.run(["codesign", "--verify", "--strict",
                                 str(toolchain / "usr/bin" / name)],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, errors="replace", timeout=60, check=False)
        require(result.returncode == 0,
                "Host ad-hoc signature verification failed for " + name + ": " + result.stdout)
    result = subprocess.run([str(toolchain / "usr/bin/swift-frontend"), "-help"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, errors="replace", timeout=60, check=False)
    require(result.returncode == 0, "Compiler frontend -help failed")
    require(re.search(r"(?<![\w-])" + re.escape(FLAG) + r"(?![\w-])", result.stdout),
            "Compiler frontend does not advertise " + FLAG)
    # Detect changes during help execution before committing a trusted profile.
    for relative, expected in files.items():
        require(digest(inside_file(toolchain, relative)) == expected,
                "Toolchain changed during qualification: " + relative)
    return resources, receipt_path, receipt_hash, files


def publish(root, profile):
    """Flush a new file, atomically hard-link without replacement, flush directory."""
    flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0)
    directory_fd = os.open(root, flags)
    temporary = None
    try:
        require(not os.path.lexists(root / PROFILE), "Refusing existing profile: " + str(root / PROFILE))
        fd, name = tempfile.mkstemp(prefix=".ios5-profile-", suffix=".tmp", dir=root)
        temporary = Path(name)
        require(temporary.parent == root and temporary.name.startswith(".ios5-profile-"),
                "Unexpected temporary profile path")
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(profile, stream, indent=2, sort_keys=True, allow_nan=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        # link() fails even if the destination is a dangling symlink. No rename
        # or replace fallback: existing profiles are never overwritten.
        os.link(temporary.name, PROFILE, src_dir_fd=directory_fd,
                dst_dir_fd=directory_fd, follow_symlinks=False)
        os.fsync(directory_fd)
    finally:
        if temporary is not None:
            # Only remove the checked mkstemp basename in the opened root.
            os.unlink(temporary.name, dir_fd=directory_fd)
            os.fsync(directory_fd)
        os.close(directory_fd)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--environment-root", required=True)
    parser.add_argument("--toolchain", required=True)
    parser.add_argument("--evidence", required=True)
    parser.add_argument("--validate-only", action="store_true",
                        help="Check evidence only; no external tools and no profile write")
    args = parser.parse_args(argv)
    try:
        root = absolute(args.environment_root, "--environment-root").resolve(strict=True)
        require(root.is_dir(), "Environment root must already exist as a directory")
        toolchain = absolute(args.toolchain, "--toolchain")
        evidence_path = absolute(args.evidence, "--evidence").resolve(strict=True)
        evidence, evidence_hash, provenance = validate_evidence(evidence_path)
        if args.validate_only:
            print("Evidence structurally valid; toolchain NOT qualified; no profile written. "
                  "Device execution: " + evidence["deviceExecution"] + ".")
            return 0
        require(not os.path.lexists(root / PROFILE), "Refusing existing profile: " + str(root / PROFILE))
        toolchain = toolchain.resolve(strict=True)
        resources, receipt, receipt_hash, files = check_toolchain(toolchain, evidence)
        # Bind the exact evidence bytes and preserved artifacts used above.
        current, current_hash, current_provenance = validate_evidence(evidence_path)
        require(current == evidence and current_hash == evidence_hash and current_provenance == provenance,
                "Evidence or provenance changed during qualification")
        require(digest(receipt) == receipt_hash, "Assembly receipt changed during qualification")
        profile = {"schemaVersion": 1, "verifiedIOS5Capability": True,
                   "compilerPath": str(toolchain), "runtimeResourcePath": str(resources),
                   "toolchainID": TOOLCHAIN_ID, "minimumDeploymentTarget": "5.0",
                   "architectures": ["armv7"], "evidence": str(evidence_path),
                   "evidenceSHA256": evidence_hash, "qualificationScope": "static-only",
                   "deviceExecution": evidence["deviceExecution"],
                   "deviceExecutionVerified": evidence["deviceExecution"] == "observed",
                   "assemblyReceiptPath": str(receipt), "assemblyReceiptSHA256": receipt_hash,
                   "compilerSHA256": sha_field(evidence, "compilerSHA256"),
                   "driverSHA256": sha_field(evidence, "driverSHA256"),
                   "hostSignaturesVerified": True,
                   "qualifiedFilesSHA256": files, "provenance": provenance,
                   "limitations": ["Host signatures provide ad-hoc integrity only, not publisher identity or notarization.",
                                    "Static qualification is not proof of device compatibility.",
                                   "Device execution: " + evidence["deviceExecution"] + ".",
                                   "No environment receipt, global installation or selection modified."]}
        publish(root, profile)
        print("Published static-qualified profile: " + str(root / PROFILE))
        print("Device execution: " + evidence["deviceExecution"] + "; no installation/selection performed.")
        return 0
    except (OSError, ValueError, TypeError, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
        print("publish-ios5-profile: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
