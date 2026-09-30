# WRT · OpenWrt 鸿蒙管理 App

> 应用名（桌面显示）：**OpenWrt 管理**　·　图标：OpenWrt logo（分层图标，见下文「界面」）

用 **HarmonyOS（ArkTS + ArkUI）** 写的 OpenWrt 路由器管理客户端。直接调用路由器自带的 **ubus JSON-RPC** 接口（`/ubus`），不依赖 LuCI 网页、不需要装 `luci-mod-rpc`。

> 开发验证环境：小米路由器 AX3000T（MediaTek MT7981）刷 OpenWrt 25.12.5

---

## 功能

- **登录与会话持久化** —— 用 `@ohos.data.preferences` 保存地址与 session，下次打开自动恢复登录；登录页可勾「记住密码」（密码存**系统安全存储** `@ohos.security.asset`，不是明文 preferences），勾了之后登录页会自动填好密码、会话过期时**静默自动重登**（不再弹回登录页）
- **仪表盘** —— **WAN 实时网速（↓/↑）+ 最近 60 秒趋势曲线**（每 2 秒采样，Canvas 手绘，**上下行双 Y 轴各自独立刻度**）；设备型号、OpenWrt 版本、内核版本、主机名、运行时长、CPU 负载（1/5/15 分钟）、内存占用、在线设备数；30 秒静默自动刷新

- **网络接口** —— 每个接口的协议、运行时长、IPv4/IPv6、网关、DNS、DHCP 服务器/租期、MTU、链路速率、MAC、桥接成员；累计流量与包数，以及**每 3 秒刷新的实时速率**（页面不可见时自动暂停采样）
- **无线网络（多 SSID）** —— 每个射频下列出**全部** SSID（含射频关闭时配置里仍存在的），逐个可改：WiFi 名称、密码、隐藏、**绑定 network**、单独启用/禁用，以及**新增 / 删除 SSID**；射频级开关、**信道 / 频宽 / 发射功率**选择；**2.4G / 5G 两张射频卡都能折叠 / 展开**（默认开着就展开、关着就收起，手动切换后记住）；每个 SSID 的已连接设备（信号强度、收发流量、在线时长）与一键断开；周边 WiFi 扫描

- **在线设备（二级页面）** —— 从仪表盘的「在线设备」卡片点进去（底部导航栏已没有该 Tab）：DHCP 租约列表（主机名、MAC、IP、剩余租期），支持下拉刷新，带返回按钮与系统返回键；每台设备可以写**备注**（如「客厅电视」），备注存在本机、不写路由器，重启 App 仍在
- **OpenClash**（🧊 **已冻结，不再迭代**）—— 运行状态、内核版本、运行模式、HTTP 端口、是否允许局域网；**策略组与节点切换**（含各节点延迟）；一键重启。
  其它页面可以只读复用它的数据，但不再改动本页、也不新增 Clash 功能
