"""Link the replay to the app's existing optimized Apple Silicon dependencies."""
from pathlib import Path
import subprocess
import sys

repo = Path(__file__).resolve().parents[2]
derived = repo / "DerivedData"
products = derived / "Build/Products/Release"
module_maps = derived / "Build/Intermediates.noindex/GeneratedModuleMaps"
source = Path(__file__).with_name("Replay.swift")
output = Path(sys.argv[1]) if len(sys.argv) > 1 else derived / "DictationPerformanceReplay"
dependencies = [
    "FluidAudio", "FastClusterWrapper", "MachTaskSelfWrapper", "Tokenizers",
    "Hub", "Jinja", "OrderedCollections", "InternalCollectionsUtilities",
    "HuggingFace", "yyjson", "Crypto", "EventSource",
]
objects = [products / (name + ".o") for name in dependencies]
missing = [str(path) for path in objects if not path.is_file()]
if missing:
    sys.exit("Build the Release app first. Missing objects:\n" + "\n".join(missing))

# Xcode's dependency objects contain profiling symbols, hence -profile-generate.
command = [
    "swiftc", "-O", "-profile-generate", "-parse-as-library",
    "-target", "arm64-apple-macos15.0",
    "-module-cache-path", str(derived / "ModuleCache.noindex"),
    "-I", str(products), "-Xcc",
    "-fmodule-map-file=" + str(module_maps / "yyjson.modulemap"),
]
for wrapper in ["FastClusterWrapper", "MachTaskSelfWrapper"]:
    command += ["-I", str(derived / "SourcePackages/checkouts/FluidAudio/Sources" / wrapper / "include")]
command += [str(source), str(repo / "Sources/Fluid/Services/DictationPreviewCadence.swift")]
command += [str(path) for path in objects]
command += ["-lc++", "-o", str(output)]
subprocess.run(command, check=True)
print(output)
