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

/** 内存信息 */
export interface MemoryInfo {
  total: number;
  free: number;
  shared: number;
  buffered: number;
  cached?: number;
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

/** 接口流量统计数据 */
export interface TrafficData {
  rx_bytes?: number;
  tx_bytes?: number;
  rx_packets?: number;
  tx_packets?: number;
  rx_errors?: number;
  tx_errors?: number;
}

/** 网络接口信息 */
export interface NetworkInterface {
  interface: string;
  proto: string;
  up: boolean;
  device: string;
  ipaddr?: string;
  netmask?: string;
  gateway?: string;
  dns?: string[];
  ip6addr?: string[];
  dns6?: string[];
  metric?: string;
  data?: TrafficData;
}

/** network.interface dump 返回 */
export interface NetworkDump {
  interface: NetworkInterface[];  // 注意：OpenWrt API 返回的字段名是 interface (单数)
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