- **深色模式** —— 顶部「跟随系统 / 深色 / 浅色」三态按钮，点一下循环切换并本地记住；选「跟随系统」时系统切深浅色，App 立即跟着变（含状态栏/导航栏图标配色）
- **关于（二级页面）** —— 主页右上角 ⓘ 进入：应用版本 / bundleName、**联系方式**（GitHub @abookkkk、项目仓库、Issues、Releases，点了用系统浏览器打开）、**检查更新**（调 GitHub Releases API 比对版本，有新版本就**自动下载** HAP 到应用目录并显示进度，再提供「另存为…」用系统文件选择器导出）
- **统一的刷新方式** —— 五个 Tab 页只有**下拉刷新**一种手势（页面里不再有「刷新」按钮）：下拉时只显示顶部指示器、页面内容不重建；刷新失败保留屏幕上已有的数据并提示，只有首屏失败才整页换成错误页 + 重试

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
| **透明毛玻璃导航栏** | 顶部标题栏与底部标签栏都是「半透明底色（调色板 `c_bar`，35% 不透明）+ `BlurStyle.COMPONENT_ULTRA_THICK`」：内容滚到栏下会被虚化、文字仍清晰；系统状态栏 / 导航栏也显式设成透明（`statusBarColor`/`navigationBarColor` = `#00000000`），渐变背景能透上去 |
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
    │   ├── Theme.ets                # 设计令牌（颜色引用 / 圆角 / 间距 / 字号）+ Canvas/弹窗取色函数
    │   └── RefreshPolicy.ets        # 统一下拉刷新策略（LoadKind 三档 + 失败反馈），五个 Tab 页共用
    ├── model/
    │   ├── OpenWrtClient.ets        # ubus JSON-RPC 客户端（核心，全部网络调用都在这）
    │   ├── OpenWrtModels.ets        # 数据模型 / 接口定义
    │   ├── SessionStore.ets         # 会话本地持久化
    │   ├── ThemeSettings.ets        # 外观模式（跟随系统/浅色/深色）+ setColorMode + 系统栏配色
    │   ├── GlobalContext.ets        # 全局 Context 单例
    │   ├── DeviceNotes.ets          # 设备备注（只存本机 preferences，键是 MAC）
    │   └── UpdateChecker.ets        # 检查更新 / 下载新版本（GitHub Releases API + releases.atom 兜底）
    └── pages/
        ├── Index.ets                # 入口：未登录→LoginPage，已登录→HomePage
        ├── LoginPage.ets            # 登录页
        ├── HomePage.ets             # Tabs 容器（4 个 Tab）+ 二级页面栈（Navigation / NavDestination）
        ├── DashboardPage.ets        # 仪表盘
        ├── AboutPage.ets            # 关于（版本 / 联系方式 / 检查更新并下载）
        ├── NetworkPage.ets          # 网络接口
        ├── WifiPage.ets             # 无线网络（射频开关 / SSID / 密码 / 隐藏 / 客户端踢出 / 扫描）
        ├── DevicesPage.ets          # 在线设备（二级页面，从仪表盘卡片进入）
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
- [x] **多 SSID 管理** —— 无线页改为以 `uci.get wireless` 为权威数据源，列出全部 wifi-iface（含射频禁用时配置里仍存在的那些），支持新增/删除/逐项编辑/绑定 network/单独启停
      （顶部那张「出口映射」卡片后来按需求删掉了：太占版面、影响观感；SSID → network → 子网的归属仍能在每个 SSID 卡片里看到）
- [x] **为 SSID 建独立子网** —— 无线页每个 SSID 可「建独立子网 / 退回 lan」：新建桥 + 静态接口 + DHCP，并把新网段加入 lan 防火墙区域；任一步失败自动回滚未提交的段
- [x] **发射功率调整** —— `iwinfo.txpowerlist` 枚举档位（本机 0~23 dBm），写 `wireless.<radio>.txpower`；选「自动」则删除该项回到驱动默认
- [x] **会话过期自动回登录页** —— 旧代码只读 `result[0]`，而会话过期时 rpcd 返回的是
      `{"error":{"code":-32002,"message":"Access denied"}}`（**没有 result 字段**），异常被吞成一句"请求异常"。
      现在两种失败形态分开处理：客户端识别 -32002 后回调上层 —— 勾过「记住密码」就用它在同一个客户端上静默重登
      （不换实例，所以各页面手里的引用依然有效），否则才清本地 session → 回登录页并提示
      「登录已过期，请重新登录」；回到前台时还会主动打一次轻量校验，切后台放超时就当场退回

- [x] **统一的刷新方式** —— 原来五个 Tab 页各一套：无线页 / 仪表盘靠按钮刷新，设备页 / 网络页虽然能下拉但会把整页置为 loading（列表连同 `Refresh` 一起被卸载重建，退化成「整页转圈」），仪表盘的静默刷新失败还会整页切错误页、丢掉已有数据。
      现在统一为：**只有下拉刷新一种手势**（页面里的刷新按钮全部删掉），下拉只切 `isRefreshing`（顶部指示器、内容不重建），
      失败按三档反馈（首屏 → 错误页 / 下拉 → 保留数据 + 提示 / 静默 → 只写日志），策略集中在 `common/RefreshPolicy.ets`，
      规范写进 `.codegenie/project_rule.md` 第七节第 10 条；写配置期间用 `.pullToRefresh(!this.busy)` 关掉下拉

