"""Dump local or archived macOS localization tables."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
IPSW = os.environ.get("IPSW_BIN", "ipsw")
PRIVACY = "System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex/Contents/Resources/Localizable.loctable"
SYSTEM = (
    r"System/((Library|iOSSupport/System/Library)/(PrivateFrameworks|AccessibilityBundles)/"
    r"(Chat|IM).*\.loctable|" + re.escape(PRIVACY.removeprefix("System/")) + ")"
)
BUNDLE = re.compile(r"([a-zA-Z0-9_-]+)\.(framework|axbundle|appex)")
DEVICE = "Macmini9,1"


def capture(*args):
    return subprocess.check_output(args, text=True).strip()


def format_json(files):
    subprocess.run(["yarn", "prettier", "--no-config", "--no-editorconfig", "--ignore-path",
                    os.devnull, "--write", *files], cwd=HERE, check=True, stdout=subprocess.DEVNULL)


def tracked(relative):
    return bool(re.fullmatch(SYSTEM, relative)) and "IMAP." not in relative


def extract(release, work, pattern, *flags):
    subprocess.run([IPSW, "extract", "--remote", *flags, "--pattern", pattern,
                    "--output", work, release["url"]], check=True)


def ota_files(release, work):
    # post.bom lists installed paths, including names stored as hard links.
    metadata = r"(^|/)(post\.bom|payloadv2\.bom|payloadv2/links\.txt)$"
    extract(release, work, metadata if release["json_files"] else r"(^|/)post\.bom$")
    (bom,) = work.glob(release["build"] + "__*/AssetData/post.bom")
    paths = capture("lsbom", "-s", bom).splitlines()
    wanted = {p[2:] for p in paths if p.startswith("./") and tracked(p[2:])}
    if not wanted:
        return []
    if not release["json_files"]:
        raise ValueError(f"{release['build']}: unexpected loctables in post.bom")

    payloads = bom.parent / "payloadv2"
    carriers = {p: p for p in wanted}
    links = payloads / "links.txt"
    if links.exists():
        with links.open(encoding="utf-8") as groups:
            for line in groups:
                name = line[1:].rstrip("\r\n").removeprefix("./")
                if line.startswith("="):
                    carrier = name
                elif line.startswith("+") and name in wanted:
                    carriers[name] = carrier

    names = sorted(set(carriers.values()))
    pattern = r"^(\./)?(" + "|".join(re.escape(n) for n in names) + ")$"
    tree = work / "payload"
    tree.mkdir()
    # Apple packs small resources near the end. The installed path list tells
    # us when we have all of them, regardless of how a release was packed.
    index = capture("lsbom", "-s", bom.with_name("payloadv2.bom"))
    numbers = sorted(re.findall(r"^\./payloadv2/payload\.(\d+)$", index, re.M), key=int, reverse=True)
    for start in range(0, len(numbers), 4):
        batch = numbers[start:start + 4]
        extract(release, work, r"(^|/)payloadv2/payload\.(" + "|".join(batch) + ")$")
        for number in batch:
            member = payloads / ("payload." + number)
            subprocess.run(["aa", "extract", "-i", member, "-d", tree,
                            "-include-regex", pattern, "-exclude-type", "d"], check=True)
            member.unlink()
        if all((tree / name).is_file() for name in names):
            break
    else:
        raise ValueError(f"{release['build']}: incomplete OTA payload")
    return [(p, tree / carriers[p]) for p in sorted(wanted)]


def ipsw_files(release, work):
    extract(release, work, "^/" + SYSTEM + "$", "--files", "--ranged", "--ranged-dmg", "fs",
            "--device", release.get("device", DEVICE))
    roots = list(work.glob("*/System"))
    if not roots:
        return []
    (system,) = roots
    if not system.parent.name.startswith(release["build"] + "__"):
        raise ValueError(f"unexpected build directory {system.parent}")
    return system_files(system.parent)


def system_files(root):
    paths = list(root.glob(PRIVACY))
    for base in ("System/Library", "System/iOSSupport/System/Library"):
        for bundles in ("PrivateFrameworks", "AccessibilityBundles"):
            for prefix in ("Chat*", "IM*"):
                paths.extend((root / base / bundles).glob(prefix + "/**/*.loctable"))
    # Historical IPSW and local dumps resolved duplicate names in case-insensitive path order.
    files = [(str(p.relative_to(root)), p) for p in sorted(paths, key=lambda p: (str(p).casefold(), str(p)))
             if p.is_file()]
    return [file for file in files if tracked(file[0])]


def dump(release, directory):
    version, build = release["version"], release["build"]
    if not re.fullmatch(r"[0-9]+(\.[0-9]+)*", version) or not re.fullmatch(r"[a-zA-Z0-9]+", build):
        raise ValueError("invalid macOS version or build")
    pinned = "json_files" in release
    directory.parent.mkdir(parents=True, exist_ok=True)
    kind = release["source_type"]
    print(f"{directory.name}: extracting {kind}", flush=True)
    with tempfile.TemporaryDirectory(dir=directory.parent) as temp:
        work = Path(temp)
        if kind == "local":
            files = system_files(Path("/"))
        else:
            files = {"ota": ota_files, "ipsw": ipsw_files}[kind](release, work)
        stage = work / "json"
        stage.mkdir()
        # Both System trees can contain a table with the same output name.
        tables = {}
        for relative, path in files:
            bundle = BUNDLE.search(relative)
            if bundle:
                tables[f"{bundle[1]}-{Path(relative).stem}-{version.replace('.', '_')}-{build}.json"] = path
        if pinned and len(tables) != release["json_files"]:
            raise ValueError(f"{directory.name}: expected {release['json_files']} tables, found {len(tables)}")
        if not pinned and not tables:
            raise ValueError(f"{directory.name}: no matching loctables")
        unexpected = {p.name for p in directory.glob("*.json")} - tables.keys()
        if pinned and unexpected:
            raise ValueError(f"{directory.name}: unexpected output files: {sorted(unexpected)}")
        generated = []
        for name, path in sorted(tables.items()):
            target = stage / name
            generated.append(target)
            subprocess.run(["plutil", "-convert", "json", "-o", target, "--", path], check=True)
            if pinned and name.startswith("SecurityPrivacyExtension-"):
                data = json.loads(target.read_bytes())
                target.write_text(json.dumps(data, ensure_ascii=False, sort_keys=True, indent=2), encoding="utf-8")
        if generated:
            format_json(generated)
            directory.mkdir(exist_ok=True)
            for path in generated:
                path.replace(directory / path.name)
        print(f"{directory}: {len(generated)} JSON files", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("dump", "format"), default="dump", nargs="?")
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--all", action="store_true", help="reproduce every release in sources.json")
    source.add_argument("--ipsw", metavar="URL|latest")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--jobs", type=int, metavar="N", help="concurrent releases with --all (default: 4)")
    args = parser.parse_args()
    if args.jobs is not None and (not args.all or args.jobs < 1):
        parser.error("--jobs requires --all and a positive integer")
    if args.command == "format" and (args.all or args.ipsw):
        parser.error("format only accepts --output")
    if args.all or args.ipsw:
        if "--ranged-dmg" not in capture(IPSW, "extract", "--help"):
            parser.error("ranged extraction requires ipsw v3.1.750+ (or set IPSW_BIN)")
    if args.all:
        output = (args.output or HERE).resolve()
        releases = json.loads((HERE / "sources.json").read_text())["releases"]
        def rebuild(release):
            dump(release, output / f"{release['version']}-{release['build']}")

        # Start the longer OTA downloads first so they overlap the smaller IPSWs.
        with ThreadPoolExecutor(max_workers=args.jobs or 4) as pool:
            list(pool.map(rebuild, sorted(releases, key=lambda r: r["source_type"] != "ota")))
        return
    if args.ipsw:
        url = args.ipsw
        if url == "latest":
            url = capture(IPSW, "download", "ipsw", "--macos", "--latest", "--device", "VirtualMac2,1", "--urls")
        if not re.fullmatch(r"https://\S+", url):
            parser.error("expected one HTTPS IPSW URL")
        info = json.loads(capture(IPSW, "info", "--remote", "--json", url))
        release = dict(version=info["version"], build=info["build"], url=url, source_type="ipsw",
                       device=os.environ.get("IPSW_DEVICE", DEVICE))
    else:
        release = dict(version=capture("sw_vers", "--productVersion"),
                       build=capture("sw_vers", "--buildVersion"), source_type="local")
    directory = HERE / (args.output or f"{release['version']}-{release['build']}")
    if args.command == "format":
        files = sorted(directory.glob("*.json"))
        if not files:
            parser.error(f"no JSON files in {directory}")
        format_json(files)
    else:
        dump(release, directory)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
