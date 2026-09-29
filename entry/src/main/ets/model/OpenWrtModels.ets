/**
 * OpenWrt ubus 数据模型定义
 */

// ===================== ubus JSON-RPC 通用结构 =====================

/** ubus JSON-RPC 通用响应体 */
export interface UbusResponse {
  jsonrpc: string;
  id: number;
  result: [number, Object];
}

/** ubus 调用返回的统一包装 */
export interface UbusResult<T> {
  success: boolean;
  code: number;
  data: T | null;
  error?: string;
}

// ===================== 登录相关 =====================

/** 登录成功返回的 session 信息 */
export interface SessionInfo {
  ubus_rpc_session: string;
  timeout: number;
  expires: number;
  acls: Record<string, Object>;
}

// ===================== 系统信息 =====================

/** 固件版本信息 */
export interface ReleaseInfo {
  distribution: string;
  version: string;
  revision: string;
  target: string;
  description: string;
}

/** system.board 返回 */
export interface SystemBoard {
  kernel: string;
  hostname: string;
  system: string;
  model: string;
  board_name: string;
  release: ReleaseInfo;
}

/** 内存信息（单位：字节） */
export interface MemoryInfo {
  total: number;
  free: number;
  shared: number;
  buffered: number;
  cached?: number;
  /** MemAvailable，估算的可用内存（字节） */
  available?: number;
}

/** 交换分区信息 */
export interface SwapInfo {
  total: number;
  free: number;
}

/** system.info 返回 */
export interface SystemInfo {
  uptime: number;
  localtime: number;
  load: number[];
  memory: MemoryInfo;
  swap: SwapInfo;
}

// ===================== 网络接口 =====================

/** 接口上的一个 IP 地址 */
export interface NetAddress {
  address: string;
  /** IPv4 是掩码位数（如 24），IPv6 是前缀长度 */
  mask: number;
}

/** 路由表项 */
export interface NetRoute {
  target: string;
  mask: number;
  nexthop: string;
}

/**
 * 网络接口（已从 ubus 原始返回映射成好用的形态）。
 *
 * ubus 原始字段名带连字符（`ipv4-address` / `dns-server` / `l3_device`），
 * 在 ArkTS 里不好直接用，所以由 OpenWrtClient.mapInterface() 转换一次。
 *
 * 注意：`network.interface dump` **不包含流量统计**，
 * 流量要另外调 `network.device status {"name":"<l3_device>"}` 拿 statistics。
 */
export interface NetworkInterface {
  /** 逻辑接口名：lan / loopback / wan / wan6 */
  name: string;
  proto: string;
  /** 配置里的设备 */
  device: string;
  /** 三层设备，查流量统计要用它 */
  l3Device: string;
  up: boolean;
  /** 已运行秒数 */
  uptime: number;
  ipv4: NetAddress[];
  ipv6: NetAddress[];
  /** 默认网关（从 route 里 target=0.0.0.0 那条取） */
  gateway: string;
  dns: string[];
  /** DHCP 拿到的服务器地址 */
  dhcpServer: string;
  /** DHCP 租期（秒） */
  leaseTime: number;

  // ---- 以下来自 network.device status ----
  rxBytes: number;
  txBytes: number;
  rxPackets: number;
  txPackets: number;
  rxErrors: number;
  txErrors: number;
  mtu: number;
  /** 链路速率，如 1000F；虚拟/无线设备可能为空 */
  speed: string;
  mac: string;
  devtype: string;
  /** 网桥成员设备 */
  bridgeMembers: string[];
  carrier: boolean;
  /** 设备状态是否取到了 */
  statsAvailable: boolean;
  /**
   * 是否在本页展示设备级统计（流量 / MTU / 速率 / MAC / 桥接成员）。
   *
   * wan 和 wan6 这类逻辑接口会共用同一个物理设备（l3_device 都是 wan），
   * 如果每个卡片都显示，就会看到两份一模一样的流量。
   * 所以只让第一个用到该设备的接口显示，其余置 false 并提示"见 xxx"。
   */
  showDeviceStats: boolean;
  /** 若设备统计已在别的接口上展示，这里给出那个接口名（用于提示） */
  deviceOwner: string;

