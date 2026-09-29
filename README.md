# WRT · OpenWrt 鸿蒙管理 App

用 **HarmonyOS（ArkTS + ArkUI）** 写的 OpenWrt 路由器管理客户端。直接调用路由器自带的 **ubus JSON-RPC** 接口（`/ubus`），不依赖 LuCI 网页、不需要装 `luci-mod-rpc`。

> 开发验证环境：小米路由器 AX3000T（MediaTek MT7981）刷 OpenWrt 25.12.5

---

## 功能

- **登录与会话持久化** —— 用 `@ohos.data.preferences` 保存地址与 session，下次打开自动恢复登录
- **仪表盘** —— 设备型号、OpenWrt 版本、内核版本、主机名、运行时长、CPU 负载（1/5/15 分钟）、内存占用、在线设备数；30 秒静默自动刷新
- **网络接口** —— 各接口的协议、设备、连接状态
- **无线网络** —— 每个射频的开关（2.4G/5G 独立）、WiFi 名称、密码、隐藏 SSID 开关；已连接设备列表（信号强度、收发流量、在线时长）与一键断开；周边 WiFi 扫描
- **在线设备** —— DHCP 租约列表（主机名、MAC、IP、剩余租期）
- **OpenClash** —— 运行状态、内核版本、运行模式、HTTP 端口、是否允许局域网；一键重启

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

## 项目结构

```
entry/src/main/
├── module.json5                     # 权限 + 明文 HTTP metadata
├── resources/base/profile/
│   └── network_config.json          # 明文 HTTP 白名单
└── ets/
    ├── model/
    │   ├── OpenWrtClient.ets        # ubus JSON-RPC 客户端（核心，全部网络调用都在这）
    │   ├── OpenWrtModels.ets        # 数据模型 / 接口定义
    │   ├── SessionStore.ets         # 会话本地持久化
    │   └── GlobalContext.ets        # 全局 Context 单例
    └── pages/
        ├── Index.ets                # 入口：未登录→LoginPage，已登录→HomePage
        ├── LoginPage.ets            # 登录页
        ├── HomePage.ets             # Tabs 容器（4 个 Tab）
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

- [ ] `bundleName` 还是默认的 `com.example.myapplication`，正式发布前需要改
- [ ] 网络接口页的收发流量暂时显示 `0 B`（`network.interface.dump` 默认不返回流量统计）
- [ ] 无线页暂未做**信道选择下拉**（`iwinfo.freqlist` 已能取到信道列表）
- [ ] 无线页暂未做**发射功率 / 频宽 (HT mode) 调整**
- [ ] 暂未做 OpenClash 节点切换 / 订阅管理
- [ ] 暂未做路由器重启按钮（`system.reboot` 已可用）