- [x] **在线设备改成仪表盘的二级页面** —— 原来它占一个底部 Tab，现在从仪表盘「在线设备」卡片点进（卡片右侧有 `›` 提示），
      用 `Navigation` + `NavPathStack` + `NavDestination` 实现：整页盖住标签栏、自绘标题栏与返回按钮、系统返回键与侧滑返回由框架处理

- [x] **2.4G / 5G 射频卡都能折叠** —— 以前只有「关着的射频」才带收起按钮，现在两张卡都有「展开 / 收起」：
      默认仍是开着就展开、关着就收起（观感不变），折起来时显示一行摘要（SSID 数量 · 当前信道 · 功率），
      手动切换会被记住 —— 页面重载（含写完配置后那次重载）不会弹回去

- [x] **设备备注** —— 在线设备页每台设备右边一个「备注 / 改备注」按钮，弹出带输入框的对话框（`@CustomDialog`）：
      备注写进本机 preferences（键是 MAC 小写，`model/DeviceNotes.ets`），**不写路由器** ——
      路由器那边能改的是静态租约 / hostname，会真的改变 dnsmasq 的分配行为，而备注只是给自己看的名字


- [x] **换了 bundleName** —— `com.example.myapplication` → **`com.abookkkk.wrt`**（正式发布前必须把默认包名换掉）
      ⚠️ 换包名等于换了一个 App：**旧包的本地数据不会跟过来**（登录 session、设备备注、外观设置都在各自的沙箱里），
      装新版后要重新登录、备注重写；旧包可以直接卸载

- [x] **「关于」页 + 检查更新** —— 右上角 ⓘ 进入：版本号 / bundleName、GitHub 联系方式、检查更新并**自动下载**新 HAP（下到应用目录，带进度，「另存为…」走系统文件选择器导出）。
      过程中有三条实测结论：① **仓库原本是私有的**，匿名看不到 release、附件也 404（已改成 public）；
      ② 匿名调 GitHub API **按 IP 每小时 60 次**，而这条链路走代理、出口 IP 与别人共用，很快就用光 → 现在会读
      `releases.atom`（网页端点，不吃 API 限流）兜底拿版本号，并按发布惯例拼附件地址；
      ③ 鸿蒙普通应用**没有静默安装权限**（`bundle.installer` 是系统 API），且 HAP 未签名（真机要自己签名）——
      所以只能「下载 → 导出 → 手动装」，页面里写明了。实测：下载到 976,897 字节（与发布物一致）、「另存为」能拉起系统保存面板

- [x] **上下两根导航栏改成透明毛玻璃** —— 顶部标题栏加 `c_bar`（35% 不透明）+ `BlurStyle.COMPONENT_ULTRA_THICK`，与底部标签栏同一套观感：
      内容滚到栏下被虚化（实测滚动截图里卡片文字从栏后透出来、被模糊），系统状态栏 / 导航栏也显式设成透明让渐变透上去。
      顺手修掉一个回归：顶栏加了 ⓘ 之后三个按钮把标题挤到换行（「OpenWrt 管 / 理」），标题字号 26 → 22 并限制单行

### 待办

- [ ] **App 无法代写「按源 IP 分流」的 Clash 规则**（实测 `file.write` 被 ACL 拒绝，连 `/tmp` 都不行；OpenClash 的自定义规则文件 `file.read` 也拒绝）。
      独立子网已经做进 App（无线页每个 SSID 都能建/删独立网段），但最后一步
      `SRC-IP-CIDR,<子网>,<策略组>` 规则仍要在 LuCI / SSH 里配 —— 详见 `PLAN.md`
- [ ] 暂未做路由器重启按钮（`system.reboot` 已可用）

- [x] **修掉「用字符串拼 JSON」的隐患** —— `session.login` 的用户名/密码、`setWifiOption` 的值、uci.set 家族，
      以及 ubus 请求体本身的 `sessionId / obj / func / args`，现在一律走 `JSON.stringify` 转义，
      密码 / SSID 里含 `"` 或 `\` 不会再破坏请求体。实测把 2.4G 的 SSID 写成含反斜杠的值能正常落盘（读回一致，随后已还原）
