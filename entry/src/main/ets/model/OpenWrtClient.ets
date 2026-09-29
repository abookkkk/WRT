/**
 * OpenWrt ubus 网络请求工具类
 * 
 * 通过 OpenWrt 的 /ubus JSON-RPC 2.0 端点通信。
 * @ohos.net.http 模块实现，纯 ArkTS，零外部依赖。
 * 
 * 注意：ArkTS 严格模式禁止对象字面量，
 * 所有参数对象通过 JSON.parse 构建。
 */

import http from '@ohos.net.http';
import { BusinessError } from '@kit.BasicServicesKit';
import type {
  UbusResponse,
  UbusResult,
  SessionInfo,
  SystemBoard,
  SystemInfo,
  NetworkDump,
  NetworkInterface,
  NetAddress,
  DhcpLease,
  LuciDhcpLease,
  LuciDhcpLeaseResponse,
  RcServiceState,
  HostHint,
  ServiceInstance,
  ServiceStatus,
  OpenClashSettings,
  WirelessRadio,
  WifiClient,
  IwinfoListResponse,
  IwinfoScanResult,
  IwinfoFreq,
  HttpResult
} from './OpenWrtModels';

const ANONYMOUS_SESSION: string = '00000000000000000000000000000000';
const DEFAULT_TIMEOUT: number = 10000;
let requestIdCounter: number = 0;

/**
 * 构建 JSON 对象（ArkTS 安全方式）
 * 由于 ArkTS 禁止对象字面量，使用 JSON.parse 替代
 */
function json(text: string): Object {
  return JSON.parse(text);
}

export class OpenWrtClient {
  private baseUrl: string;
  private host: string;
  private httpClient: http.HttpRequest;
  private sessionId: string = '';
  private loggedIn: boolean = false;
  private connectTimeout: number;
  private readTimeout: number;

  constructor(
    host: string,
    port: number = 80,
    useHttps: boolean = false,
    connectTimeout: number = DEFAULT_TIMEOUT,
    readTimeout: number = DEFAULT_TIMEOUT
  ) {
    const protocol: string = useHttps ? 'https' : 'http';
    this.host = host;
    this.baseUrl = `${protocol}://${host}:${port}`;
    this.connectTimeout = connectTimeout;
    this.readTimeout = readTimeout;
    this.httpClient = http.createHttp();
  }

  async login(username: string, password: string): Promise<boolean> {
    try {
      const result: UbusResult<SessionInfo> = await this.ubusCall<SessionInfo>(
        ANONYMOUS_SESSION,
        'session',
        'login',
        json(`{"username":"${username}","password":"${password}"}`)
      );
      if (result.success && result.data) {
        this.sessionId = result.data.ubus_rpc_session;
        this.loggedIn = true;
        return true;
      }
      return false;
    } catch (e) {
      console.error(`[OpenWrtClient] 登录异常: ${JSON.stringify(e)}`);
      return false;
    }
  }

  isLoggedIn(): boolean {
    return this.loggedIn && this.sessionId.length > 0;
  }

  getSessionId(): string {
    return this.sessionId;
  }

  restoreSession(sessionId: string): void {
    if (sessionId && sessionId.length === 32) {
      this.sessionId = sessionId;
      this.loggedIn = true;
    }
  }

  /** 路由器 IP / 主机名（不含协议和端口） */
  getHost(): string {
    return this.host;
  }

  /** 基础地址，形如 http://192.168.2.1:80 */
  getBaseUrl(): string {
    return this.baseUrl;
  }

