# OpenWrt 鸿蒙 App 开发规则

> 用途：发给 DevEco Studio 里的 CodeGenie 或其他 AI，作为长期遵循的项目规则。每次新开对话或让 AI 写代码前，先把这份规则贴给它。
>
> **本文件已根据 2026-09-29 的真机（模拟器）实测结果校正过。凡是标「实测」的结论都是在真实路由器上验证过的，不要凭猜测推翻。**

---

## 一、项目背景

我要开发一个鸿蒙 App，用于管理我的 OpenWrt 路由器。所有生成的代码都必须围绕这个场景，不要跑题到通用鸿蒙教程或其他路由器系统。

### 我的 OpenWrt 环境（固定不变）

| 项目 | 值 |
|---|---|
| OpenWrt 版本 | 25.12.5 (r33051-f5dae5ece4) |
| 内核 | 6.12.94 |
| 目标平台 | mediatek/filogic，aarch64_cortex-a53 |
| 设备 | Xiaomi Mi Router AX3000T (OpenWrt U-Boot layout) |
| LuCI HTTP | http://192.168.2.1 |
| LuCI HTTPS | https://192.168.2.1 |
| 登录用户名 | root |
| luci-mod-rpc | 未安装 |
| luci-app-commands | 未安装 |
| 已装插件 | luci-app-openclash 0.47.156、luci-theme-argon 2.4.7、luci-app-argon-config 2.4.7 |
| 包管理器 | apk（不是 opkg） |
| /ubus 端点 | 可用 |

### 我的鸿蒙开发环境（固定不变）

