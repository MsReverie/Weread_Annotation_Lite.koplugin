# Weread Annotation Lite

独立的 KOReader 插件：在本地 EPUB/TXT 等可重排文档上显示微信读书热门划线和想法。支持章节预取、离线缓存和扫码登录。

轻量、只读。不打开、不下载微信读书在线书籍。划线按章节窗口预取，想法按需或后台批量拉取，兼顾阅读流畅度的同时解决API超限问题，

当前版本：`0.1.0`  
插件目录：`wereadannotationlite.koplugin`  
插件名：`wereadannotationlite`

---

## 基于 (Based on)

在以下两个项目上二次开发：

- **[weread.koplugin](https://github.com/finlater/weread.koplugin)**
- **[pickthought.koplugin](https://github.com/Mr54233/pickthought.koplugin)**

结合二者优势，重构了同步与 UI：模块扁平为 `{main.lua, settings.lua, lib/, ui/}`。

---

## 主要功能

- **只读**：只拉划线和想法，不打开/下载微信读书在线书。
- **本地匹配**：按文件名搜索微信读书书库，绑定本地书与线上书。
- **热门划线**：按章节拉取热门划线，定位到本地文档对应位置。
- **划线覆盖层**：划线与想法单独存 SQLite，不改本地书；阅读页虚线高亮，点击查看想法。
- **想法按需加载**：点击未缓存划线时即时拉取该条想法。
- **智能预取**：自动预取当前章节及后续若干章的划线，再按批次预取想法；结果写入本地库，可离线阅读。
- **离线缓存**：划线、想法、章节目录持久化，再次打开同一本书直接加载。
- **可中断**：预取可取消；再次启动从中断处继续，已缓存内容不重复拉。
- **QR 扫码登录**：生成二维码，微信读书 App 扫码后自动写入官方 API Key。文件管理器和阅读器里都能打开登录（`is_doc_only = false`）。

---

## 安装

1. 将 `wereadannotationlite.koplugin` 复制到 KOReader 的 `plugins` 目录。
2. 重启 KOReader。工具菜单中会出现 **Weread Annotation Lite**。

---

## 使用

### 1. 登录

- 工具菜单 → **Weread QR login**（文件管理器或阅读器均可）。
- 微信读书 App 扫码确认。
- 登录成功后自动保存官方 API Key，无需手填。

### 2. 匹配并拉取划线

- 打开一本本地可重排书籍（EPUB / TXT / FB2 / HTML 等）。
- 工具菜单 → **Fetch underlines**。
- 未绑定时弹出搜索框（预填文件名），搜索并选择对应的微信读书书籍。
- 绑定后从当前章（首次绑定则从第一章）开始拉取划线。

### 3. 查看想法

- 点击划线区域打开底部想法弹窗。
- 上下滑动翻看；左右滑动或点弹窗外部关闭。

### 4. 自动预取

- 菜单中 **Auto prefetch underlines and thoughts** 默认开启。
- 打开已绑定的书后，后台预取当前章及后续章节的划线和想法。
- 翻章时若下一窗口尚未缓存，会继续预取。
- 批次大小、延迟、划线窗口、冷却时间目前需改设置文件（见下方）。

---

## 菜单

| 选项 | 作用 |
|------|------|
| **Enable underlines and thoughts** | 全局开关。关闭后隐藏划线/想法，并取消预取。 |
| **Fetch underlines** | 手动拉取。未绑定则先匹配；已绑定则从当前章强制刷新窗口。 |
| **Auto prefetch underlines and thoughts** | 自动预取划线与想法（默认开）。 |
| **Show prefetch notifications** | 预取进度提示（默认关）。 |
| **Weread QR login** | 扫码登录或换账号。 |
| **Clear current book data** | 删除当前书的本地库（绑定、划线、想法、章节）。 |

阅读器未打开文档时，登录仍可用；清除数据和拉取划线需要先打开书。

---

## 数据存储

- **数据库**：`koreader/data/WereadAnnotationLite/`  
  每本书一个 `.db`，文件名为书籍完整路径 SHA256 的前 16 位十六进制。
- **设置**：`koreader/settings/wereadannotationlite.lua`  
  保存 `api_key`、`account` 和偏好。登录过程中的 Cookie 只用于扫码，**不会写入设置文件**。
- **缓存**：热门划线按章节缓存（含 synckey）；想法按划线 range 缓存。

默认偏好（未写入设置文件时生效）：

| 键 | 默认 | 含义 |
|----|------|------|
| `prefetch_thoughts` | `true` | 自动预取 |
| `prefetch_notify` | `false` | 预取提示 |
| `prefetch_batch_size` | `5` | 每批想法条数 |
| `prefetch_batch_delay` | `0.3` | 批次间隔（秒） |
| `prefetch_underline_window` | `5` | 一次预取的章节窗口 |
| `prefetch_underline_cooldown` | `30` | 划线预取冷却（秒） |
| `debug_log` | `false` | 调试日志 |

---

## 注意

- **格式**：仅 CREngine 可重排文档（EPUB、FB2、TXT、HTML 等）。不支持 PDF / DJVU 等固定布局。
- **网络**：登录、匹配、首次拉取需要联网；缓存后可离线看已有划线和想法。
- **账号**：API Key 只存在本机，插件不上传个人数据。

---

## 许可

GPLv3。欢迎贡献、提 Issue 或 Fork。

感谢 [@finlater](https://github.com/finlater)、[@Mr54233](https://github.com/Mr54233) 和 KOReader 社区。