  /**
   * 读取 OpenClash 的 uci 配置摘要（config 段）。
   *
   * 用途：拿到 Clash 外部控制 API 的端口和密钥。
   * dashboard_password 就是 API 密钥，不带它请求 9090 端口会返回 401。
   * 注意不能用 file.read 去读 /etc/openclash/*.yaml —— ACL 没放行，返回 code 6。
   */
  async getOpenClashSettings(): Promise<OpenClashSettings | null> {
    const r: UbusResult<Record<string, Object>> = await this.ubusCallAuth<Record<string, Object>>(
      'uci', 'get', json('{"config":"openclash","section":"config"}')
    );
    if (!r.success || !r.data) {
      console.error(`[OpenWrtClient] getOpenClashSettings 失败: success=${r.success} code=${r.code} err=${r.error}`);
      return null;
    }

    const values: Record<string, Object> | undefined = r.data['values'] as Record<string, Object>;
    if (!values) {
      console.error(`[OpenWrtClient] getOpenClashSettings 无 values: ${JSON.stringify(r.data).substring(0, 160)}`);
      return null;
    }

    const settings: OpenClashSettings = {
      enabled: String(values['enable'] || '0') === '1',
      proxyMode: String(values['proxy_mode'] || ''),
      apiPort: parseInt(String(values['cn_port'] || '9090')) || 9090,
      apiSecret: String(values['dashboard_password'] || ''),
      httpPort: String(values['http_port'] || ''),
      mixedPort: String(values['mixed_port'] || '')
    };
    return settings;
  }

  /**
   * 切换 OpenClash 运行模式（rule / global / direct）。
   * 走 uci set + commit，然后需要重启服务才生效。
   */
  async setOpenClashMode(mode: string): Promise<boolean> {
    const setResult: UbusResult<Object> = await this.ubusCallAuth<Object>(
      'uci', 'set', json(`{"config":"openclash","section":"config","values":{"proxy_mode":"${mode}"}}`)
    );
    if (!setResult.success) {
      return false;
    }
    const commitResult: UbusResult<Object> = await this.ubusCallAuth<Object>(
      'uci', 'commit', json('{"config":"openclash"}')
    );
    return commitResult.success;
  }

  /**
   * 切换 OpenClash 总开关（enable）。
   * 打开后建议再调 restartService('openclash') 让其生效。
   */
  async setOpenClashEnabled(enabled: boolean): Promise<boolean> {
    const flag: string = enabled ? '1' : '0';
    const setResult: UbusResult<Object> = await this.ubusCallAuth<Object>(
      'uci', 'set', json(`{"config":"openclash","section":"config","values":{"enable":"${flag}"}}`)
    );
    if (!setResult.success) {
      return false;
    }
    const commitResult: UbusResult<Object> = await this.ubusCallAuth<Object>(
      'uci', 'commit', json('{"config":"openclash"}')
    );
    return commitResult.success;
  }

  // ======================== 无线（WiFi） ========================

  /**
   * 读取全部无线设备状态：射频开关、SSID、是否隐藏、密钥、接口名、信道、发射功率。
   * 一次调用就能拿全，比解析 uci 方便得多，推荐做 WiFi 页的首选数据源。
   */
  async getWirelessDevices(): Promise<UbusResult<Record<string, WirelessRadio>>> {
    return this.ubusCallAuth<Record<string, WirelessRadio>>(
      'luci-rpc', 'getWirelessDevices', json('{}')
    );
  }

  /**
   * 读取某个 AP 接口上已连接的客户端。
   *
   * 注意：不要用 hostapd.<iface>.get_clients —— ACL 没放行会返回 -32002，
   * 必须用 iwinfo.assoclist（在白名单里）。
   *
   * @param ifname 接口名，从 getWirelessDevices() 的 interfaces[].ifname 取，如 phy1-ap0
   */
  async getWifiClients(ifname: string): Promise<UbusResult<WifiClient[]>> {
    const r: UbusResult<IwinfoListResponse<WifiClient>> =
      await this.ubusCallAuth<IwinfoListResponse<WifiClient>>(
        'iwinfo', 'assoclist', json(`{"device":"${ifname}"}`)
      );
    if (!r.success || !r.data) {
      return { success: false, code: r.code, data: null, error: r.error || '获取客户端失败' };
    }
    return { success: true, code: 0, data: r.data.results || [] };
  }

