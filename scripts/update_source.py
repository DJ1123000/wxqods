#!/usr/bin/env python3
"""Add a release to source.json (the AltStore / SideStore source).

Usage: scripts/update_source.py <version> <build> <path/to/WQFiles.ipa> ["what's new"]

The new version goes first (AltStore treats the first entry as the latest).
An existing entry for the same version is replaced, so re-uploading an IPA to
a release just refreshes its size and date.  The version and build arguments
are retained for compatibility, but must match the embedded IPA metadata.
"""
import datetime
import json
import os
import plistlib
import stat
import sys
import tempfile
import zipfile
from pathlib import Path
from typing import Any, Dict, Tuple

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "source.json")
EXPECTED_APP_PATH = "Payload/WQFiles.app"
EXPECTED_INFO_PATH = f"{EXPECTED_APP_PATH}/Info.plist"
EXPECTED_EXECUTABLE_PATH = f"{EXPECTED_APP_PATH}/WQFiles"
MINIMUM_IOS_VERSION = "26.0"


def _version_tuple(value: str) -> Tuple[int, ...]:
    parts = value.split(".")
    if not parts or any(not part.isdigit() for part in parts):
        raise ValueError(f"invalid iOS version {value!r}")
    return tuple(int(part) for part in parts)


def _regular_zip_member(info: zipfile.ZipInfo, path: str) -> None:
    if info.is_dir():
        raise ValueError(f"IPA member is a directory, not a file: {path}")
    mode = (info.external_attr >> 16) & 0o170000
    if mode == stat.S_IFLNK:
        raise ValueError(f"IPA member must not be a symlink: {path}")
    if mode not in (0, stat.S_IFREG):
        raise ValueError(f"IPA member is not a regular file: {path}")


def _member(zf: zipfile.ZipFile, path: str) -> zipfile.ZipInfo:
    matches = [info for info in zf.infolist() if info.filename == path]
    if len(matches) != 1:
        raise ValueError(f"IPA must contain exactly one {path}")
    info = matches[0]
    _regular_zip_member(info, path)
    return info


def read_ipa_metadata(ipa: os.PathLike[str] | str) -> Dict[str, str]:
    """Validate the release app in *ipa* and return its embedded metadata."""
    ipa_path = Path(ipa)
    try:
        mode = ipa_path.stat().st_mode
    except OSError as exc:
        raise ValueError(f"cannot stat IPA {ipa_path}: {exc}") from exc
    if not stat.S_ISREG(mode):
        raise ValueError(f"IPA is not a regular file: {ipa_path}")

    try:
        with zipfile.ZipFile(ipa_path) as zf:
            info_member = _member(zf, EXPECTED_INFO_PATH)
            executable_member = _member(zf, EXPECTED_EXECUTABLE_PATH)
            if info_member.file_size > 1024 * 1024:
                raise ValueError("embedded Info.plist is unreasonably large")
            if executable_member.file_size == 0:
                raise ValueError("IPA executable is empty")
            try:
                info = plistlib.loads(zf.read(info_member))
            except Exception as exc:
                raise ValueError(f"invalid embedded Info.plist: {exc}") from exc
    except zipfile.BadZipFile as exc:
        raise ValueError(f"invalid IPA ZIP: {exc}") from exc

    if not isinstance(info, dict):
        raise ValueError("embedded Info.plist is not a dictionary")

    required = (
        "CFBundleIdentifier",
        "CFBundleShortVersionString",
        "CFBundleVersion",
        "CFBundleExecutable",
        "MinimumOSVersion",
    )
    missing = [key for key in required if not isinstance(info.get(key), str) or not info[key]]
    if missing:
        raise ValueError(f"embedded Info.plist is missing string metadata: {', '.join(missing)}")
    if info["CFBundleExecutable"] != "WQFiles":
        raise ValueError("embedded executable is not WQFiles")

    minimum_os = info["MinimumOSVersion"]
    if _version_tuple(minimum_os) < _version_tuple(MINIMUM_IOS_VERSION):
        raise ValueError(
            f"IPA minimum OS {minimum_os} is below the documented iOS {MINIMUM_IOS_VERSION} policy"
        )
    return {
        "bundle_identifier": info["CFBundleIdentifier"],
        "version": info["CFBundleShortVersionString"],
        "build": info["CFBundleVersion"],
        "minimum_os": minimum_os,
    }


