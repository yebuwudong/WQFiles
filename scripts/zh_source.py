#!/usr/bin/env python3
"""汉化版：把上游 source.json（AltStore 源）改写成本仓库的发布信息。

用法: python3 scripts/zh_source.py <ipa 路径> ["更新说明"]
版本号与构建号从 IPA 的 Info.plist 读取，下载地址按当前 tag 生成。
"""
import datetime
import json
import os
import plistlib
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "source.json"
REPO = os.environ.get("GITHUB_REPOSITORY", "yebuwudong/WQFiles")
TAG = os.environ.get("WQ_TAG") or os.environ.get("GITHUB_REF_NAME", "zh-latest")
APP_PATH = "Payload/WQFiles.app"


def main() -> int:
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    ipa = Path(sys.argv[1])
    notes = sys.argv[2] if len(sys.argv) > 2 else ""
    with zipfile.ZipFile(ipa) as archive:
        with archive.open(f"{APP_PATH}/Info.plist") as handle:
            info = plistlib.load(handle)
    version = info["CFBundleShortVersionString"]
    build = info["CFBundleVersion"]
    download = f"https://github.com/{REPO}/releases/download/{TAG}/WQFiles-zh.ipa"

    source = json.loads(SOURCE.read_text(encoding="utf-8"))
    source["name"] = "WQ 文件（汉化）"
    source["identifier"] = "cz.kolbi.wqfiles.zh.source"
    source["subtitle"] = "iOS 26/27 文件管理器 · 汉化版"
    source["description"] = "WQ Files 汉化版，基于 kolbicz/WQFiles 自动构建。"
    source["website"] = f"https://github.com/{REPO}"
    app = source["apps"][0]
    app["name"] = "WQ 文件（汉化）"
    app["developerName"] = "kolbicz / 汉化：yebuwudong"
    app["subtitle"] = "iOS 26/27 文件管理器（worse_query）· 汉化版"
    app["localizedDescription"] = (
        "界面已汉化的 WQ Files：iOS 26/27 的文件浏览器、App 数据管理与缓存清理工具，"
        "基于 worse_query 沙盒技术，无需越狱。\n\n"
        "• 浏览每个 App 的数据容器、App 群组、扩展与守护进程容器\n"
        "• 属性列表编辑器与十六进制查看/编辑器，改动前先备份\n"
        "• 备份、还原、清除 App 数据，备份可打包成 ZIP 通过 AirDrop 分享\n"
        "• 缓存清理\n\n"
        "支持 iOS 26 与 27；iOS 26 上无法访问系统数据和系统群组。"
        "需要会保留 App Group 权限的签名工具。"
    )
    entry = {
        "version": version,
        "buildVersion": build,
        "date": datetime.date.today().isoformat(),
        "size": ipa.stat().st_size,
        "downloadURL": download,
        "localizedDescription": notes or f"汉化版 {version}（构建 {build}）。",
    }
    app["versions"] = [entry] + [v for v in app.get("versions", []) if v.get("version") != version]
    SOURCE.write_text(json.dumps(source, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"source.json -> {version} ({build}) {download}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