  /**
   * 扫描周边 WiFi。
   *
   * 实测坑：当 5G 跑在 HE160（占用跨 DFS 的宽信道）时，MT7981 驱动会拒绝后台扫描，
   * 返回空数组 —— 在路由器上直接跑 iw scan 也是 0 个 BSS，报
   * "Netlink error while awaiting scan results"。
   * 所以页面必须能优雅处理"扫不到"的情况，并提示用户可能是带宽太宽导致的。
   */
  async scanWifi(ifname: string): Promise<UbusResult<IwinfoScanResult[]>> {
    const r: UbusResult<IwinfoListResponse<IwinfoScanResult>> =
      await this.ubusCallAuth<IwinfoListResponse<IwinfoScanResult>>(
        'iwinfo', 'scan', json(`{"device":"${ifname}"}`)
      );
    if (!r.success || !r.data) {
      return { success: false, code: r.code, data: null, error: r.error || '扫描失败' };
    }
    return { success: true, code: 0, data: r.data.results || [] };
  }

  /** 该射频支持的信道列表（iwinfo.freqlist） */
  async getWifiChannels(ifname: string): Promise<UbusResult<IwinfoFreq[]>> {
    const r: UbusResult<IwinfoListResponse<IwinfoFreq>> =
      await this.ubusCallAuth<IwinfoListResponse<IwinfoFreq>>(
        'iwinfo', 'freqlist', json(`{"device":"${ifname}"}`)
      );
    if (!r.success || !r.data) {
      return { success: false, code: r.code, data: null, error: r.error || '获取信道列表失败' };
    }
    return { success: true, code: 0, data: r.data.results || [] };
  }

  /**
   * 写一个 wireless 配置项（只写到内存，还没 commit）。
   * 改完所有项后要调 commitWifi() + applyWifi() 才真正生效。
   *
   * @param section uci section 名，射频用 radio0/radio1，AP 用 default_radio0/default_radio1
   */
  async setWifiOption(section: string, option: string, value: string): Promise<boolean> {
    const r: UbusResult<Object> = await this.ubusCallAuth<Object>(
      'uci', 'set',
      json(`{"config":"wireless","section":"${section}","values":{"${option}":"${value}"}}`)
    );
    return r.success;
  }

  /** 提交 wireless 配置变更 */
  async commitWifi(): Promise<boolean> {
    const r: UbusResult<Object> = await this.ubusCallAuth<Object>(
      'uci', 'commit', json('{"config":"wireless"}')
    );
    return r.success;
  }

  /**
   * 应用无线配置（让改动真正生效）。
   * 实测：rc.init + network reload 可用，而且不会踢掉已经连着的客户端。
   */
  async applyWifi(): Promise<boolean> {
    const r: UbusResult<Object> = await this.ubusCallAuth<Object>(
      'rc', 'init', json('{"name":"network","action":"reload"}')
    );
    return r.success;
  }

  /**
   * 踢掉一个无线客户端。
   *
   * 对象名必须是 hostapd.<ifname>，例如 hostapd.phy1-ap0。
   * @param banTimeMs 拉黑时长（毫秒），传 0 表示只断开不拉黑，客户端可以立刻重连
   */
  async kickWifiClient(ifname: string, mac: string, banTimeMs: number = 0): Promise<UbusResult<Object>> {
    return this.ubusCallAuth<Object>(
      `hostapd.${ifname}`, 'del_client',
      json(`{"addr":"${mac}","deauth":true,"ban_time":${banTimeMs}}`)
    );
  }

  async getSystemBoard(): Promise<UbusResult<SystemBoard>> {
    return this.ubusCallAuth<SystemBoard>('system', 'board', json('{}'));
  }

  async getSystemInfo(): Promise<UbusResult<SystemInfo>> {
    return this.ubusCallAuth<SystemInfo>('system', 'info', json('{}'));
  }

  async getNetworkDump(): Promise<UbusResult<NetworkDump>> {
    return this.ubusCallAuth<NetworkDump>('network.interface', 'dump', json('{}'));
  }

