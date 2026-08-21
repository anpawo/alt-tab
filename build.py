#!/usr/bin/env python3
"""Builds Alt-tab.app into ./dist.

    python3 build.py                  a universal build, signed with the local identity if
                                      there is one and ad-hoc otherwise
    python3 build.py --arch native    only this machine's architecture — faster, and what
                                      install.sh uses
    python3 build.py --adhoc --zip    what a downloadable release is made of

Nothing here talks to the network or to GitHub. It compiles, assembles the bundle, signs it,
and stops.

Two arguments, one caveat each:

--arch     Swift Package Manager can only build more than one architecture at a time through
           Xcode's XCBuild, which is absent on a machine with just the Command Line Tools. So
           a universal build here is two builds and a `lipo`, which is why it takes twice as
           long. `native` skips all of that.

--adhoc    macOS ties the Accessibility grant to the signing identity. A self-signed
           certificate keeps that grant across rebuilds; an ad-hoc signature cannot, because it
           has no identity — its fingerprint is a hash of the binary itself, so every build is
           a different app as far as the permission is concerned. Local builds should therefore
           use the certificate (`./make-signing-identity.sh` creates it, once) and anything
           meant to leave this machine has to be ad-hoc, since the certificate is trusted
           nowhere else.
"""

import argparse
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DIST = ROOT / "dist"
APP = DIST / "Alt-tab.app"
IDENTITY = "Alt-tab Self-Signed"


def run(*command, capture=False):
    result = subprocess.run(
        command, cwd=ROOT, text=True,
        stdout=subprocess.PIPE if capture else None,
    )
    if result.returncode != 0:
        sys.exit(f"error: {' '.join(command)} failed")
    return (result.stdout or "").strip()


def refuse_logging_in_the_key_path():
    """A stray log call in the key-handling path is a plaintext keylog, and the launch agent
    writes stderr to a file. Cheaper to make it un-shippable than to remember."""
    source = (ROOT / "Sources/AltTab/Trigger.swift").read_text()
    for number, line in enumerate(source.splitlines(), 1):
        if re.search(r"\b(NSLog|print|os_log)\b", line):
            sys.exit(f"error: no logging in the key-handling path — Trigger.swift:{number}")


def deployment_target():
    info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
    return info["LSMinimumSystemVersion"], info["CFBundleShortVersionString"]


def compile(architectures, target):
    """Returns the binaries built, one per architecture."""
    binaries = []
    for architecture in architectures:
        if architecture == "native":
            run("swift", "build", "-c", "release", "--product", "alt-tab")
            path = Path(run("swift", "build", "-c", "release", "--show-bin-path", capture=True))
        else:
            triple = f"{architecture}-apple-macosx{target}"
            run("swift", "build", "-c", "release", "--triple", triple, "--product", "alt-tab")
            path = ROOT / ".build" / f"{architecture}-apple-macosx" / "release"
        binaries.append(path / "alt-tab")
    return binaries


def assemble(binaries):
    if APP.exists():
        shutil.rmtree(APP)
    (APP / "Contents/MacOS").mkdir(parents=True)
    if len(binaries) == 1:
        shutil.copy2(binaries[0], APP / "Contents/MacOS/alt-tab")
    else:
        run("lipo", "-create", *[str(b) for b in binaries],
            "-output", str(APP / "Contents/MacOS/alt-tab"))
    shutil.copy2(ROOT / "Resources/Info.plist", APP / "Contents/Info.plist")


def sign(adhoc):
    available = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"],
                               text=True, stdout=subprocess.PIPE).stdout
    if not adhoc and IDENTITY in available:
        run("codesign", "--force", "--sign", IDENTITY, str(APP))
        return IDENTITY
    if not adhoc:
        print(f'==> No "{IDENTITY}" certificate — signing ad-hoc, so macOS will ask for '
              "Accessibility again after every build. ./make-signing-identity.sh creates one.")
    run("codesign", "--force", "--sign", "-", str(APP))
    return "ad-hoc"


def main():
    parser = argparse.ArgumentParser(description="Build Alt-tab.app.")
    parser.add_argument("--arch", default="universal",
                        choices=["universal", "native", "arm64", "x86_64"],
                        help="default: universal (Apple Silicon and Intel)")
    parser.add_argument("--adhoc", action="store_true",
                        help="sign ad-hoc even when the local certificate exists")
    parser.add_argument("--zip", action="store_true",
                        help="also write dist/Alt-tab-<version>.zip")
    parser.add_argument("--no-check", action="store_true", help="skip the test suite")
    options = parser.parse_args()

    refuse_logging_in_the_key_path()
    target, version = deployment_target()

    if not options.no_check:
        print("==> Checks")
        run("swift", "run", "-c", "release", "check")

    architectures = {"universal": ["arm64", "x86_64"]}.get(options.arch, [options.arch])
    print(f"==> Compiling ({', '.join(architectures)})")
    binaries = compile(architectures, target)

    print(f"==> Assembling {APP.relative_to(ROOT)}")
    assemble(binaries)
    print(f"==> Signing ({sign(options.adhoc)})")

    if options.zip:
        archive = DIST / f"Alt-tab-{version}.zip"
        archive.unlink(missing_ok=True)
        # ditto, not zip: it is the only archiver that keeps the signature and the bundle's
        # symlinks intact, and a zipped app that will not launch looks like a broken build.
        run("ditto", "-c", "-k", "--keepParent", str(APP), str(archive))
        print(f"==> {archive.relative_to(ROOT)}")

    print(f"==> {APP.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
