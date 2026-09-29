# WRT · OpenWrt 鸿蒙管理 App

> 应用名（桌面显示）：**OpenWrt 管理**　·　图标：OpenWrt logo（分层图标，见下文「界面」）

用 **HarmonyOS（ArkTS + ArkUI）** 写的 OpenWrt 路由器管理客户端。直接调用路由器自带的 **ubus JSON-RPC** 接口（`/ubus`），不依赖 LuCI 网页、不需要装 `luci-mod-rpc`。

> 开发验证环境：小米路由器 AX3000T（MediaTek MT7981）刷 OpenWrt 25.12.5

---

## 功能

- **登录与会话持久化** —— 用 `@ohos.data.preferences` 保存地址与 session，下次打开自动恢复登录
- **仪表盘** —— **WAN 实时网速（↓/↑）+ 最近 60 秒趋势曲线**（每 2 秒采样，Canvas 手绘，**上下行双 Y 轴各自独立刻度**）；设备型号、OpenWrt 版本、内核版本、主机名、运行时长、CPU 负载（1/5/15 分钟）、内存占用、在线设备数；30 秒静默自动刷新
- **网络接口** —— 每个接口的协议、运行时长、IPv4/IPv6、网关、DNS、DHCP 服务器/租期、MTU、链路速率、MAC、桥接成员；累计流量与包数，以及**每 3 秒刷新的实时速率**（页面不可见时自动暂停采样）
- **无线网络** —— 每个射频的开关（2.4G/5G 独立）、WiFi 名称、密码、隐藏 SSID；**信道与频宽（HT mode）选择**；已连接设备列表（信号强度、收发流量、在线时长）与一键断开；周边 WiFi 扫描
- **在线设备** —— DHCP 租约列表（主机名、MAC、IP、剩余租期）
- **OpenClash** —— 运行状态、内核版本、运行模式、HTTP 端口、是否允许局域网；**策略组与节点切换**（含各节点延迟）；一键重启
- **深色模式** —— 顶部「跟随系统 / 深色 / 浅色」三态按钮，点一下循环切换并本地记住；选「跟随系统」时系统切深浅色，App 立即跟着变（含状态栏/导航栏图标配色）

---

## 环境要求