  /**
   * 读取全部网络接口，并把流量统计一起补上（推荐用这个）。
   *
   * 为什么不能只用 dump：
   *   `network.interface dump` 的 `data` 字段是空的，**不含流量统计**；
   *   流量的 `statistics.rx_bytes / tx_bytes` 在 `network.device status` 里。
   * 所以 N 个接口会发 N+1 个请求。
   */
  async getNetworkInterfaces(): Promise<UbusResult<NetworkInterface[]>> {
    const dump: UbusResult<NetworkDump> =
      await this.ubusCallAuth<NetworkDump>('network.interface', 'dump', json('{}'));
    if (!dump.success || !dump.data) {
      return { success: false, code: dump.code, data: null, error: dump.error || '获取接口失败' };
    }

    const rawList: Object[] = dump.data.interface || [];
    const out: NetworkInterface[] = [];
    // 记录已经展示过设备统计的 l3_device，避免 wan / wan6 重复显示同一份流量
    const seenDevices: string[] = [];

    for (let i = 0; i < rawList.length; i++) {
      const item: NetworkInterface = this.mapInterface(rawList[i]);

      if (item.l3Device.length > 0) {
        const st: UbusResult<Record<string, Object>> =
          await this.ubusCallAuth<Record<string, Object>>(
            'network.device', 'status', json(`{"name":"${item.l3Device}"}`)
          );
        if (st.success && st.data) {
          this.applyDeviceStatus(item, st.data);
        }
      }

      // 同一个物理设备只展示一次设备级统计
      item.showDeviceStats = item.statsAvailable && seenDevices.indexOf(item.l3Device) < 0;
      if (item.showDeviceStats) {
        seenDevices.push(item.l3Device);
      } else {
        item.deviceOwner = this.findDisplayOwner(out, item.l3Device);
      }

      out.push(item);
    }

    return { success: true, code: 0, data: out };
  }

  /** 找出已经展示过该设备统计的接口名（用于提示"见 WAN"） */
  private findDisplayOwner(list: NetworkInterface[], l3Device: string): string {
    for (let i = 0; i < list.length; i++) {
      if (list[i].l3Device === l3Device && list[i].showDeviceStats) {
        return list[i].name.toUpperCase();
      }
    }
    return '';
  }

  /** 把 ubus 的原始接口对象（字段名带连字符）映射成好用的模型 */
  private mapInterface(raw: Object): NetworkInterface {
    const r: Record<string, Object> = raw as Record<string, Object>;

    const item: NetworkInterface = {
      name: String(r['interface'] || ''),
      proto: String(r['proto'] || ''),
      device: String(r['device'] || ''),
      l3Device: String(r['l3_device'] || r['device'] || ''),
      up: r['up'] === true,
      uptime: this.toNumber(r['uptime']),
      ipv4: this.toAddresses(r['ipv4-address']),
      ipv6: this.toAddresses(r['ipv6-address']),
      gateway: this.findGateway(r['route']),
      dns: this.toStringList(r['dns-server']),
      dhcpServer: '',
      leaseTime: 0,
      rxBytes: 0,
      txBytes: 0,
      rxPackets: 0,
      txPackets: 0,
      rxErrors: 0,
      txErrors: 0,
      mtu: 0,
      speed: '',
      mac: '',
      devtype: '',
      bridgeMembers: [],
      carrier: false,
      statsAvailable: false,
      showDeviceStats: false,
      deviceOwner: ''
    };

    // DHCP 拿到的服务器 / 租期在 data 里
    const data: Record<string, Object> | undefined = r['data'] as Record<string, Object>;
    if (data) {
      item.dhcpServer = String(data['dhcpserver'] || '');
      item.leaseTime = this.toNumber(data['leasetime']);
    }
    return item;
  }

  /** 把 network.device status 的内容补到接口上（流量、速率、MTU、桥接成员） */
  private applyDeviceStatus(item: NetworkInterface, d: Record<string, Object>): void {
    item.statsAvailable = true;
    item.mtu = this.toNumber(d['mtu']);
    item.speed = String(d['speed'] || '');
    item.mac = String(d['macaddr'] || '');
    item.devtype = String(d['devtype'] || '');
    item.carrier = d['carrier'] === true;
    item.bridgeMembers = this.toStringList(d['bridge-members']);

    const stats: Record<string, Object> | undefined = d['statistics'] as Record<string, Object>;
    if (stats) {
      item.rxBytes = this.toNumber(stats['rx_bytes']);
      item.txBytes = this.toNumber(stats['tx_bytes']);
      item.rxPackets = this.toNumber(stats['rx_packets']);
      item.txPackets = this.toNumber(stats['tx_packets']);
      item.rxErrors = this.toNumber(stats['rx_errors']);
      item.txErrors = this.toNumber(stats['tx_errors']);
    }
  }