| 项目 | 值 |
|---|---|
| IDE | DevEco Studio 6.1.1 Release (Build #6.1.1.300) |
| 操作系统 | Windows 11 |
| 语言 | ArkTS |
| UI 框架 | ArkUI 声明式 |
| 目标设备 | 手机为主，兼容平板 |
| SDK | HarmonyOS 6.1.1 (API 24)，targetSdkVersion / compatibleSdkVersion 都是 6.1.1(24) |
| 工程路径 | E:\HarmonyNext\Code\OpenWrt |
| 工程状态 | 已有完整工程，5 个 Tab 页：仪表盘 / 网络接口 / 无线 / 在线设备 / OpenClash；应用名「OpenWrt 管理」（分层图标，源自 OpenWrt logo） |
| bundleName | com.example.myapplication |

---

## 二、通信方式规则

1. **只用 ubus RPC（/ubus 端点）**。因为我的系统没装 `luci-mod-rpc`，所以**不要**用 `/cgi-bin/luci/rpc/*` 那套旧接口（会 404）。
2. **ubus 走 JSON-RPC 2.0 协议**，请求体格式固定为：
   ```json
   {"jsonrpc":"2.0","id":1,"method":"call","params":["<session_id>","<object>","<function>",{<params>}]}
   ```
   响应形如 `{"jsonrpc":"2.0","id":1,"result":[<code>, <data>]}`。
   `code === 0` 才算成功；非 0 或返回 `error` 对象都算失败。
3. **匿名 session id 是 32 个 0**：`00000000000000000000000000000000`，只有 `session.login` 能用它。
4. **登录**：`session.login`，参数 `{"username":"root","password":"..."}`，成功返回 `ubus_rpc_session`（32 位）和 `timeout`（300 秒）。

---

## 三、ubus 权限白名单（实测，非常重要）

OpenWrt 的 rpcd 有 ACL。**很多看起来理所当然的方法实际会被拒绝**，返回 `-32002 Access denied` 或 ubus code 6。
写代码前先对照下面两张表，不要凭直觉调用。

### ✅ 允许调用（实测可用）

| 对象 | 方法 | 用途 |
|---|---|---|
| `session` | `login` | 登录拿 session |
| `system` | `board` | 固件/设备信息 |
| `system` | `info` | 运行时长、内存、负载 |
| `rc` | `list` | **查服务状态（返回 running / enabled）** |
| `rc` | `init` | **启停服务（action: start/stop/restart/reload/enable/disable）** |
| `service` | `list` | 列服务（注意返回结构是嵌套的 instances） |
| `luci-rpc` | `getDHCPLeases` | **DHCP 租约（在线设备）** |
| `luci-rpc` | `getHostHints` | **全部已知主机（MAC → 名称/IP）** |
| `luci-rpc` | `getNetworkDevices` | 网络设备 |
| `luci-rpc` | `getWirelessDevices` | 无线设备 |
| `luci-rpc` | `getBoardJSON` | 板级信息 |
| `network.interface` | `dump` | 接口状态（IP/协议/up） |
| `network.device` | `status` | 单设备状态 |
| `iwinfo` | `info` / `scan` / `assoclist` / `freqlist` / `txpowerlist` / `countrylist` | WiFi 详情、信道扫描、关联客户端 |
| `uci` | `get` / `set` / `commit` / `changes` / `add` / `apply` / `delete` / `order` / `rename` | **读写任意配置（含 wireless、openclash、dhcp、network）** |
| `file` | `read` / `write` / `list` / `remove` / `exec` / `stat` | **仅限 ACL 白名单里的固定路径/命令** |
| `log` | `read` | 读日志 |
| `luci` | `getVersion` / `getProcessList` / `getRealtimeStats` / `getLEDs` 等 | LuCI 辅助信息 |

### ❌ 被拒绝（实测，别用）

| 调用 | 结果 | 正确做法 |
|---|---|---|
| `luci.getDHCPLeases` | `-32002 Access denied`（luci 对象上**没有**这个方法） | 改用 `luci-rpc.getDHCPLeases` |
| `service.restart` | `-32002 Access denied`（service 只放行了 list） | 改用 `rc.init` + `action=restart` |
| `network.wireless.status` | `-32002 Access denied` | 用 `uci.get wireless` + `iwinfo` |
| `iwinfo.devices` | `-32002 Access denied`（只放行了 info/scan/assoclist 等） | 用 `iwinfo.info` |
| `hostapd.<iface>.get_clients` | `-32002 Access denied`（只放行 del_client/wps_*） | 用 `iwinfo.assoclist` |
| `file.read /tmp/dhcp.leases` | ubus code **6（权限拒绝）**，路径不在白名单 | 用 `luci-rpc.getDHCPLeases` |
| `file.exec /etc/init.d/xxx` | ubus code **6**，只能跑白名单命令 | 用 `rc.init` |
| 匿名 session 调任何业务方法 | `-32002 Access denied` | 必须先 `session.login` |
| `rc.init` + `action=running/enabled/status` | ubus code **2（参数非法）** | 查状态用 `rc.list` |

### 网络接口 / 流量的数据来源（实测，很容易搞错）

| 想要什么 | 该调哪个 |
|---|---|
| 逻辑接口（lan / wan / wan6 / loopback）的 IP、网关、DNS、运行时长 | `network.interface dump` |
| **设备流量统计**（rx/tx bytes、包数、错误包） | `network.device status` + `{"name":"<l3_device>"}` |
| 设备属性（MTU、链路速率、MAC、网桥成员、carrier） | 同上 |
| 所有网卡的 IP + 统计（另一条路） | `luci-rpc.getNetworkDevices` |

**⚠️ 两个坑：**

1. **`network.interface dump` 里没有流量。** 它的 `data` 字段对静态/桥接接口是空的，
   `rx_bytes` / `tx_bytes` 只存在于 `network.device status` 返回的 `statistics` 里。
   所以 N 个接口要发 N+1 个请求。

2. **dump 的字段名带连字符**：`ipv4-address`（数组 `[{address, mask}]`）、
   `dns-server`（数组）、`l3_device`、`ipv6-address`、`route`（`[{target, mask, nexthop}]`）。
   ArkTS 里不能当标识符用，**必须先映射成 camelCase 模型**再给 UI 用。
   网关要从 `route` 里找 `target === '0.0.0.0' && mask === 0` 那条的 `nexthop`。

3. **wan 和 wan6 的 `l3_device` 都是 `wan`**，如果每张卡都显示设备统计，
   会出现两份一模一样的流量和 MTU。要按 `l3_device` 去重，只让第一个显示，
   其余的给一句"见 XXX 卡片"的提示。

---

## 四、关键数据结构的真实形状（实测，容易写错）

### 1. `luci-rpc.getDHCPLeases`

**返回的是对象，不是数组！**
```json
{"dhcp_leases":[{"expires":29856,"hostname":"HCL","macaddr":"00:E0:4C:89:44:6F","ipaddr":"192.168.2.230"}],
 "dhcp6_leases":[{"expires":0,"interface":"br-lan","hostname":"HCL","macaddr":"...","duid":"...","iaid":"...","ip6addr":"...","ip6addrs":["..."]}]}
```
- `expires` 是**剩余秒数**（相对值），不是时间戳；`<0` 表示永久租约。
- 主机名字段可能缺失。

### 2. `rc.list`
```json
{"openclash":{"start":99,"stop":15,"enabled":true,"running":true}}
```
**判断服务是否在跑，就用这个对象 + `running` 字段。**

### 3. `service.list`（不要用它判断 running！）
```json
{"openclash":{"instances":{"openclash":{"running":true,"pid":13373,"command":[...]},
                           "openclash-watchdog":{"running":true,"pid":13374}}}}
```
`running` 嵌在 `instances.<名字>.running` 里，**顶层没有 `running` 字段**，写 `data["openclash"].running` 永远是 undefined。

### 4. `uci.get`（指定 config + section）
```json
{"values":{"enable":"1","proxy_mode":"rule","cn_port":"9090","http_port":"7890","mixed_port":"7893","dashboard_password":"***"}}
```
取 `result.values` 这个 map。**传了 `section` 才会返回扁平 values，只传 `config` 会返回所有 section。**

### 5. ⚠️ `system.info` 的 `load` 放大了 65536 倍，`memory` 单位是字节

```json
{
  "uptime": 536545,
  "load": [15680, 12800, 6784],
  "memory": { "total": 245288960, "free": 34324480, "buffered": 0,
              "cached": 54083584, "available": 30146560, "shared": 19456000 }
}
```

- **`load` 是定点整数**：实测路由器 `/proc/loadavg` 是 `0.24 0.20 0.10`，
  而 `system.info` 返回 `[15680, 12800, 6784]` —— **除以 65536 正好对上**
  （15680/65536 = 0.239）。直接用会显示成 `15680.00` 这种离谱数字。

  兼容写法（有些版本返回浮点）：
  ```typescript
  private normalizeLoad(raw: number): number {
    return raw > 100 ? raw / 65536 : raw;   // 真实 load 不可能超过 100
  }
  ```

- **`memory` 的单位是字节**（不是 KB）：`total = 245288960` 就是 233.9 MB。
- `memory.available`（MemAvailable）可以直接当"可用内存"用。
- 已用内存按 `total - free - buffered - cached` 算，结果和 `free` 命令的 used 基本一致
  （`free` 的 buff/cache 口径略大，差 2~3 个百分点）。
- `uptime` 单位是秒。

---

## 五、OpenClash 接入规则（实测）

OpenClash **没有自己的 ubus 对象**，走这三条路：

1. **是否运行** → `rc.list` + `name=openclash`，看 `running`。
2. **配置** → `uci.get` `config=openclash section=config`，其中：
   - `dashboard_password` → Clash 外部控制 API 的**密钥**
   - `cn_port` → 外部控制端口（我的机器是 **9090**）
   - `proxy_mode` → rule / global / direct
   - `http_port` 7890、`mixed_port` 7893
3. **版本/模式** → Clash 外部控制 API：`http://<路由器IP>:<cn_port>/version`、`/configs`
   - **必须带请求头 `Authorization: Bearer <dashboard_password>`**，否则一律 **401 未经授权**。
   - 实测：带密钥 → `{"meta":true,"version":"v1.19.30"}`。
   - **不要**试图用 `file.read` 读 `/etc/openclash/*.yaml` 找密钥 —— 权限拒绝，走 uci。

**启停 OpenClash**：`rc.init` + `{"name":"openclash","action":"start|stop|restart"}`。服务名就叫 `openclash`，没有叫 `clash` 的服务。

---

## 六、无线（WiFi）管理规则（实测）

### 读数据

| 目的 | 调用 |
|---|---|
| **射频开关 / SSID / 密码 / 隐藏 / 接口名 / 信道 / 功率**（首选，一次拿全） | `luci-rpc.getWirelessDevices` |
| 已连接客户端 | `iwinfo.assoclist` + `{"device":"<ifname>"}` |
| 可用信道 | `iwinfo.freqlist` + `{"device":"<ifname>"}` |
| WiFi 详情 | `iwinfo.info` + `{"device":"<ifname>"}` |
| 周边扫描 | `iwinfo.scan` + `{"device":"<ifname>"}` |

- `ifname` 从 `getWirelessDevices()` 的 `result.<radio>.interfaces[0].ifname` 取，例如 `phy1-ap0`。
- **不要**用 `hostapd.<ifname>.get_clients` 取客户端列表 —— ACL 没放行，会 `-32002`。
- `assoclist` / `scan` / `freqlist` 返回的都是 `{"results":[...]}`，要取 `.results`。
- `getWirelessDevices` 返回的每个 radio 有：`up` / `disabled` / `config`（band、channel）/ `interfaces[]`（含 `ifname`、`section`、`config.ssid/key/hidden/encryption`）/ `iwinfo`（channel、txpower、hwmodes_text）。

### 写数据 / 应用

```
uci set wireless <section> <option> <value>     ← uci.set
uci commit wireless                              ← uci.commit
rc.init {"name":"network","action":"reload"}     ← 真正生效
```

| 要改什么 | section | option | 值 |
|---|---|---|---|
| 射频开关 | `radio0` / `radio1` | `disabled` | `0` 开 / `1` 关 |
| WiFi 名称 | `default_radio0` / `default_radio1` | `ssid` | 字符串 |
| WiFi 密码 | 同上 | `key` | WPA 至少 8 位 |
| 隐藏 SSID | 同上 | `hidden` | `1` 隐藏 / `0` 显示 |

**实测**：`rc.init network reload` **不会踢掉已连接的客户端** —— 射频保持 up、SSID 不变、客户端仍在线。

### 断开客户端

```
hostapd.<ifname>.del_client  {"addr":"<MAC>","deauth":true,"ban_time":0}
```

- 对象名必须带接口名，如 `hostapd.phy1-ap0`；写成 `hostapd` 会 `-32002`。
- `ban_time` 单位是**毫秒**，`0` = 只断开不拉黑，客户端可以立即重连。

### ⚠️ 信道扫描的坑

当 5G 跑在 **HE160**（占用跨 DFS 的宽信道，比如 36–64 中心 50）时，MT7981 驱动会**拒绝后台扫描**，
`iwinfo.scan` 返回空数组；在路由器上直接跑 `iw scan` 也是 0 个 BSS，报
`Netlink error while awaiting scan results: No event received`。

**正确处理**：扫到空数组时不要显示空白列表，要提示用户"可能是 160MHz 宽信道导致的，把带宽降到 80MHz 通常就能扫到"。

---

## 七、ArkTS / ArkUI 硬性规则（踩过的坑）

### 1. 明文 HTTP 必须挂 metadata，否则所有 http:// 请求被系统拒绝

`entry/src/main/resources/base/profile/network_config.json` 写好了还不够，
**必须在 `entry/src/main/module.json5` 的 `module` 里挂上**：

```json5
"metadata": [
  {
    "name": "ohos.net.network_security_config",
    "resource": "$profile:network_config"
  }
]
```

`network_config.json` 里把我路由器的地址都列进 `domain-config` 并设 `cleartextTrafficPermitted: true`：
`192.168.2.1`、`192.168.1.1`、`192.168.0.1`、`openwrt.lan`。

**漏了这段 metadata 的表现**：App 能编译能安装，但所有请求静默失败，日志里看不到「明文被拦截」之类的提示。

### 2. ⚠️ `@Builder` 值传递参数不会触发 UI 刷新（本项目最隐蔽的 bug）

**错误写法**：
```typescript
@Builder
row(label: string, value: string) {          // 值传递参数
  Row() { Text(label); Text(value) }
}

// 调用
this.row('版本', this.version);               // version 变了，这一行永远不刷新！
```

**正确写法**：`@Builder` 不接参数，**直接读 `this.xxx`**，才会建立状态依赖：
```typescript
@Builder
clashInfoRows() {
  Column() {
    Row() { Text('版本'); Text(this.version) }   // 直接读 @State → 会刷新
  }.width('100%')
}
```

**判断依据**：如果某个 `@State` 只被当作参数传进 `@Builder`，它就"哑"了。
本项目 `DevicesPage` 把设备卡片**全部内联**，就是为了绕开这个坑 —— 保持这个做法。

**症状**：日志显示数据已经拿到了，但界面上一直显示初始值（`--`）。

### 3. 其他约定

- 用 `import { http } from '@kit.NetworkKit'` 或 `import http from '@ohos.net.http'` 都行，后者已废弃但仍可用。
- 不要写 `private client!: OpenWrtClient;` 这种断言（`arkts-no-definite-assignment` 警告），建议写成 `private client: OpenWrtClient | null = null;`。
- `promptAction.showToast` / `showDialog` 已废弃，但当前工程在用，暂时不强制改。
- 对象字面量**不是**被禁止的；同文件里 `Record<string, string>` 字面量就在用。不要为了"规避"而到处 `JSON.parse`。

### 4. ⚠️ 不要用 `onReachStart` 做「滚到顶部就刷新」

`Scroll` / `List` 的 `onReachStart` **在列表初次渲染时就会触发**（初始位置本来就在顶部）。
如果刷新回调会更新 `@State` 数据，就会引起重渲染 → 再次触发 → **无限刷新死循环**，
把路由器打到冒烟（实测表现为设备页疯狂刷新）。

**错误写法**：
```typescript
List() { ... }
  .onReachStart(() => this.refreshData());   // ← 死循环
```

**正确写法**：用 `Refresh` 组件做下拉刷新：
```typescript
Refresh({ refreshing: this.isRefreshing }) {
  List() { ... }
    .width('100%').height('100%').edgeEffect(EdgeEffect.Spring)
}
.layoutWeight(1)
.width('100%')
.onRefreshing(() => { this.refreshData(); })
```

配套：`refreshData()` 里做并发保护，`loadXxx()` 的 `finally` 里复位：
```typescript
private refreshData(): void {
  if (this.isRefreshing) return;
  this.isRefreshing = true;
  this.loadXxx();
}
// loadXxx 的 finally:
//   this.isLoading = false;
//   this.isRefreshing = false;
```

**曾经中招的页面**：`DevicesPage` / `NetworkPage` / `OpenClashPage`（已全部改成 `Refresh`）。

### 5. 定时器参数单位是毫秒，别写错

`setInterval(fn, ms)` 的第二个参数是**毫秒**。写 `1000` 是 1 秒而不是 30 秒。
仪表盘一次刷新要发 3 个 ubus 请求（`system.board` + `system.info` + `luci-rpc.getDHCPLeases`），
写成 1 秒等于把 256MB 的路由器当压力测试机。当前设为 `30000`（30 秒）。

### 6. 不要同时用 `width('100%')` 和左右 `margin`

`width('100%')` 已经等于父容器**全宽**，再加左右 margin 会让组件**向右溢出**父容器，
右边的内容被屏幕裁掉。实测症状：设备卡片右侧的 `●` 状态点和「X小时X分后过期」被切掉。

**错误写法**：
```typescript
ListItem() {
  Column() { ... }
    .width('100%')
    .margin({ left: 16, right: 16 })   // ← 右侧溢出，右边内容被裁
}
```

**正确写法**：左右留白放到**父容器**的 `padding` 上，卡片只留纵向 margin：
```typescript
List() { ... }
  .width('100%')
  .padding({ left: 16, right: 16 })    // ← 内容区被正确内缩
// 卡片：.width('100%').margin({ bottom: 10 })
```

> 判断方法：dump 布局看 bounds。父容器宽 1316 时，卡片应该是 `[56, ...][1260, ...]`；
> 如果右边界是 1316（屏幕最右）就是溢出了。

### 7. `Column` 的 `alignItems` 默认是 `Center`

要让子元素左对齐，必须显式写 `.alignItems(HorizontalAlign.Start)`。
否则主机名、MAC 地址这类文本会在列内居中（实测设备卡片就中招了：
`HCL` 显示在 `[727,534]` 而不是 `[294,534]`）。

### 8. ⚠️ 颜色一律走资源，页面里不要写死色值（否则夜间模式必炸）

调色板只有两份，**新增颜色必须两边都加**（名字一致）：

| 文件 | 用途 |
|---|---|
| `entry/src/main/resources/base/element/color.json` | 浅色 |
| `entry/src/main/resources/dark/element/color.json` | 深色 |

- 资源名统一 `c_` 前缀（主色 `c_primary`、卡片 `c_card`、文字三级 `c_text_1/2/3`、页面渐变 `c_bg_top/mid/bottom`……）；
- 页面里通过 `common/Theme.ets` 的 `C_XXX` 常量引用（类型是 `Resource`），**不要写 `'#xxxxxx'`**；
- 收不了 `Resource` 的地方 —— Canvas 的 `strokeStyle`/`fillStyle`、`promptAction.showDialog` 按钮的 `color`
  （它们的类型是 `string`）—— 用 Theme 里的 `colorString(res, 回退值)` / `colorRgba(res, 回退值, alpha)`
  在运行时取色，这样深色下也会跟着变；
- 外观模式由 `model/ThemeSettings.ets` 统一管：
  `ApplicationContext.setColorMode()`，`COLOR_MODE_NOT_SET` = 跟随系统，选择存在 `openwrt_settings`
  这个 preferences 里；App 启动时在 `EntryAbility.onCreate` 应用（必须早于加载页面，否则会先按系统模式渲染一帧）；
- **沉浸式下状态栏/导航栏的图标颜色不会跟着应用模式走**（它跟的是系统模式），强制深色时必须自己
  `setWindowSystemBarProperties({statusBarContentColor, navigationBarContentColor})`，ThemeSettings 已处理；
- 想判断"当前实际是不是深色"**不要查 Configuration**：`resourceManager` 的 `Configuration` 类型上没有
  暴露 `colorMode`（编译不过），`ApplicationContext.config` 也不存在。ThemeSettings 里的做法是拿背景色资源的
  实际解析结果按亮度反推，跟随系统时也准；
- 实测验证方式（模拟器）：`uitest dumpLayout` 取按钮坐标 → `uitest uiInput click` →
  `snapshot_display` 截图 → 采样背景像素判断深浅；系统深浅色可在「设置 → 显示和亮度」里切，
  跟随系统模式下 App 会立即跟着变。

---

## 八、构建 / 部署备忘

- 命令行编译（DevEco 没开时可用）：
  ```powershell
  $env:DEVECO_SDK_HOME = "E:\HarmonyNext\DevEco Studio\sdk"
  $env:JAVA_HOME = "E:\HarmonyNext\DevEco Studio\jbr"
  & "E:\HarmonyNext\DevEco Studio\tools\hvigor\bin\hvigorw.bat" `
      --mode module -p product=default -p buildMode=debug assembleHap --no-daemon
  ```
- 产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`
- **HarmonyOS 模拟器接受未签名 HAP**，可直接装：
  ```powershell
  $hdc = "E:\HarmonyNext\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
  & $hdc install -r <hap路径>
  & $hdc shell aa start -a EntryAbility -b com.example.myapplication
  ```
- 抓日志：`hdc shell hilog -r`（清空）→ 操作 → `hdc shell "hilog -x"`，过滤 `JSAPP`
- 截图：`hdc shell snapshot_display -f /data/local/tmp/s.jpg` + `hdc file recv`
- 模拟器 `hdc shell` 是 **uid=2000(shell)，不是 root**。
- **不要在 DevEco 开着工程时并行跑命令行编译** —— 会让 IDE 状态错乱（运行配置丢设备、报「无法在 '<默认>' 上运行 'entry'」）。
