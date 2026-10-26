"""Build a local toolkit package and optionally deploy it, retaining rollback outside Mods.

Native artifacts are built by PVPCore/scripts/build_{shared_loader,ccb_modcheck}.cmd.
No official game file, installed runtime or Workshop item is changed by this tool.
"""
from pathlib import Path
import argparse
import datetime as dt
import hashlib
import json
import shutil
import struct
import subprocess
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT.parents[1] / "A-C6-Mod/PVPCore"
MODINFO = "MultiplayerToolkits.modinfo"
MODS = Path.home() / "Documents/My Games/Sid Meier's Civilization VI/Mods"
TARGET = MODS / "CCB工具箱2.0"
BACKUPS = Path("D:/A-Developing/tmp/ccb-modcheck-rollback")


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require_x64(path):
    data = path.read_bytes()
    assert data[:2] == b"MZ", f"Not a PE: {path}"
    offset = struct.unpack_from("<I", data, 0x3C)[0]
    assert data[offset:offset+4] == b"PE\0\0"
    assert struct.unpack_from("<H", data, offset+4)[0] == 0x8664, path


def inventory(directory):
    return {p.relative_to(directory).as_posix(): sha(p)
            for p in directory.rglob("*") if p.is_file()}


def identical(expected, directory):
    actual = inventory(directory)
    missing = sorted(expected.keys()-actual.keys())
    extra = sorted(actual.keys()-expected.keys())
    changed = sorted(k for k in expected.keys() & actual.keys() if expected[k] != actual[k])
    assert not (missing or extra or changed), {"missing": missing, "extra": extra, "changed": changed}


def check_manifest():
    tree = ET.parse(ROOT/MODINFO).getroot()
    baseline_warnings = []
    def require_unchanged_baseline(path, value, error):
        current = subprocess.check_output(["git", "hash-object", str(path)], cwd=ROOT, text=True).strip()
        original = subprocess.check_output(["git", "rev-parse", "375e9cd:"+value], cwd=ROOT, text=True).strip()
        assert current == original, f"New/changed file fails validation: {value}: {error}"
        baseline_warnings.append({"file": value, "gitBlob": original, "parseError": str(error), "status": "unchanged pre-existing baseline"})
    paths = [n.text.strip() for n in tree.findall("./Files/File")]
    assert len(paths) == len(set(paths)), "Duplicate Files entries"
    declared = set(paths)
    for n in list(tree.findall("./FrontEndActions//File")) + list(tree.findall("./InGameActions//File")) + list(tree.findall(".//LuaReplace")):
        assert n.text.strip() in declared, f"Undeclared action file: {n.text}"
    for value in paths:
        rel = Path(value)
        assert not rel.is_absolute() and ".." not in rel.parts, value
        path = ROOT/rel
        assert path.is_file(), f"Missing source payload: {value}"
        if path.suffix in {".xml", ".sql", ".lua"}:
            if path.read_bytes().startswith(b"\xef\xbb\xbf"):
                require_unchanged_baseline(path, value, "UTF-8 BOM in existing upstream module")
        if path.suffix == ".xml":
            try:
                ET.parse(path)
            except ET.ParseError as error:
                # Preserve accepted upstream modules. A legacy parse defect is only
                # allowed when Git proves it is byte-content-identical to the pinned
                # pre-MOD-Check baseline. New/changed XML must always parse.
                require_unchanged_baseline(path, value, error)
    return tree, paths, baseline_warnings


def game_not_running():
    check = subprocess.run(["powershell.exe", "-NoProfile", "-Command",
        "@(Get-Process CivilizationVI* -ErrorAction SilentlyContinue).Count"],
        capture_output=True, text=True, check=True)
    assert check.stdout.strip() == "0", "Close Civilization VI before replacing the local mod."


