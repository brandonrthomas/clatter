"""`clatter` console entry point — installs/uninstalls the bundled bash tool."""
import argparse
import os
import subprocess
import sys
from importlib.resources import files


def _assets() -> str:
    """Filesystem path to the bundled bash assets (scripts/, relay/, install.sh, ...)."""
    return str(files("clatter").joinpath("_assets"))


def main() -> None:
    p = argparse.ArgumentParser(
        prog="clatter",
        description="Clatter — real-time message bus for Claude Code sessions. "
        "https://github.com/brandonrthomas/clatter",
    )
    p.add_argument(
        "action",
        nargs="?",
        choices=["install", "uninstall", "version", "path"],
        help="install: deploy to ~/.claude/clatter (+ /clat command, hooks, services). "
        "uninstall: remove it. path: print the bundled asset dir. version: print version.",
    )
    a = p.parse_args()
    assets = _assets()

    if a.action == "install":
        raise SystemExit(subprocess.call(["bash", os.path.join(assets, "install.sh")]))
    if a.action == "uninstall":
        raise SystemExit(subprocess.call(["bash", os.path.join(assets, "uninstall.sh")]))
    if a.action == "path":
        print(assets)
        return
    if a.action == "version":
        from importlib.metadata import PackageNotFoundError, version
        try:
            print(version("clatter-bus"))
        except PackageNotFoundError:
            print("unknown")
        return
    p.print_help()


if __name__ == "__main__":
    main()