  /** Object -> number（ubus 里数字可能是 number 也可能是字符串） */
  private toNumber(v: Object | undefined): number {
    if (v === undefined || v === null) {
      return 0;
    }
    const n: number = parseInt(String(v));
    return isNaN(n) ? 0 : n;
  }

  /** Object -> string[] */
  private toStringList(v: Object | undefined): string[] {
    const out: string[] = [];
    if (v === undefined || v === null || !Array.isArray(v)) {
      return out;
    }
    const arr: Object[] = v as Object[];
    for (let i = 0; i < arr.length; i++) {
      out.push(String(arr[i]));
    }
    return out;
  }

  /** Object -> NetAddress[]（ipv4-address / ipv6-address 的形状） */
  private toAddresses(v: Object | undefined): NetAddress[] {
    const out: NetAddress[] = [];
    if (v === undefined || v === null || !Array.isArray(v)) {
      return out;
    }
    const arr: Object[] = v as Object[];
    for (let i = 0; i < arr.length; i++) {
      const o: Record<string, Object> = arr[i] as Record<string, Object>;
      const a: NetAddress = {
        address: String(o['address'] || ''),
        mask: this.toNumber(o['mask'])
      };
      out.push(a);
    }
    return out;
  }

  /** 从 route 列表里找默认网关（target 0.0.0.0 且 mask 0） */
  private findGateway(v: Object | undefined): string {
    if (v === undefined || v === null || !Array.isArray(v)) {
      return '';
    }
    const arr: Object[] = v as Object[];
    for (let i = 0; i < arr.length; i++) {
      const o: Record<string, Object> = arr[i] as Record<string, Object>;
      if (String(o['target'] || '') === '0.0.0.0' && this.toNumber(o['mask']) === 0) {
        return String(o['nexthop'] || '');
      }
    }
    return '';
  }

  /**
   * 获取 DHCP 租约（在线设备列表）。
   *
   * 重要：必须调用 luci-rpc 对象，不要用 luci 对象：
   *   luci.getDHCPLeases      -> -32002 Access denied（luci 上根本没有这个方法）
   *   luci-rpc.getDHCPLeases  -> 正常返回
   * luci-rpc 由 rpcd-mod-luci 提供，本机已安装。
   *
   * 另外：不要用 file.read 读 /tmp/dhcp.leases 兜底 —— ACL 只放行了固定路径清单，
   * /tmp/dhcp.leases 不在清单里，会返回 ubus code 6（权限拒绝）。
   */
  async getDhcpLeases(): Promise<UbusResult<DhcpLease[]>> {
    const resp = await this.ubusCallAuth<LuciDhcpLeaseResponse>(
      'luci-rpc', 'getDHCPLeases', json('{"family":0}')
    );

    if (!resp.success || !resp.data) {
      return {
        success: false,
        code: resp.code,
        data: null,
        error: resp.error || '获取 DHCP 租约失败'
      };
    }

    // 返回体是 { dhcp_leases: [...], dhcp6_leases: [...] }，不是裸数组
    const raw: LuciDhcpLease[] = resp.data.dhcp_leases || [];
    const leases: DhcpLease[] = [];
    const now: number = Math.floor(Date.now() / 1000);

    for (let i = 0; i < raw.length; i++) {
      const item: LuciDhcpLease = raw[i];
      // dnsmasq 用 '*' 表示未知主机名，统一转成空字符串，由页面兜底显示
      const hostname: string = (item.hostname && item.hostname !== '*') ? item.hostname : '';

      // expires 是剩余秒数；<0 表示永久租约
      let endTime: number;
      if (typeof item.expires === 'number') {
        endTime = item.expires < 0 ? now + (365 * 24 * 3600) : now + item.expires;
      } else {
        endTime = 0;
      }

      leases.push({
        mac: item.macaddr || '',
        ip: item.ipaddr || '',
        hostname: hostname,
        start: 0,
        end: endTime,
        duid: item.duid
      });
    }

    return { success: true, code: 0, data: leases };
  }

