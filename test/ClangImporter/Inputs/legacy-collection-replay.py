"""Replay UIKit's scanner-produced PCM command without supplying overlay flags."""
import json
import subprocess
import sys

graph_path = sys.argv[1]
compiler = sys.argv[2:]
with open(graph_path) as stream:
    graph = json.load(stream)
for module in graph["modules"]:
    details = module.get("details", {}).get("clang", {})
    if details.get("moduleMapPath", "").endswith(
        "UIKit.framework/Modules/module.modulemap"
    ):
        command = details["commandLine"]
        for required in ("-enable-legacy-ios5-class-marking", "-sdk", "-resource-dir", "-target"):
            assert required in command, (required, command)
        assert any("__SWIFT_LEGACY_UIKIT_COLLECTIONS=3" in arg for arg in command), command
        subprocess.check_call(compiler + command)
        break
else:
    raise AssertionError("UIKit is absent from the Clang dependency graph")