def _load_source(source_path: os.PathLike[str] | str) -> Dict[str, Any]:
    try:
        with open(source_path, encoding="utf-8") as source_file:
            source = json.load(source_file)
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"cannot read catalog {source_path}: {exc}") from exc
    try:
        app = source["apps"][0]
        bundle_identifier = app["bundleIdentifier"]
        versions = app["versions"]
    except (KeyError, IndexError, TypeError) as exc:
        raise ValueError("catalog has no usable first app entry") from exc
    if not isinstance(bundle_identifier, str) or not isinstance(versions, list):
        raise ValueError("catalog app entry has invalid bundleIdentifier or versions")
    return source


def _write_source_atomically(source_path: os.PathLike[str] | str, source: Dict[str, Any]) -> None:
    """Write JSON to a sibling, fsync it, then atomically replace the catalog."""
    path = os.path.abspath(os.fspath(source_path))
    directory = os.path.dirname(path) or "."
    basename = os.path.basename(path)
    old_mode = None
    try:
        old_mode = stat.S_IMODE(os.stat(path).st_mode)
    except FileNotFoundError:
        pass

    fd, temporary = tempfile.mkstemp(prefix=f".{basename}.", suffix=".tmp", dir=directory)
    try:
        if old_mode is not None:
            os.chmod(temporary, old_mode)
        with os.fdopen(fd, "w", encoding="utf-8") as source_file:
            json.dump(source, source_file, indent=2, ensure_ascii=False)
            source_file.write("\n")
            source_file.flush()
            os.fsync(source_file.fileno())
        fd = -1

        # Opening the directory before replacement makes the replacement and
        # directory durability step part of one controlled operation.
        directory_fd = os.open(directory, os.O_RDONLY)
        try:
            os.replace(temporary, path)
            temporary = ""
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except Exception:
        if fd >= 0:
            os.close(fd)
        if temporary:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
        raise


def update_catalog(
    source_path: os.PathLike[str] | str,
    version: str,
    build: str,
    ipa: os.PathLike[str] | str,
    notes: str = "",
) -> Dict[str, str]:
    """Validate *ipa*, update *source_path*, and return the published entry."""
    if not version or not build:
        raise ValueError("version and build must not be empty")
    source = _load_source(source_path)
    app = source["apps"][0]
    artifact = read_ipa_metadata(ipa)
    if artifact["bundle_identifier"] != app["bundleIdentifier"]:
        raise ValueError(
            "IPA bundle identifier does not match the catalog: "
            f"{artifact['bundle_identifier']} != {app['bundleIdentifier']}"
        )
    if artifact["version"] != version:
        raise ValueError(
            f"IPA version does not match the requested version: {artifact['version']} != {version}"
        )
    if artifact["build"] != build:
        raise ValueError(
            f"IPA build does not match the requested build: {artifact['build']} != {build}"
        )

    existing = next((v for v in app["versions"]
                     if isinstance(v, dict) and v.get("version") == version), None)
    if not notes and isinstance(existing, dict):
        old_notes = existing.get("localizedDescription")
        if isinstance(old_notes, str):
            notes = old_notes
    entry = {
        "version": artifact["version"],
        "buildVersion": artifact["build"],
        "date": datetime.date.today().isoformat(),
        "size": os.path.getsize(ipa),
        "downloadURL": f"https://github.com/kolbicz/WQFiles/releases/download/v{artifact['version']}/WQFiles.ipa",
        "localizedDescription": notes,
        # This is deliberately taken from the IPA, never from the old entry.
        "minOSVersion": artifact["minimum_os"],
    }
    app["versions"] = [entry] + [v for v in app["versions"]
                                 if not (isinstance(v, dict) and v.get("version") == version)]
    _write_source_atomically(source_path, source)
    return entry


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if len(args) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    version, build, ipa = args[:3]
    notes = args[3] if len(args) > 3 else ""
    try:
        entry = update_catalog(SOURCE, version, build, ipa, notes)
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(f"source.json: {entry['version']} ({entry['buildVersion']}), {entry['size']} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
