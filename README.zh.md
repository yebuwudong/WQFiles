# WQ 文件（汉化版）

这是 [kolbicz/WQFiles](https://github.com/kolbicz/WQFiles) 的汉化分支：在保持功能完全一致的前提下，
把界面文案翻译成简体中文。

## 下载

- 最新汉化 IPA：[Releases → `zh-latest`](https://github.com/yebuwudong/WQFiles/releases/tag/zh-latest)
- AltStore / SideStore 源：`https://raw.githubusercontent.com/yebuwudong/WQFiles/main/source.json`

> 需要 iOS 26.0 – 26.7.2 或 iOS 27（与上游一致）。
> 签名工具必须保留 **App Group** 权限；若 App 内「日志」显示 *No App Group*，请换一个会保留 App Group 的签名工具后重新签名。

## 汉化了什么

- 全部界面文字：导航标题、按钮、列表、单元格副标题、占位提示、空状态。
- 全部弹窗与警告：标题、正文、按钮，以及备份/还原/清除/清理流程的说明与结果。
- 各工具：文件浏览器、属性列表编辑器、十六进制查看/编辑器、App 数据管理、缓存清理、分享与 ZIP 打包。
- 「日志」界面的**界面部分**仍是日志本体，保持原文，方便对照上游排查问题。

刻意**没有**翻译的内容（改动会破坏数据或上游兼容性）：

| 内容 | 原因 |
| --- | --- |
| 备份清单里的键（`Complete`、`State`、`Sequence` 等） | 写入磁盘的备份格式，改了就与旧备份不兼容 |
| 内部日志（`wq_log`）、谓词（`selected == YES`）、日期格式 | 不是界面文案 | |
| 系统 App 名称表 | 已本地化：常见 Apple 服务改成苹果官方中文名（天气、信息、备忘录…） |
| 磁盘上的目录名（`Backups`、`AppBackups`、`Library/Caches` 等） | 用来比较/拼接真实路径，翻译会直接导致逻辑失效 |

## 汉化是怎么做的

- `i18n/zh.txt`：一张「英文原文 ⇥ 中文译文」的表（tab 分隔，共 500+ 条）。
- `scripts/zh_apply.py`：按表替换源码里的界面字符串字面量；会跳过注释与日志调用，并校验
  `%@`/`%lu` 等格式符数量一一对应。脚本幂等，可重复运行。

```bash
python3 scripts/zh_apply.py           # 套用 i18n/zh.txt
python3 scripts/zh_apply.py --check   # 只报告还没译的界面字符串
```

上游代码更新后，先同步上游，再跑一次 `--check`：新出现的英文界面字符串会被列出来，
补进 `i18n/zh.txt` 后重新运行即可。

## 自动构建与同步

- `Build 汉化版 IPA`：在 macOS 26 运行器上跑完上游的回归测试，然后用上游的 `build.sh`
  打出 IPA，发布到 `zh-latest` 这个 Release，并刷新 AltStore 源 `source.json`。
- `Sync upstream`：每天自动合并 `kolbicz/WQFiles` 的 `main`；合并成功后触发一次构建。
  如果出现冲突，会自动停在冲突状态并以失败告终，需要人工处理（通常只需重跑汉化脚本）。

## 许可

与原项目一致：GPL-3.0-or-later。原始代码与设计版权归 kolbicz 所有。
