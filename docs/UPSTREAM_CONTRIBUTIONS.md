# 自用版本与上游投稿

本 fork 的 `main` 用于自用构建，保留「书源管理 → 更多 → 在线书源」。上游 `Aminark/legado-ios` 不接受内置书源分享站入口，因此投稿分支 `contrib/reading-sources-and-backup` 不包含此功能。

## 分支范围

| 分支 | 内容 |
| --- | --- |
| `main` | 共用功能及修复，加上自用在线书源入口 |
| `contrib/reading-sources-and-backup` | PR #6：阅读体验、换源预览和备份恢复；保留用户自行导入书源的原有能力 |

在线书源、专用浏览页、网站导入适配及测试集中在 `feat(personal): retain online source catalogs in the fork` 提交中。投稿分支没有功能开关、隐藏入口或内置网站列表。

## 同步修复

共用功能的修复先在投稿分支提交，再将该提交 cherry-pick 到 `main`；避免将整个 `main` 合并回投稿分支，以免重新带入自用功能。提交继续附带 Codex 的 `Co-authored-by` 标记。

上游合并 PR 后，在 `main` 同步 `upstream/main`，检查在线书源相关文件、菜单与项目注册仍存在。若维护者重写提交造成删除或冲突，可从上述独立提交恢复自用功能。后续投稿从最新 `upstream/main` 新建贡献分支。

两个版本分别运行：

```sh
swift test --disable-sandbox
python3 -m unittest discover -s scripts/tests -v
```

再用 Xcode 的 `LegadoReaderTests` Scheme 编译并运行原生测试；自用版本包含 `OnlineSourceBrowserTests`，投稿版本不包含该浏览器及其测试。

PR #6 的代码和说明以投稿分支为准；自用版本的在线书源说明只保留在本 fork。