  /**
   * 获取全部已知主机（MAC -> 名称/IP），来源 luci-rpc.getHostHints。
   * 比 DHCP 租约更全：含静态主机、路由器自身、以及 ARP 表里还在的设备。
   */
  async getHostHints(): Promise<UbusResult<Record<string, HostHint>>> {
    return this.ubusCallAuth<Record<string, HostHint>>('luci-rpc', 'getHostHints', json('{}'));
  }

  /**
   * 重启服务。
   *
   * 重要：不要用 service.restart —— ACL 只给 service 对象放行了 list，
   * 调 service.restart 会返回 -32002 Access denied。
   * 必须走 rc.init：rc.list / rc.init 都在 ACL 白名单里。
   */
  async restartService(serviceName: string): Promise<UbusResult<Object>> {
    return this.ubusCallAuth<Object>('rc', 'init', json(`{"name":"${serviceName}","action":"restart"}`));
  }

  /** 启动服务（同样走 rc.init） */
  async startService(serviceName: string): Promise<UbusResult<Object>> {
    return this.ubusCallAuth<Object>('rc', 'init', json(`{"name":"${serviceName}","action":"start"}`));
  }

  /** 停止服务（同样走 rc.init） */
  async stopService(serviceName: string): Promise<UbusResult<Object>> {
    return this.ubusCallAuth<Object>('rc', 'init', json(`{"name":"${serviceName}","action":"stop"}`));
  }

  async listServices(serviceName?: string): Promise<UbusResult<Record<string, ServiceStatus>>> {
    let args: Object;
    if (serviceName) {
      args = json(`{"name":"${serviceName}"}`);
    } else {
      args = json('{}');
    }
    return this.ubusCallAuth<Record<string, ServiceStatus>>('service', 'list', args);
  }

  /**
   * 查询服务状态（running / enabled）。
   *
   * 用 rc.list：直接返回 {running, enabled}，形如
   *   {"openclash":{"start":99,"stop":15,"enabled":true,"running":true}}
   *
   * 注意不要用 service.list 的顶层 running —— 实际结构是嵌套在
   *   data["openclash"].instances["openclash"].running
   * 里面的，顶层根本没有 running 字段，取到的永远是 undefined。
   */
  async getServiceState(serviceName: string): Promise<RcServiceState | null> {
    const result: UbusResult<Record<string, RcServiceState>> =
      await this.ubusCallAuth<Record<string, RcServiceState>>(
        'rc', 'list', json(`{"name":"${serviceName}"}`)
      );
    if (result.success && result.data) {
      const state: RcServiceState | undefined = result.data[serviceName];
      return state || null;
    }
    return null;
  }

  async isServiceRunning(serviceName: string): Promise<boolean> {
    const state: RcServiceState | null = await this.getServiceState(serviceName);
    if (state && typeof state.running === 'boolean') {
      return state.running;
    }

    // rc.list 不可用时退回 service.list，按 instances 嵌套结构判断
    const result: UbusResult<Record<string, ServiceStatus>> = await this.listServices(serviceName);
    if (result.success && result.data) {
      const svc: ServiceStatus | undefined = result.data[serviceName];
      if (svc && svc.instances) {
        const keys: string[] = Object.keys(svc.instances);
        for (let i = 0; i < keys.length; i++) {
          const inst: ServiceInstance | undefined = svc.instances[keys[i]];
          if (inst && inst.running === true) {
            return true;
          }
        }
      }
    }
    return false;
  }

  async getFormattedUptime(): Promise<string> {
    const result: UbusResult<SystemInfo> = await this.getSystemInfo();
    if (result.success && result.data) {
      return this.formatUptime(result.data.uptime);
    }
    return '获取失败';
  }

  async getMemoryUsagePercent(): Promise<number> {
    const result: UbusResult<SystemInfo> = await this.getSystemInfo();
    if (result.success && result.data) {
      const mem = result.data.memory;
      const used: number = mem.total - mem.free - mem.buffered - (mem.cached || 0);
      return Math.round((used / mem.total) * 100);
    }
    return 0;
  }