def matching_guids(guid):
    found = []
    for path in MODS.rglob("*.modinfo"):
        try:
            if ET.parse(path).getroot().get("id", "").lower() == guid.lower():
                found.append(path)
        except ET.ParseError:
            continue
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--deploy", action="store_true")
    args = parser.parse_args()
    if args.deploy:
        game_not_running()
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    source_tree = ET.parse(ROOT/MODINFO).getroot()
    version = source_tree.findtext("./Properties/CCBDisplayVersion")
    mod_version = int(source_tree.get("version"))
    assert version and mod_version >= 201
    (ROOT/"MPH/ModCheck/CCBModCheckVersion.lua").write_text(
        "-- Generated from MultiplayerToolkits.modinfo by tools/package_modcheck.py.\n"
        f'CCBModCheckVersion={{display="工具箱 {version}",modVersion={mod_version},apiVersion=1,coverage="ccb-code-v1",workshopId=nil}};\n', encoding="utf-8")
    artifacts = {
        "Binaries/Win64/GameCore_XP2_Shell_FinalRelease.dll": NATIVE/"build/shared_loader/GameCore_XP2_Shell_FinalRelease.dll",
        "Binaries/Win64/Civ6DllLoader.runtime.dll": NATIVE/"build/shared_loader/Civ6DllLoader.runtime.dll",
        "Binaries/Win64/Plugins/Global/CCBModCheck.dll": NATIVE/"build/ccb_modcheck/CCBModCheck.dll",
    }
    for relative, source in artifacts.items():
        assert source.is_file(), f"Build native artifact first: {source}"
        require_x64(source)
        target = ROOT/relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        assert sha(source) == sha(target)
    tree, paths, baseline_warnings = check_manifest()
    stage = ROOT/"torelease/CCB工具箱2.0"
    stage.parent.mkdir(parents=True, exist_ok=True)
    if stage.exists():
        backup = BACKUPS/(stamp+"-previous-staging")
        backup.parent.mkdir(parents=True, exist_ok=True)
        assert stage.resolve().parent == (ROOT/"torelease").resolve()
        assert backup.resolve().is_relative_to(BACKUPS.resolve())
        shutil.move(str(stage), str(backup))
    stage.mkdir()
    for value in paths+[MODINFO]:
        target = stage/value
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT/value, target)
        assert sha(ROOT/value) == sha(target), value
    payload = inventory(stage)
    archive = ROOT/"release"/f"CCBToolkits_{version}_{stamp}.zip"
    archive.parent.mkdir(exist_ok=True)
    assert not archive.exists()
    with zipfile.ZipFile(archive, "x", zipfile.ZIP_DEFLATED) as z:
        for relative in payload:
            z.write(stage/relative, "CCB工具箱2.0/"+relative)
    with zipfile.ZipFile(archive, "r") as z:
        assert len(z.infolist()) == len(payload)
        for relative, expected in payload.items():
            assert hashlib.sha256(z.read("CCB工具箱2.0/"+relative)).hexdigest() == expected, relative
    report = {
        "schema": 1, "builtAt": stamp, "version": version, "modVersion": mod_version,
        "guid": tree.get("id"), "source": str(ROOT), "stage": str(stage),
        "archive": str(archive), "archiveSHA256": sha(archive),
        "publicLoaderSource": "52ce9bfbc532f2b48c1f576ff30d80cc27ad0426",
        "publicRedistribution": "pending authorization; local development only",
        "binaries": {k: sha(v) for k, v in artifacts.items()},
        "baselineWarnings": baseline_warnings,
        "payload": payload, "sourceStageArchiveHashCheck": "PASS", "deployed": False,
        "acceptance": {"gameLoad": "PENDING", "DX11": "PENDING", "DX12": "PENDING", "independentMultiplayer": "PENDING", "migratedPluginsCombination": "PENDING"},
    }
    if args.deploy:
        guid = tree.get("id")
        others = [p for p in matching_guids(guid) if TARGET.resolve() not in p.resolve().parents]
        assert not others, f"Duplicate GUID outside target, move old copies first: {others}"
        if TARGET.exists():
            old = BACKUPS/(stamp+"-local-mod")
            old.parent.mkdir(parents=True, exist_ok=True)
            # Explicit absolute containment check before moving a complete tree.
            assert TARGET.resolve().parent == MODS.resolve()
            assert old.resolve().is_relative_to(BACKUPS.resolve())
            shutil.move(str(TARGET), str(old))
            report["rollback"] = str(old)
        try:
            shutil.copytree(stage, TARGET)
            identical(payload, TARGET)
        except Exception:
            # Keep the failed candidate outside Mods, then restore the previous local package.
            failed = BACKUPS/(stamp+"-failed-candidate")
            assert TARGET.resolve().parent == MODS.resolve()
            assert failed.resolve().is_relative_to(BACKUPS.resolve())
            if TARGET.exists():
                failed.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(TARGET), str(failed))
            if report.get("rollback"):
                shutil.copytree(Path(report["rollback"]), TARGET)
            raise
        assert len(matching_guids(guid)) == 1, "Expected a single deployed toolkit GUID"
        report.update(deployed=True, target=str(TARGET), sourceStageArchiveDeployHashCheck="PASS", matchingGuidCount=1)
    out = ROOT/"build"/f"modcheck-delivery-{stamp}.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({k: v for k, v in report.items() if k != "payload"}, ensure_ascii=False, indent=2))
    print(f"Payload files: {len(payload)}; full report: {out}")


if __name__ == "__main__":
    main()
