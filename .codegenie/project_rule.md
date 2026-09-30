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
| 工程状态 | 已有完整工程，4 个 Tab 页：仪表盘 / 网络接口 / 无线 / OpenClash，外加 1 个二级页面「在线设备」（从仪表盘卡片进入，见第七节第 11 条）；应用名「OpenWrt 管理」（分层图标，源自 OpenWrt logo） |
| bundleName | **com.abookkkk.wrt**（2026-09-30 从默认的 `com.example.myapplication` 改过来；换包名等于换一个 App，旧包的本地数据不会跟过来） |

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
5. ⚠️ **构造 JSON 一律用 `JSON.stringify` 转义，不要拼字符串。**
   踩过的坑：`session.login` 与 `setWifiOption` 把密码 / SSID 直接插进 JSON 串里，值里只要有一个 `"` 或 `\`，
   请求体就不是合法 JSON，路由器只会回一个含糊的失败（表现为"登录失败 / 保存失败"，很难查）。
   现在 `uciSetBody()`（客户端里的小 helper）负责 uci.set 的转义，ubus 请求体的
   `sessionId / obj / func / args` 四个元素也都过 `JSON.stringify`。
   实测：SSID 写成含反斜杠的值能正常落盘、读回一致。

> ⚠️ **两种失败形态必须分开处理**（本项目踩过，也是"登录过期"被显示成"请求异常"的根因）：
> - `{"result":[<code>, ...]}` 且 `code != 0` —— **ubus 层**错误（4=参数错、6=权限/路径不在白名单）；
> - `{"error":{"code":-32002,"message":"Access denied"}}` —— **JSON-RPC 层**错误，
>   **会话过期就是这一种**，此时**根本没有 result 字段**；只读 `result[0]` 会抛异常，
>   被 catch 成"请求异常: Cannot read property '0' of undefined"，既看不出是过期、也没法统一处理。
>   实测：匿名 session、乱写的 session id、rpcd 重启后的旧 session，调任何业务方法都是这个形状。
> - 判定"登录已过期"就用 `error.code === -32002`；处理方式：清本地 session → 回登录页（密码不落地，无法自动重登）。
> - `session.list` 也被拒（-32002），没法枚举/销毁别人的 session；想制造过期只能重启 rpcd
>   （`rc.init {"name":"rpcd","action":"restart"}`，会废掉所有 session），或等 300 秒空闲超时。

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

> 🧊 **本页已冻结（2026-09-30，用户要求）**：
> **不要再改动 `OpenClashPage.ets`，也不要新增任何 Clash 相关功能**（订阅管理、全量测速、连接列表等一律不做）。
> 已经实现的部分保持原样、不要"顺手优化"。
> 唯一例外是**只读复用**：其它页面可以调用已有的
> `getOpenClashSettings()` / `getClashRules()` / `getClashGroups()` 读数据，但不要去改这些方法本身。
> 下面这些实测结论保留，供理解现状用。
>
> **唯一的一次例外（2026-09-30，用户同意）**：把本页的**刷新机制**对齐到全 App 统一规范
> （见第七节第 10 条）—— `loadAll()` 改名 `loadData(kind)`、下拉刷新不再切 `isLoading`、
> 失败不再整页切错误页。**只动了刷新，没碰任何 Clash 逻辑、界面与文案。**

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

**同类坑：`ForEach` 会复用条目节点。** 条目上显示的某个值改了、但 key 没变时，那一行不会刷新。
`DevicesPage` 的设备卡 key 里就带上了备注（`device.mac + device.ip + '#' + 备注`），
备注一改 key 就变，卡片才会重建。

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

**接法（全 App 统一，见下面第 10 条）**：`onRefreshing` 里调 `onPullRefresh()`，
它只切 `isRefreshing` 然后 `loadData('pull')` —— **不要**再把 `isLoading` 拉起来。

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

### 9. ⚠️ 多 SSID / 出口映射（实测结论，别再踩）

**管理 SSID 的权威数据源是 `uci.get {"config":"wireless"}`，不是 `luci-rpc.getWirelessDevices`。**

- 射频 `disabled=1` 时，`getWirelessDevices` 里该 radio 的 `interfaces[]` 是**空的**，
  但配置里的 wifi-iface 仍然存在（本机实测：`radio0` 禁用，`default_radio0`（SSID `OpenWrt`）
  还在）。只按运行时接口渲染，就会出现「射频关着 → 它的 SSID 在 App 里彻底消失」。
- 正确做法（`WifiPage` 现在的实现）：uci 拿配置态（全部 device/iface）→ `getWirelessDevices`
  拿运行时（每个 AP 的 `ifname`、射频 `iwinfo`）→ 用 **section 名**把两者 join 起来。
- `uci.get` 只传 `config` 时返回 `{"values": {"<section>": {...}}}`（要多套一层 `values`）；
  传了 `section` 才是扁平的 `{"values": {...}}`。

**写操作实测放行**：`uci.add/delete/commit/set` 都可用（用不存在的 config 名探测，返回
`ubus_code=4`（参数错）而不是 `-32002`，说明是参数问题、不是权限拒绝）。
新增 SSID = `uci.add wireless wifi-iface`（尽量用返回的 `section`，拿不到就用前后差集兜底）
→ 逐项 `uci.set` → `uci commit wireless` → `rc.init {"name":"network","action":"reload"}`。
注意 `getWirelessDevices` 里 `config.network` 是**数组**，uci 里是字符串，解析要当心。

**❌ 但 `file.write` 被 ACL 拒绝**：连写 `/tmp/app_probe.txt` 都返回 `ubus_code=6`；
`file.read` 读 OpenClash 自定义规则文件同样是 6（`file.list` / `file.stat` 反而可用）。
所以 **App 写不了 OpenClash 的分流规则**，「一 WiFi 一住宅 IP」需要的
`SRC-IP-CIDR,<子网>,<策略组>` 只能在 LuCI / SSH 里配；App 负责管 SSID + 显示映射 + 告警。

> 📌 无线页顶部那张「出口映射」卡片**已按需求删除**（用户反馈太占版面、影响观感），
> 下面这些读法保留备查 —— 以后要做类似的"某段流量从哪出去"的展示时别再重新踩一遍。
> 现在 SSID 的 network / 子网归属仍显示在每个 SSID 卡片里（`ap.netSubnet`）。

**出口映射怎么读**（纯读，不需要写权限）：
`uci network`（`ipaddr` 是数组且形如 `192.168.2.1/24`，要归一化成网络地址）→ 子网；
`uci firewall` 的 zone `network` 列表 → 归属区域；Clash API `/rules` 里
`type == "SRC-IP-CIDR"` 且 payload 命中该子网 → 策略组；`/rules` 最后一条 `MATCH` → 默认策略组；
再用 `/proxies` 取每个组当前的 `now`。
**不要**拿目的地址的 `IP-CIDR` / 域名规则去推断「这个 SSID 从哪出去」。

**设备备注存本机，不写路由器**：路由器上能改的是 `dhcp` 的静态租约 / hostname，
那会真的改变 dnsmasq 的分配行为；而备注只是给自己看的名字。实现是
`model/DeviceNotes.ets`（preferences，键用 **MAC 小写**：租约里 MAC 唯一且稳定，IP 会变、
hostname 可能是空的），界面用 `@CustomDialog` + `TextInput`（比在滚动列表里内联输入框好，
系统对话框会自动避让键盘）。清除备注就是把值存成空串 —— 别用 `delete`。

**发射功率**：`iwinfo.txpowerlist`（本机 0~23 dBm，`active` 标当前值）可枚举，
写 `wireless.<radio>.txpower`；选「自动」就 `uci delete` 掉该项，回到驱动默认。

**射频卡的折 / 展状态**：`RadioItem` 每次 `loadData()` 都重建，展开状态只存在对象里的话，
刷新一次（含写完配置后等 6 秒的那次重载）就会弹回默认。所以页面里另存一份
`expandedOverride: Record<section, boolean>`，`loadData` 时按它还原；默认值是
「射频开着就展开、关着就收起」（2.4G / 5G 两张卡都有「展开 / 收起」按钮）。
切换时别忘 `dataVersion + 1` —— `@Builder` 值传递参数不会触发刷新。

### 10. ⚠️ 页面刷新只有一种方式：下拉刷新（统一规范）

**策略的唯一来源是 `entry/src/main/ets/common/RefreshPolicy.ets`** —— 要改刷新行为就改那里。
四个 Tab 页 + 二级页面「在线设备」（含已冻结的 OpenClash 页）必须完全一致：

| `LoadKind` | 谁在用 | 屏幕上的表现 | 失败时 |
|---|---|---|---|
| `'first'` | `aboutToAppear` / 错误页的「重试」 | 整页 `LoadingProgress` | 切错误页（带「重试」按钮） |
| `'pull'` | `Refresh.onRefreshing` | 只有顶部下拉指示器 | **保留已有数据** + toast 提示 |
| `'quiet'` | 定时器 / 写完配置后的重新加载 | 什么都不显示 | 保留已有数据，只写日志 |

每页固定两个入口，不要再各写一套：

```typescript
private async loadData(kind: LoadKind = 'first'): Promise<void> {
  if (kind === 'first') { this.isLoading = true; }   // 只有首屏才切整页 Loading
  try {
    // ...取数据...
    this.hasError = false;                           // 成功就清错误页：静默刷新也能把错误页救回来
  } catch (e) {
    this.failLoad('加载异常: ' + JSON.stringify(e), kind);
  } finally {
    this.isLoading = false;
    this.isRefreshing = false;
  }
}

