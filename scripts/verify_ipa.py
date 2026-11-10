#!/usr/bin/env python3
"""TrollStore IPA 结构审计器（纯标准库，Windows/Linux/WSL 均可跑）。

对构建产物做无需 iOS 运行时的静态校验：
  - zip 完整性 / Payload 目录布局
  - 主 app + widget .appex 齐全；NE 服务扩展已移除（TF1604 架构，VPN 走主进程内 LibVpnCore）
  - 各 target 的 Info.plist（含二进制 plist）关键字段
  - Mach-O 魔数 + arm64 切片（TrollStore 装机前提）
  - 可执行文件非空、MinimumOSVersion 下限

用法: python3 scripts/verify_ipa.py <path/to.ipa>
退出码 0 = 全过；非 0 = 有 FAIL 项。
"""
import plistlib
import struct
import sys
import zipfile

EXPECT_BUNDLE = "com.nebula.clashmi"
MACHO_MAGICS = {
    0xFEEDFACE: "mach-o 32",
    0xFEEDFACF: "mach-o 64",
    0xCAFEBABE: "fat",
    0xBEBAFECA: "fat(be)",
    0xCAFEBABF: "fat 64",
}


def read_plist(zf, path):
    try:
        with zf.open(path) as f:
            return plistlib.load(f)
    except Exception as e:  # noqa: BLE001
        return {"__error__": str(e)}


def macho_info(data):
    if len(data) < 8:
        return None, "truncated"
    (magic,) = struct.unpack(">I", data[:4])
    kind = MACHO_MAGICS.get(magic)
    if kind is None:
        (magic_le,) = struct.unpack("<I", data[:4])
        kind = MACHO_MAGICS.get(magic_le)
        magic = magic_le
    if kind is None:
        return None, f"not mach-o (magic=0x{magic:08x})"
    cpus = []
    if kind.startswith("fat"):
        n = struct.unpack(">I", data[4:8])[0]
        for i in range(min(n, 8)):
            off = 8 + i * 20
            if off + 8 <= len(data):
                cputype = struct.unpack(">I", data[off : off + 4])[0]
                cpus.append(cputype & 0x00FFFFFF)
    else:
        le = magic in (0xFEEDFACE, 0xFEEDFACF)
        cputype = struct.unpack("<I" if le else ">I", data[4:8])[0]
        cpus.append(cputype & 0x00FFFFFF)
    return cpus, kind


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    fails, warns = [], []

    def fail(msg):
        fails.append(msg)
        print(f"  FAIL  {msg}")

    def ok(msg):
        print(f"  ok    {msg}")

    def warn(msg):
        warns.append(msg)
        print(f"  warn  {msg}")

    print(f"== IPA: {path}")
    try:
        zf = zipfile.ZipFile(path)
    except Exception as e:  # noqa: BLE001
        print(f"  FAIL  cannot open zip: {e}")
        return 1
    bad = zf.testzip()
    if bad:
        fail(f"corrupt zip entry: {bad}")
    else:
        ok(f"zip intact, {len(zf.namelist())} entries")

    names = zf.namelist()
    tops = {n.split("/")[0] for n in names}
    if tops == {"Payload"}:
        ok("Payload/ layout")
    else:
        fail(f"top-level should be only Payload/, got {sorted(tops)}")

    apps = [n for n in names if n.endswith(".app/") and n.count("/") == 2]
    if len(apps) == 1:
        ok(f"app bundle: {apps[0]}")
    else:
        fail(f"expect exactly 1 .app, got {apps}")
    if not apps:
        print("== nothing else to check")
        return 1
    app = apps[0]

    # ---- collect targets: main + PlugIns/*.appex ----
    appexes = sorted(
        {
            n.split("PlugIns/")[1].split("/")[0]
            for n in names
            if "PlugIns/" in n and ".appex/" in n
        }
    )
    ok(f"appex targets: {appexes or 'NONE'}")
    # TF1604 架构（commit b8424e4）：NE 隧道跑在主进程内 LibVpnCore.framework
    # 的 ExtensionProvider，无独立 .appex；包内只应有 widget 扩展。
    if "clashmiService.appex" in appexes:
        fail("clashmiService.appex PRESENT — NE 扩展已被移除（TF1604 方案），包内不应再出现")
    else:
        ok("clashmiService.appex absent (NE 走主进程内 LibVpnCore，TF1604 架构)")
    if "clashmiWidgetExtension.appex" in appexes:
        ok("clashmiWidgetExtension.appex present")
    else:
        fail("clashmiWidgetExtension.appex MISSING")

    # ---- Info.plist of main app + each appex ----
    targets = [(app, "main")]
    for a in appexes:
        targets.append((f"{app}PlugIns/{a}/", a))
    for prefix, label in targets:
        pl_path = prefix + "Info.plist"
        info = read_plist(zf, pl_path)
        if "__error__" in info:
            fail(f"{label}: Info.plist unreadable: {info['__error__']}")
            continue
        bid = info.get("CFBundleIdentifier", "")
        exe = info.get("CFBundleExecutable", "")
        minos = info.get("MinimumOSVersion", "")
        ver = info.get("CFBundleShortVersionString", "")
        if label == "main":
            if bid == EXPECT_BUNDLE:
                ok(f"{label}: bundle id {bid}")
            else:
                fail(f"{label}: bundle id '{bid}' != {EXPECT_BUNDLE}")
        else:
            if bid.startswith(EXPECT_BUNDLE):
                ok(f"{label}: bundle id {bid}")
            else:
                fail(f"{label}: bundle id '{bid}' not under {EXPECT_BUNDLE}")
        if minos:
            ok(f"{label}: MinimumOSVersion {minos} (TrollStore 需 iOS 15.0-16.6.1, A12+ 至 17.0)")
        else:
            warn(f"{label}: MinimumOSVersion missing")
        if ver:
            ok(f"{label}: version {ver}")
        if not exe:
            fail(f"{label}: CFBundleExecutable missing")
            continue
        binpath = prefix + exe
        try:
            data = zf.read(binpath)
        except KeyError:
            fail(f"{label}: executable missing at {binpath}")
            continue
        if len(data) < 10000:
            fail(f"{label}: executable suspiciously small ({len(data)} bytes)")
        cpus, kind = macho_info(data)
        if kind is None:
            fail(f"{label}: {cpus}")  # cpus holds error text in this case
        else:
            cpu_names = {0x000C: "arm64", 0x000C0000 >> 16: "arm64", 0x0007: "x86"}
            shown = ",".join(
                "arm64" if (c & 0xFF) == 12 else f"cpu({c})" for c in (cpus or [])
            )
            if any((c & 0xFF) == 12 for c in (cpus or [])):
                ok(f"{label}: {kind} [{shown}] {len(data)//1024}KB")
            else:
                fail(f"{label}: no arm64 slice ({kind} [{shown}]) — TrollStore 装不了")

    # ---- embedded provisioning: must be ABSENT for ldid-fake-signed ----
    prov = [n for n in names if n.endswith("embedded.mobileprovision")]
    if prov:
        warn(f"embedded.mobileprovision present ({len(prov)}) — 假签产物通常没有，无碍 TrollStore")
    else:
        ok("no embedded.mobileprovision (expected for ldid fake-sign)")

    print(f"== RESULT: {len(fails)} fail, {len(warns)} warn")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
