# FTV (OK 影视风格) 跨平台客户端

本项目参考 **OK 影视 (FongMi TV)** 架构重构，专注于 **FongMi 原生 JS 爬虫源** 高性能执行，支持 Windows、Linux、Android TV、手机与 iOS 多端统一体验。

---

## 一、核心功能与架构亮点

### 1. 模块化组件架构
- **三大顶级导航**：底部主导航保留 **点播**、**直播**、**设置**，顶部保留全网并发搜索与推送解析入口。
- **页面组件拆分**：
  - `lib/views/detail/`：主播放页与 `widgets/`（跑马灯 `marquee_widget.dart`、剧集弹窗 `episode_list_sheet.dart`、弹幕弹窗 `danmaku_dialogs.dart`、轨道/投屏弹窗 `player_track_dialogs.dart`、播放设置 `player_settings_dialog.dart`、字幕样式弹窗 `subtitle_settings_dialog.dart`、详情信息区 `detail_info_sections.dart`）。
  - `lib/views/vod/`：点播主页与 `widgets/`（点播卡片 `vod_card.dart`、推送弹窗 `vod_push_dialog.dart`、收藏与历史弹窗 `vod_records_sheets.dart`）。
  - `lib/views/search/`：全网搜索页与 `widgets/`（结果卡片 `search_result_card.dart`、历史建议 `search_suggestions_view.dart`）。
  - `lib/views/settings/`：设置主页及独立子页 `playback_settings_page.dart`、`personal_settings_page.dart`、`backup_restore_page.dart`。

### 2. 本地 JS 源包与多端配置管理
- **跨平台本地导入**：支持 Android 原生 SAF 文件/目录选择器（自动解析 `/storage/emulated/0/...` 绝对路径并引导授权 `MANAGE_EXTERNAL_STORAGE`）与 Windows 本地目录直连，支持 `clan://localhost/` 相对路径解析与 ZIP 离线包。
- **容错 JSON 解析**：内置宽松容错解析器，自动处理 BOM 头、注释、尾部多余逗号、JSON5 单引号及 Base64 / `**<base64>` 编码。
- **JS 站源严格筛选**：自动过滤 `csp_`（Jar 源）与 `.py` 源，仅加载原生 JS 源。
- **推送源优先初始化**：启动与重载配置时优先等待 `push_agent` 完成 `init`（同步网盘 Cookie 与配置至本地存储），再激活默认点播站点。
- **Logo 长按重载**：点播页左上角 Logo 长按可一键清空缓存并重新加载当前配置。

### 3. 全网并发秒搜（流式增量加载）
- **滑动并发池**：采用 4 路滑动窗口并发搜索，任意站源完成后立即增量追加至结果网格与左侧站源过滤栏，搜索初始为空态，不阻塞快站结果展示。
- **并发隔离**：搜索过程中点击任意结果进入详情或播放，与后台继续进行的搜索互不干扰。

### 4. 播放器、字幕样式与断点续播
- **直连与请求头注入**：播放直连地址自动注入 `header`（`User-Agent`、`Referer`、`Cookie` 等）。
- **加载与快进缓冲指示**：初始加载及快进/拖拽跳转缓冲时，播放器中央实时显示旋转加载动画与实时网速（`demuxer-cache-speed`）。
- **全手势控制（隐藏控件同样生效）**：左侧上下滑调亮度、右侧上下滑调音量、水平滑动快进/快退，长按倍速播放。
- **片头 / 片尾跳过**：按视频维度持久化（同剧不同集共享），底部胶囊按钮支持**单击直接设点**、**长按直接重置**。
- **历史与收藏精确续播**：自动保存 `siteKey`、`siteName`、线路 `sourceName`、剧集名与播放进度（播放中每 5 秒自动持久化），从历史记录重播时自动还原对应站源、线路、剧集并跳转至上次进度。
- **播放器内错误提示**：`detail` / `play` 返回的 `msg` 提示直接居中显示于播放器画面区（白色警告三角图标）。
- **字幕样式设置（`SubtitleConfig`）**：
  - 默认透明无背景 + 黑色清晰描边阴影、增大默认字号。
  - 在 **选择字幕 → 字幕样式** 或 **播放器设置 → 字幕样式设置** 中支持实时预览与持久化调节：**字体大小、底部位置、透明度、字幕颜色、半透明背景框开关**。

### 5. LogVar 弹幕系统
- **默认不描边与可配样式**：弹幕字体默认不描边（常规字重），支持在弹幕设置中自由切换**描边 / 不描边**、字号、透明度、速度、显示区域与时间偏移。
- **弹幕搜索面板优化**：支持弹幕源折叠/展开、跑马灯完整显示剧集标题、默认高亮匹配当前播放剧集、缓存上次搜索的弹幕源与剧集列表（再次打开直接保留），关闭弹窗后异步拉取的弹幕仍正常推送。

### 6. 沉浸式电视直播与 TV 焦点
- **多分组多线路直播 (`LiveView`)**：支持频道抽屉、OSD 换台指示与多线路容错切换。
- **遥控器焦点 (`TvFocusable`)**：方向键导航金琥珀发光边框与平滑居中滚动，主界面连续两次返回防误触退出。

---

## 二、覆盖部署步骤

1. 下载补丁压缩包 `ftv_local_config_patch.zip`（包含完整的 `android/`、`lib/` 与 `README.md`）。
2. 将压缩包解压并覆盖到项目根目录 `D:\code\ftv\`。
3. 在终端中执行：
   ```bash
   flutter pub get
   flutter run
   ```