private failLoad(msg: string, kind: LoadKind): void {
  console.error('[页面名] ' + msg);
  if (shouldShowErrorPage(kind)) { this.hasError = true; this.errorMsg = msg; }
  else if (shouldToast(kind)) { notifyLoadFailed(msg); }
}

private onPullRefresh(): void {
  if (this.isRefreshing) return;
  this.isRefreshing = true;
  this.loadData('pull');
}
```

几条硬性要求：

1. **页面里不再放「刷新」按钮**（原来无线页头部的、仪表盘底部的都已删掉），刷新手势只有下拉一种。
2. 下拉必须**只切 `isRefreshing`**。一旦顺手写上 `isLoading = true`，`if (!isLoading)` 那整段内容会被卸载重建，
   退化成「整页转圈」，下拉指示器也会一起消失。
3. `'pull'` / `'quiet'` 失败**绝不能** `hasError = true`：那会把用户正在看的数据整页换成错误页。
4. 下拉指示器要落在**页面内容最上方**：可滚动内容（含标题 / 统计行）整体放进 `Refresh` 里，
   且 `Refresh` 的直接子节点必须是可滚动容器（`Scroll` / `List`）。
5. 盖在列表上面的空状态层要写 `.hitTestBehavior(HitTestMode.None)`，否则会把下拉手势吞掉。
6. 写配置期间（`busy`）用 `.pullToRefresh(!this.busy)` 关掉下拉，避免边写边刷。

### 11. ⚠️ 二级页面（在 App 内推入的新页面）用 Navigation，不要加 Tab、也不要用 router

**现状**：「在线设备」是仪表盘的二级页面 —— 点仪表盘「在线设备」卡片 →
`HomePage.openDevices()` → `pathStack.pushPathByName('devices', null)` →
`Navigation.navDestination(this.pageMap)` → `devicesDestination()` 里的 `NavDestination`。

要点（都踩过）：

1. `Navigation` 包在 `HomePage.build()` 最外层，`.mode(NavigationMode.Stack)` + `.hideTitleBar(true)`
   （标题栏自己画，才能跟 App 的渐变/深色主题一致）。推入的 `NavDestination` **会整页盖住标签栏**，
   这正是"二级页面"该有的样子；系统返回键、侧滑返回、转场动画都由框架负责，不用自己处理。
2. `navDestination(builder)` 的回调**只给页面名**（`(name: string, param: unknown)`），
   所以要在 `@Builder pageMap(name: string)` 里按 name 分发。
3. 标签栏被盖住后**没有别的东西铺背景**：`NavDestination` 里要自己铺一层渐变
   `.expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])`，
   否则状态栏/手势条区域会露出窗口底色。
4. 自定义组件（struct）**不能链式加通用属性**（`DevicesPage(...).layoutWeight(1)` 编译不过），
   要用一个 `Column() { DevicesPage(...) }.layoutWeight(1)` 包一层。
5. 页面组件与宿主解耦：二级页需要的数据/回调由宿主通过构造参数传
   （`DashboardPage({ client, onOpenDevices: () => this.openDevices() })`）；
   回调属性**不要写 `private`**，否则会多一条 ArkTS 警告。
6. 不要用 `@ohos.router`：它只能传可序列化参数，`OpenWrtClient` 这种对象传不过去。

### 12. ⚠️ 检查更新走 GitHub Releases：三个坑

「关于」页的检查更新 / 自动下载（`model/UpdateChecker.ets`）踩过的点：

1. **GitHub API 必须带 `User-Agent`**，不带直接 403。
2. **私有仓库匿名什么都拿不到**：`private=True` 时匿名调 `/repos/...` 是 403、附件下载是 404（正文只有 9 字节 "Not Found"）。
   本项目一开始仓库是私有的，检查更新因此完全走不通 —— 要么把仓库改 public（现在的做法），
   要么另开一个 public 的发布仓库；**不要把 token 写进 App**（能被反编译，而且会过期）。
3. **匿名 API 按 IP 限流 60 次/小时**，而这条链路走代理、出口 IP 与别人共用，很容易用光。
   所以 `fetchLatest()` 在 API 失败后会退到 **`https://github.com/<owner>/<repo>/releases.atom`**
   （网页端点，没有这个限制）拿版本号与正文，附件地址按发布惯例拼
   `OpenWrt-Manager-<tag>-unsigned.hap`。⚠️ atom 的 `<title>` 是 release **名字**（"OpenWrt 管理 v1.0.3"）
   而不是 tag —— 拿它当版本号会解析出 `[0,0,3]`，跟本机 `[1,0,3]` 一比就以为"已是最新"、**新版本被漏掉**；
   tag 要从 `<link href="…/releases/tag/<tag>">` 里取。