| 项目 | 版本 |
|---|---|
| DevEco Studio | 6.1.1 Release (Build #6.1.1.300) |
| HarmonyOS SDK | 6.1.1 (API 24) |
| 语言 / UI | ArkTS / ArkUI 声明式 |
| 设备类型 | phone、tablet |

**路由器侧要求**：任何装了 `rpcd` 的 OpenWrt 都能用基础功能；OpenClash 页额外需要 `luci-app-openclash`。

---

## 快速开始

```bash
# 1. 用 DevEco Studio 打开工程，等待 Sync 完成
# 2. 安装依赖
ohpm install

# 3. 连接手机或启动模拟器，直接 Run
```

### 首次使用

打开 App 后在登录页填：

| 字段 | 说明 |
|---|---|
| 路由器 IP | 你的 OpenWrt 地址，例如 `192.168.2.1` |
| 端口 | `80`（走 HTTP）或 `443`（走 HTTPS，自签证书） |
| 用户名 | 通常 `root` |
| 密码 | 路由器 root 密码 |

---

## ⚠️ 关键：明文 HTTP 必须挂 metadata

HarmonyOS **默认禁止明文 HTTP**。想连局域网里的 `http://192.168.x.x/ubus`，光放一个 `network_config.json` 到 `resources` 里是**没用的**，必须在 `entry/src/main/module.json5` 的 `module` 里挂载：

```json5
"metadata": [
  {
    "name": "ohos.net.network_security_config",
    "resource": "$profile:network_config"
  }
]
```

同时把路由器地址加进 `entry/src/main/resources/base/profile/network_config.json`：

```json
{
  "network-security-config": {
    "base-config": { "cleartextTrafficPermitted": false },
    "domain-config": [
      {
        "cleartextTrafficPermitted": true,
        "domains": [
          { "name": "192.168.2.1" },
          { "name": "192.168.1.1" },
          { "name": "192.168.0.1" },
          { "name": "openwrt.lan" }
        ]
      }
    ]
  }
}
```

> **换路由器地址的话，记得同步改这个白名单**，否则请求会静默失败（连接错误里不会提示"明文被拦截"）。

---

## 界面

采用 HarmonyOS 6 (API 24) 的现代 UI 能力：

| 特性 | 实现 |
|---|---|
| **沉浸式布局** | `expandSafeArea` 让渐变背景延伸到状态栏 / 导航栏之后（只扩展背景，内容仍留在安全区内） |
| **系统符号图标** | `SymbolGlyph($r('sys.symbol.xxx'))` —— 标签栏与表单图标全用系统符号：`house` / `rectangle_stack` / `wifi` / `person` / `bolt` / `lock` / `lock_fill` / `eye` / `eye_slash` |
| **毛玻璃标签栏** | `Tabs.barBackgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)` + 半透明底色 |
| **渐变背景** | `linearGradient` 浅蓝 → 灰白 |
| **玻璃拟态卡片** | 半透明白 `#F2FFFFFF` + 圆角 20 + `ShadowStyle.OUTER_DEFAULT_SM` |
| **登录页** | 深蓝渐变头部 + 圆形半透明徽章 + 玻璃表单卡片；键盘「前往」键通过 `onSubmit` 直接提交登录 |
| **趋势曲线** | `Canvas` + `CanvasRenderingContext2D` 命令式绘制（能拿画布真实宽高自适应屏幕，也方便数据更新时直接重绘）；**双 Y 轴**——上下行各自按窗口内峰值缩放，避免一边大一边被压成直线 |
| **统一设计令牌** | `entry/src/main/ets/common/Theme.ets` 集中管理颜色 / 圆角 / 间距 / 字号（颜色是资源引用，不是色值） |
| **深色模式** | 调色板两套资源：`resources/base/element/color.json`（浅色）+ `resources/dark/element/color.json`（深色），由 `ApplicationContext.setColorMode()` 切换；`COLOR_MODE_NOT_SET` 即跟随系统。Canvas / 弹窗按钮这类收不了 `Resource` 的地方用 `Theme.colorString()` 运行时取色 |
| **应用图标** | 分层图标 `layered_image`：`foreground.png` 1024×1024（图标内容限制在中央 640 安全区内，圆角 / 圆形遮罩都不会切到图形）+ `background.png` 浅蓝→白渐变 + 启动图 `startIcon.png` 512×512 |

> 💡 **实时速率怎么做的**：用 `luci-rpc.getNetworkDevices` —— **一次请求**就返回全部网卡的
> `stats.rx_bytes / tx_bytes`（实测 8 个），比逐个调 `network.device status` 便宜得多。
> 每 2~3 秒采一次，速率 = (本次 − 上次) / 间隔秒数；页面滑出屏幕后用
> `onVisibleAreaChange` 自动暂停采样。

> 💡 **系统符号名从哪来**：DevEco SDK 的
> `sdk/default/openharmony/toolchains/id_defined.json` 里 `"type":"symbol"` 的记录共 **4000+ 个**，
> 直接搜关键词即可（如 `wifi`、`house`、`trash`）。注意 `$r()` 的资源名必须是**字面量**，
> 不能用模板字符串拼，所以按索引分支写 if/else。

---

## 项目结构

```
entry/src/main/
├── module.json5                     # 权限 + 明文 HTTP metadata
├── resources/base/profile/
│   └── network_config.json          # 明文 HTTP 白名单
└── ets/
    ├── common/
    │   └── Theme.ets                # 设计令牌（颜色引用 / 圆角 / 间距 / 字号）+ Canvas/弹窗取色函数
    ├── model/
    │   ├── OpenWrtClient.ets        # ubus JSON-RPC 客户端（核心，全部网络调用都在这）
    │   ├── OpenWrtModels.ets        # 数据模型 / 接口定义
    │   ├── SessionStore.ets         # 会话本地持久化
    │   ├── ThemeSettings.ets        # 外观模式（跟随系统/浅色/深色）+ setColorMode + 系统栏配色
    │   └── GlobalContext.ets        # 全局 Context 单例
    └── pages/
        ├── Index.ets                # 入口：未登录→LoginPage，已登录→HomePage
        ├── LoginPage.ets            # 登录页
        ├── HomePage.ets             # Tabs 容器（5 个 Tab）
        ├── DashboardPage.ets        # 仪表盘
        ├── NetworkPage.ets          # 网络接口
        ├── WifiPage.ets             # 无线网络（射频开关 / SSID / 密码 / 隐藏 / 客户端踢出 / 扫描）
        ├── DevicesPage.ets          # 在线设备
        └── OpenClashPage.ets        # OpenClash
```

---

## ubus 权限说明（踩坑记录）

OpenWrt 的 rpcd 有 **ACL 白名单**，很多看起来理所当然的方法实际会被拒绝，返回 `-32002 Access denied` 或 ubus code 6。
本项目已按真机实测结果写好了。完整清单见 **[`.codegenie/project_rule.md`](.codegenie/project_rule.md)**，这里列几个最容易写错的：

| ❌ 会被拒绝 | ✅ 正确做法 |
|---|---|
| `luci.getDHCPLeases` | `luci-rpc.getDHCPLeases` |
| `service.restart` | `rc.init` + `{"action":"restart"}` |
| `service.list` 的顶层 `running` | `rc.list` 返回的 `running` |
| `file.read /tmp/dhcp.leases` | `luci-rpc.getDHCPLeases` |
| `network.wireless.status` | `uci.get wireless` + `iwinfo.*` |
| `iwinfo.devices` | `iwinfo.info` |

另外两个**返回结构**的坑：

- `luci-rpc.getDHCPLeases` 返回的是**对象** `{dhcp_leases:[...], dhcp6_leases:[...]}`，不是数组
- `service.list` 的 `running` 嵌套在 `instances.<名字>.running` 里，顶层没有该字段

---

## ArkUI 注意事项

**`@Builder` 的值传递参数不会建立状态依赖**，参数变了 UI 不会刷新：

```typescript
// ❌ 数据变了，界面永远停在初始值
@Builder
infoRow(label: string, value: string) { Row() { Text(label); Text(value) } }
this.infoRow('版本', this.version);

// ✅ 直接读 @State，才会响应刷新
@Builder
clashInfoRows() { Column() { Row() { Text('版本'); Text(this.version) } } }
```

`DevicesPage.ets` 里把设备卡片全部内联，就是为了绕开这个坑。

---

## 已知限制 / TODO

### 已完成

- [x] **应用图标与应用名** —— 图标取自 OpenWrt logo（`foreground.png` 1024×1024、内容限制在中央 640 安全区；`background.png` 浅蓝→白渐变；启动图 `startIcon.png` 512×512），应用名统一为「OpenWrt 管理」
- [x] **OpenClash 策略组与节点切换** —— 读 `/proxies` 列出 Selector / URLTest / Fallback 策略组及成员延迟，用 `PUT /proxies/{组名}` 切节点
- [x] **深色模式** —— 顶部三态按钮（跟随系统 / 深色 / 浅色）循环切换并本地记住；颜色集中在 base/dark 两套 `color.json`，随系统深浅色自动切换（含系统栏图标配色）

### 待办

- [ ] **无线页的「多 SSID」缺口**（对「多 WiFi / 一 WiFi 一住宅 IP」方案影响最大的一条）：
      `luci-rpc.getWirelessDevices` 返回的 `interfaces[]` 目前只取了第一个（`ifaces[0]`），
      因此一个射频上挂的第 2 个及以后的 SSID 既看不到也改不了，已连接客户端也只统计第一个 AP；
      另外还缺「SSID → network / zone / 出口 IP」的对照展示
- [ ] **会话过期没有恢复路径**：路由器 session 300 秒超时后所有请求返回 `-32002`，
      页面只会显示各种「获取失败 / 写入失败」；密码没有持久化、无法自动重登，
      需要统一检测 `-32002` 并退回登录页
- [ ] 无线页暂未做**发射功率调整**（`iwinfo.txpowerlist` 可枚举可选功率，目前只读不写）
- [ ] 暂未做 OpenClash **订阅管理**（策略组 / 节点切换已支持）
- [ ] 暂未做路由器重启按钮（`system.reboot` 已可用）
- [ ] `bundleName` 还是默认的 `com.example.myapplication`，正式发布前需要改
- [ ] `OpenWrtClient` 用字符串拼接构造 JSON（`session.login`、`setWifiOption`）：密码 / SSID 里含 `"` 或 `\` 时请求体会坏掉，应改用 `JSON.stringify`
- [ ] 设备页 / 网络页的下拉刷新会把整页置为 loading，列表连同 `Refresh` 一起被卸载重建，体验退化成「整页转圈」；仪表盘静默刷新失败时也会整体切到错误页、丢掉已有数据