  async getOnlineDeviceCount(): Promise<number> {
    const result: UbusResult<DhcpLease[]> = await this.getDhcpLeases();
    if (result.success && result.data) {
      const now: number = Math.floor(Date.now() / 1000);
      return result.data.filter((lease: DhcpLease) => lease.end > now).length;
    }
    return 0;
  }

  // ======================== 核心 ubus 调用 ========================

  /** 带身份认证的 ubus 调用（自动携带 sessionId） */
  private async ubusCallAuth<T>(
    obj: string, func: string, args: Object
  ): Promise<UbusResult<T>> {
    if (!this.loggedIn || !this.sessionId) {
      return { success: false, code: -1, data: null, error: '未登录，请先调用 login()' };
    }
    return this.ubusCall<T>(this.sessionId, obj, func, args);
  }

  /** 底层 ubus 调用 */
  private async ubusCall<T>(
    sessionId: string, obj: string, func: string, args: Object
  ): Promise<UbusResult<T>> {
    const requestId: number = ++requestIdCounter;

    // 手动构建 JSON-RPC 请求字符串（避免对象字面量）
    const bodyStr: string = `{"jsonrpc":"2.0","id":${requestId},"method":"call",` +
      `"params":["${sessionId}","${obj}","${func}",${JSON.stringify(args)}]}`;

    try {
      const response: HttpResult = await this.httpRequest(
        `${this.baseUrl}/ubus`, bodyStr
      );

      if (!response.success) {
        return { success: false, code: -2, data: null, error: response.error || 'HTTP 请求失败' };
      }

      const text: string = response.data || '{}';
      const ubusResp: UbusResponse = JSON.parse(text);
      const ubusCode: number = ubusResp.result[0] as number;

      if (ubusCode === 0) {
        return { success: true, code: 0, data: ubusResp.result[1] as T };
      } else {
        return { success: false, code: ubusCode, data: null, error: `ubus 调用失败，返回码: ${ubusCode}` };
      }
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      return { success: false, code: -3, data: null, error: `请求异常: ${err.message || JSON.stringify(e)}` };
    }
  }

  // ======================== HTTP 底层请求 ========================

  private httpRequest(url: string, bodyStr: string): Promise<HttpResult> {
    return new Promise<HttpResult>((resolve) => {
      const headers: Record<string, string> = {
        'Content-Type': 'application/json',
        'Accept': 'application/json'
      };

      const requestOptions: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: bodyStr,
        connectTimeout: this.connectTimeout,
        readTimeout: this.readTimeout
      };

      this.httpClient.request(url, requestOptions, (err: BusinessError | null, data: http.HttpResponse) => {
        if (err) {
          resolve({ success: false, error: `网络错误: ${err.message}`, statusCode: err.code });
          return;
        }

        const statusCode: number = data.responseCode;
        if (statusCode >= 200 && statusCode < 300) {
          resolve({ success: true, data: data.result as string, statusCode });
        } else {
          resolve({ success: false, data: data.result as string, error: `HTTP ${statusCode}`, statusCode });
        }
      });
    });
  }

  private formatUptime(seconds: number): string {
    const days: number = Math.floor(seconds / 86400);
    const hours: number = Math.floor((seconds % 86400) / 3600);
    const minutes: number = Math.floor((seconds % 3600) / 60);
    const parts: string[] = [];
    if (days > 0) parts.push(`${days} 天`);
    if (hours > 0) parts.push(`${hours} 小时`);
    if (minutes > 0) parts.push(`${minutes} 分钟`);
    if (parts.length === 0) parts.push('不到 1 分钟');
    return parts.join(' ');
  }

  async ping(): Promise<boolean> {
    try {
      const result: UbusResult<Record<string, string>> =
        await this.ubusCall<Record<string, string>>(ANONYMOUS_SESSION, 'system', 'board', json('{}'));
      return result.success;
    } catch {
      return false;
    }
  }

  destroy(): void {
    try {
      this.httpClient.destroy();
    } catch (e) {
      console.error(`[OpenWrtClient] 销毁异常: ${JSON.stringify(e)}`);
    }
    this.sessionId = '';
    this.loggedIn = false;
  }
}