**更新包怎么下载（需求变更后：App 不自己下载）**

- 发现新版本只弹确认框，用户点「去浏览器下载」后 `startAbility`（`action: ohos.want.action.viewData` + `uri`）
  打开**系统浏览器**（模拟器上是 `com.huawei.hmos.browser`），下载与安装都由浏览器/文件管理完成 ——
  App 不落盘、不导出、不安装。所以「普通应用没有静默安装权限」（`bundle.installer` 是系统 API + `INSTALL_BUNDLE`）
  这件事不影响本流程。
- ⚠️ 直接附件地址（`releases/download/<tag>/<name>.hap`）在浏览器里会**再确认一次**（文件名 / 大小 / 立即下载），
  这是预期行为，不是 bug。原子兜底路径拼出来的地址也验证过可用。
- 曾经实现过「App 内 `requestInStream` 流式下载 + 进度 + 系统文件选择器导出」，后来按要求删掉了；
  那时的坑仍值得记：`requestInStream` 的**状态码回调常晚于 `dataEnd`**，不等一下就校验的话，
  会把 404 的 9 字节错误正文当成下载成功（必须比对预期字节数）。

### 13. 全屏沉浸式：内容能滚到状态栏 / 手势条后面

要做出华为图库那种「内容一直铺到屏幕物理顶端、从状态栏后面滚过去」的观感，三件事缺一不可
（每一步都在模拟器上逐像素验证过）：