  // ---- 实时速率（由页面定时采样算出，字节/秒）----
  /** 是否已能算出速率（需要至少两次采样） */
  rateReady: boolean;
  rxRate: number;
  txRate: number;
}

/** network.interface dump 的原始返回。字段名带连字符，只用于映射。 */
export interface NetworkDump {
  interface: Object[];
}

/**
 * 单个网卡的收发计数（来自 luci-rpc.getNetworkDevices 的 stats 字段）。
 * 用数组而不是 Record，避免 ArkTS 里 `record[key]` 取不到时的 undefined 类型问题。
 */
export interface NetDeviceStats {
  device: string;
  rxBytes: number;
  txBytes: number;
}

// ===================== DHCP 租约 =====================

/** DHCP 租约信息 */
export interface DhcpLease {
  mac: string;
  ip: string;
  hostname: string;
  start: number;
  end: number;
  duid?: string;
}

/** LuCI getDHCPLeases 返回的原始租约项 */
export interface LuciDhcpLease {
  expires?: number;
  ipaddr?: string;
  macaddr?: string;
  hostname?: string;
  duid?: string;
  clientid?: string;
}

/**
 * luci-rpc.getDHCPLeases 的返回体。
 * 注意：它是**对象**（含 dhcp_leases / dhcp6_leases 两个数组），不是裸数组。
 */
export interface LuciDhcpLeaseResponse {
  dhcp_leases?: LuciDhcpLease[];
  dhcp6_leases?: LuciDhcp6Lease[];
}

/** IPv6 DHCP 租约项 */
export interface LuciDhcp6Lease {
  expires?: number;
  interface?: string;
  hostname?: string;
  macaddr?: string;
  duid?: string;
  iaid?: string;
  ip6addr?: string;
  ip6addrs?: string[];
}

/**
 * rc.list 返回的单个服务状态。
 * 形如：{"openclash":{"start":99,"stop":15,"enabled":true,"running":true}}
 * 比 service.list 的 instances 嵌套结构好用得多，推荐用它判断服务是否在跑。
 */
export interface RcServiceState {
  start?: number;
  stop?: number;
  enabled?: boolean;
  running?: boolean;
}

/** getHostHints 返回的单个主机信息（MAC -> 信息） */
export interface HostHint {
  name?: string;
  ipaddrs?: string[];
  ip6addrs?: string[];
}

/**
 * Clash 的一个策略组（Selector / URLTest / Fallback）。
 * 只有 Selector 类型可以手动切换节点。
 */
export interface ClashGroup {
  name: string;
  /** Selector / URLTest / Fallback / LoadBalance */
  type: string;
  /** 当前选中的节点名 */
  now: string;
  /** 组内成员节点名 */
  members: string[];
  /** 各成员最近一次测速延迟（毫秒），-1 表示未知；与 members 一一对应 */
  memberDelays: number[];
  /** 是否能手动切换（只有 Selector 可以） */
  switchable: boolean;
}

/**
 * OpenClash 概览（汇总 Clash 外部控制 API 的 /version /configs /proxies /connections）
 */
export interface ClashOverview {
  version: string;
  /** rule / global / direct */
  mode: string;
  logLevel: string;
  allowLan: boolean;
  ipv6: boolean;
  /** 形如 "7890 / 7893 / 9090" */
  ports: string;
  /** 节点总数 */
  proxyCount: number;
  /** 形如 "Hysteria2 21 · Vless 19" */
  typeSummary: string;
  /** 活动连接数 */
  activeConnections: number;
  /** 累计下载（字节） */
  downloadTotal: number;
  /** 累计上传（字节） */
  uploadTotal: number;
  /** Clash 自身占用内存（字节） */
  memory: number;
  /** 策略组列表 */
  groups: ClashGroup[];
}

