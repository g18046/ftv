# FTV 影视 JS Spider 与配置开发文档

本文档是面向 FTV 影视生态及 JS Spider 开发者的精简核心开发指南。去除了复杂的 DOM 解析、加解密函数、jar/py 扩展以及点播解析器（parses）相关说明，仅保留 FTV 影视能用的基础知识说明、JS 相关运行时规范、配置结构、字段参数说明、数据返回结构与示例以及本地 API 说明。

## 一、 核心基础知识说明

1. **`push_agent` 站点**：key 为 `push_agent` 的站点负责处理点播页的推送播放逻辑。

2. **文件夹跳转（`folder`）**：

   * 分类函数中的 `vod_tag`（或 `vod_type`）为 `"folder"` 时，点击卡片不进入详情页，而是重复调用分类函数并展示新的列表信息。

   * 搜索结果中的 `vod_tag` 为 `"folder"` 时，点击打开新一页展示列表，且支持返回退回到搜索列表页。

3. **搜索与快速搜索**：

   * 支持并发搜索多站点，同时也支持指定特定站点进行搜索。

   * 搜索方法签名统一使用：`search(key, quick, pg)`。

   * 在详情页长按 `vod_name`（影片名称）处可触发快速搜索，相关内容会展示在详情页描述下方的卡片区域。

## 二、 顶层配置 (JSON) 与站点配置说明

FTV 影视的点播配置通常为 JSON 格式，**本项目仅支持 JS 类型的 Spider 扩展，不支持 Jar 及 Python，同时不支持全局 spider 字段与点播解析器（parses）**。

### 1. 顶层配置结构

| 字段 | 类型 | 说明 | 
| ----- | ----- | ----- | 
| `sites` | array | 点播站点列表配置 | 
| `lives` | array | 直播配置列表 | 
| `home` | string | 默认选中的站点 key | 
| `wallpaper` | string | 壁纸配置 URL 或路径 | 
| `msg` | string | 错误消息提示 | 

### 2. 站点配置 (`sites` 元素)

`type` 字段默认即为 `3`（可以不填）。`name` 可以不单独填写，保持和 `key` 或 JS 脚本名称一致即可。

```json
{
  "sites": [
    {
      "key": "push_agent",
      "name": "push_agent",
      "api": "./js/我的推送.js",
      "changeable": 0,
      "filterable": 0,
      "ext": {
        "quarkck": "./config/quarkcookie.txt"
      }
    },
    {
      "key": "聚影",
      "name": "聚影",
      "api": "./js/聚影.js",
      "changeable": 0
    }
  ]
}
```

| 字段 | 类型 | 说明 | 
| ----- | ----- | ----- | 
| `key` | string | 站点唯一标识（详情、播放、收藏和历史记录均使用此值定位） | 
| `name` | string | 站点名称（可直接保持和 key 或 JS 名称一致） | 
| `type` | number | 站点类型。默认值为 `3`，可不填 | 
| `api` | string | JS 脚本文件的路径（如 `./js/聚影.js`），仅支持 JS | 
| `ext` | string/object | 传给初始化方法的扩展参数或配置文件路径 | 
| `changeable` | number | 是否允许换源。`1` 启用，`0` 禁用 | 

## 三、 JS Spider 运行时与方法规范

JS Spider 运行在 QuickJS 运行时环境中。模块可以通过 `export default` 导出对象或工厂函数，也可以导出 CatVod 兼容的 `__jsEvalReturn()`。

### 必须实现的导出方法