1. **窗口全屏布局** —— `ThemeSettings.refreshSystemBar` 里 `win.setWindowLayoutFullScreen(true)`：
   页面从此从屏幕物理顶端开始铺（含状态栏 / 手势条区域），系统栏本身也已设成透明。
2. **两根栏都要脱离布局流、悬浮在内容之上**：
   - **顶栏**：`.position({ x: 0, y: 0 })` + `.zIndex(2)`，并且 `padding.top = topInset + SP_S`
     —— 玻璃从屏幕物理顶端铺下来，栏里的文字/按钮仍落在状态栏下方（不和时钟、电量打架）。
   - **底栏**：⚠️ 全屏后系统的 `BarPosition.End` 标签栏会**掉进手势条区域**，而 `barHeight` 只会让栏变高、
     连带把内容区往上挤（内容就又滚不到栏下面）。所以改成**自绘**：`Tabs.barHeight(0)` +
     一条自己算高度的 `Row`（复用 `tabItem()` builder，切页走 `TabsController.changeIndex()`），
     自绘的那条做成**悬浮胶囊**（不贴边 + 选中项药丸高亮），`margin.bottom = SP_S + bottomInset` 让开手势条。
     （曾经的 `Tabs.barOverlap(true)` 方案只能解决"越过安全区底边"，全屏后不够用。）
3. **两栏的材质＝液态玻璃**：**底色完全透明**（`backgroundColor(Color.Transparent)`）+ `backgroundEffect({ radius: 40, saturation: 1.4, brightness: 1.0, color: Color.Transparent })`。
   ⚠️ 别用 `backgroundBlurStyle(BlurStyle.…)` —— 那套「材质」自带色调（`c_bar` 那类半透明底就是这么来的），
   一路调到 10% 仍然不是「全透」；只有 `backgroundEffect` 的 `color` 设成透明才是纯模糊。
   边缘再加一条 1px 细线（顶栏底边 / 底栏顶边，用 `C_DIVIDER`）当玻璃边。（调色板里的 `c_bar` 因此已删除。）
4. **各页自己留避让** —— HomePage 量好避让区后写进 `AppStorage` 的 `safeTop` / `safeBottom`
   （= `topInset + HEADER_CONTENT_HEIGHT` / `bottomInset + TAB_BAR_CONTENT_HEIGHT`），
   各页用 `@StorageProp` 读（值变化会自动重排），当作内容 Column 的上下 padding。
   ⚠️ **不要给 Tabs 加 padding** —— 那会挤压内容区，内容就又滚不到栏下面了。

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
  & $hdc shell aa start -a EntryAbility -b com.abookkkk.wrt
  ```
- 抓日志：`hdc shell hilog -r`（清空）→ 操作 → `hdc shell "hilog -x"`，过滤 `JSAPP`
- 截图：`hdc shell snapshot_display -f /data/local/tmp/s.jpg` + `hdc file recv`
- 模拟器 `hdc shell` 是 **uid=2000(shell)，不是 root**。
- **不要在 DevEco 开着工程时并行跑命令行编译** —— 会让 IDE 状态错乱（运行配置丢设备、报「无法在 '<默认>' 上运行 'entry'」）。