/**
 * OpenClash 的 uci 配置摘要（config 段）。
 *
 * OpenClash 没有自己的 ubus 对象，配置全在 uci 里，靠
 * uci.get {"config":"openclash","section":"config"} 读取。
 * 其中 dashboard_password 就是 Clash 外部控制 API 的密钥，
 * 请求 /version、/configs 时必须带 Authorization: Bearer <它>，否则返回 401。
 */
export interface OpenClashSettings {
  /** 总开关 enable */
  enabled: boolean;
  /** 运行模式：rule / global / direct */
  proxyMode: string;
  /** 外部控制端口 cn_port，默认 9090 */
  apiPort: number;
  /** 外部控制密钥 dashboard_password */
  apiSecret: string;
  /** HTTP 代理端口 */
  httpPort: string;
  /** 混合代理端口 */
  mixedPort: string;
}

// ===================== 无线（WiFi）相关 =====================

/**
 * iwinfo 信息（iwinfo.info / luci-rpc.getWirelessDevices 里的 iwinfo 字段）
 */
export interface IwinfoData {
  phy?: string;
  ssid?: string;
  bssid?: string;
  country?: string;
  mode?: string;
  channel?: number;
  center_chan1?: number;
  frequency?: number;
  txpower?: number;
  quality?: number;
  quality_max?: number;
  signal?: number;
  noise?: number;
  bitrate?: number;
  hwmodes_text?: string;
  htmodes?: string[] | string;
  hardware?: Record<string, Object>;
  encryption?: Record<string, Object>;
}

/** 无线接口（一个 AP）的配置 */
export interface WirelessIfaceConfig {
  device?: string;
  network?: string;
  mode?: string;
  ssid?: string;
  key?: string;
  encryption?: string;
  hidden?: boolean;
  disabled?: boolean;
}

/** 无线接口（一个 AP） */
export interface WirelessIface {
  section?: string;
  ifname?: string;
  config?: WirelessIfaceConfig;
  iwinfo?: IwinfoData;
}

/** 一个射频（radio0 / radio1） */
export interface WirelessRadio {
  up?: boolean;
  disabled?: boolean;
  autostart?: boolean;
  config?: Record<string, Object>;
  interfaces?: WirelessIface[];
  iwinfo?: IwinfoData;
}

/** 已连接的无线客户端（iwinfo.assoclist 里的一项） */
export interface WifiClientRate {
  bytes?: number;
  packets?: number;
  rate?: number;
  mhz?: number;
  mcs?: number;
  nss?: number;
}

export interface WifiClient {
  mac?: string;
  signal?: number;
  signal_avg?: number;
  noise?: number;
  inactive?: number;
  connected_time?: number;
  authorized?: boolean;
  authenticated?: boolean;
  rx?: WifiClientRate;
  tx?: WifiClientRate;
}

/** iwinfo.assoclist / iwinfo.scan / iwinfo.freqlist 的统一包装 */
export interface IwinfoListResponse<T> {
  results?: T[];
}

/** iwinfo.scan 扫到的一个邻居 AP */
export interface IwinfoScanResult {
  ssid?: string;
  bssid?: string;
  channel?: number;
  signal?: number;
  quality?: number;
  quality_max?: number;
  mode?: string;
  encryption?: Record<string, Object>;
}

/** iwinfo.freqlist 里的一个信道 */
export interface IwinfoFreq {
  channel?: number;
  mhz?: number;
  restricted?: boolean;
}

// ===================== 服务管理 =====================

/** 服务实例 */
export interface ServiceInstance {
  running: boolean;
  pid?: number[];
}

/** 服务状态 */
export interface ServiceStatus {
  name: string;
  running: boolean;
  pid?: number[];
  term_timeout?: number;
  instances?: Record<string, ServiceInstance>;
}

// ===================== HTTP 请求通用结果 =====================

/** HTTP 请求结果 */
export interface HttpResult {
  success: boolean;
  data?: string;
  error?: string;
  statusCode?: number;
}