| 方法 | 参数 | 返回值 | 说明 | 
| ----- | ----- | ----- | ----- | 
| `init(ext)` | `ext: any` | 任意 | 初始化。传入扩展参数 | 
| `home(filter)` | `filter: boolean` | string (JSON) | 返回首页分类 JSON | 
| `homeVod()` | 无 | string (JSON) | 返回首页推荐 JSON（可选） | 
| `category(tid, pg, filter, extend)` | `tid: string`, `pg: string`, `filter: boolean`, `extend: object` | string (JSON) | 返回分类页 JSON | 
| `detail(id)` | `id: string` | string (JSON) | 返回详情 JSON。注意 JS 运行时只传 `ids[0]`（单字符串），不是数组 | 
| `search(key, quick, pg)` | `key: string`, `quick: boolean`, `pg: string` | string (JSON) | 分页搜索方法 | 
| `play(flag, id, flags)` | `flag: string`, `id: string`, `flags: array` | string (JSON) | 返回播放链接 JSON | 

## 四、 JS 全局工具函数

精简后的 JS 全局环境仅保留核心工具，**移除了复杂的加解密和 DOM 解析相关函数**。

| 工具 | 签名 | 返回值 | 说明 | 
| ----- | ----- | ----- | ----- | 
| `req` | `req(url, options)` | object | 同步 HTTP 请求。等价于 `http(url, { ...options, async: false })` | 
| `http` | `http(url, options)` | Promise 或 object | 默认返回 Promise；当 `options.async === false` 时同步返回 object | 
| `getPort` | `getPort()` | number | 获取当前本地 HTTP 服务的端口号 | 
| `setTimeout` | `setTimeout(fn, delay)` | null | QuickJS 定时执行函数 | 
| `local.get` | `local.get(rule, key)` | string | 读取本地持久化字符串 (`Prefers`) | 
| `local.set` | `local.set(rule, key, value)` | void | 写入本地持久化字符串 (`Prefers`) | 
| `local.delete` | `local.delete(rule, key)` | void | 删除本地持久化字符串 (`Prefers`) | 

## 五、 Spider 返回结构与完整示例

### 1. 首页分类返回 (`home`)

```json
{
  "class": [
    { "type_id": "1", "type_name": "电影" },
    { "type_id": "2", "type_name": "剧集" }
  ]
}
```

### 2. 分类列表 / 搜索返回 (`category` / `search`)

```json
{
  "list": [
    {
      "vod_id": "v123",
      "vod_name": "示例影片",
      "vod_pic": "https://example.com/pic.jpg",
      "vod_remarks": "更新至10集"
    }
  ],
  "page": 1,
  "pagecount": 10,
  "total": 100
}
```

### 3. 详情返回 (`detail`)

```json
{
  "list": [
    {
      "vod_id": "v123",
      "vod_name": "示例影片",
      "vod_pic": "https://example.com/pic.jpg",
      "vod_play_from": "线路一",
      "vod_play_url": "第一集$https://example.com/1.m3u8#第二集$https://example.com/2.m3u8"
    }
  ]
}
```

### 4. 播放返回 (`play`)

```json
{
  "parse": 0,
  "url": "https://example.com/video.m3u8",
  "header": {
    "Referer": "https://example.com/"
  }
}
```

## 六、 本地 HTTP 服务与 API

App 启动后会内置局域网 HTTP 服务（NanoHTTPD），端口从 `9978` 开始依次尝试。

### 1. 核心端点与能力

| 路径 | 方法 | 说明 | 
| ----- | ----- | ----- | 
| `/device` | GET/POST | 获取设备信息 | 
| `/media` | GET/POST | 获取当前播放状态 | 
| `/action` | GET/POST | 触发控制动作（如 push, search, refresh 等） | 
| `/cache` | GET/POST | 命名空间字符串缓存管理 | 

### 2. 本地推送字幕 API 示例

通过 `/action` 接口可以动态刷新或注入字幕：

```bash
curl -G "http://127.0.0.1:9978/action" \
  --data-urlencode "do=refresh" \
  --data-urlencode "type=subtitle" \
  --data-urlencode "path=https://example.com/subtitle.srt"
```

* **`do=refresh`**：触发当前播放器状态刷新或资源注入。
* **`type=subtitle`**：指定注入资源类型为字幕。
* **`path`**：传入字幕的远程 URL 或本地文件路径。