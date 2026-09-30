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
  NetDeviceStats,
  DhcpLease,
  LuciDhcpLease,
  LuciDhcpLeaseResponse,
  RcServiceState,
  HostHint,
  ServiceInstance,
  ServiceStatus,
  OpenClashSettings,
  ClashGroup,
  ClashOverview,
  ClashRule,
  WirelessRadio,
  WifiClient,
  WifiConfig,
  WifiDeviceCfg,
  WifiIfaceCfg,
  NetworkCfg,
  IwinfoListResponse,
  IwinfoScanResult,
  IwinfoFreq,
  HttpResult
} from './OpenWrtModels';

const ANONYMOUS_SESSION: string = '00000000000000000000000000000000';
const DEFAULT_TIMEOUT: number = 10000;
/**
 * JSON-RPC 层"权限被拒"。rpcd 的 session 默认 300 秒空闲就失效，
 * 之后任何业务调用都返回这个码（等价于匿名 session），据此判断"登录已过期"。
 */
const SESSION_EXPIRED_CODE: number = -32002;
let requestIdCounter: number = 0;

/** 统计节点类型用的小结构（ArkTS 里 Record 取不到 key 时类型是 undefined，不方便） */
class ClashTypeCount {
  type: string = '';
  count: number = 0;
}

/** 节点名 → 最近延迟（毫秒） */
class ClashDelay {
  name: string = '';
  delay: number = -1;
}

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
  /** 会话过期回调（由 Index 注册，用于统一退回登录页） */
  private onSessionExpiredCb?: () => void;
  /** 只通知一次：并发请求可能同时撞上过期，避免刷屏 */
  private sessionExpiredFired: boolean = false;

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
        this.sessionExpiredFired = false;
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
      this.sessionExpiredFired = false;
    }
  }

  /**
   * 注册"会话已过期"回调。
   *
   * 为什么需要：rpcd 的 session 300 秒空闲就失效，而密码不落地（安全考虑），
   * App 无法自动重登。所以一旦某个调用拿到 -32002，就统一通知上层退回登录页，
   * 而不是让用户在每个页面看到"获取失败 / 请求异常"却不知道为什么。
   */
  setOnSessionExpired(cb: () => void): void {
    this.onSessionExpiredCb = cb;
    this.sessionExpiredFired = false;
  }

  /** 当前是否处于"已登录且未被判定过期"的状态 */
  isSessionAlive(): boolean {
    return this.loggedIn && !this.sessionExpiredFired;
  }

  /** 触发一次会话过期通知（幂等） */
  private fireSessionExpired(): void {
    if (this.sessionExpiredFired || !this.loggedIn) {
      return;
    }
    this.sessionExpiredFired = true;
    // 本地标记为未登录：后续调用直接短路，不再去骚扰路由器
    this.loggedIn = false;
    console.warn('[OpenWrtClient] 会话已过期（-32002），通知上层退回登录页');
    if (this.onSessionExpiredCb) {
      this.onSessionExpiredCb();
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

  // ======================== Clash 外部控制 API ========================

  /**
   * 调 Clash 外部控制 API（端口默认 9090）。
   * 必须带 `Authorization: Bearer <dashboard_password>`，否则一律 401。
   *
   * ⚠️ 注意：HarmonyOS 的 `http.RequestMethod` **没有 PATCH**，
   * 而 mihomo 的 `/configs` 只认 PATCH 做局部更新
   * （实测 PUT 返回 204 但字段根本没变）。所以**切换运行模式不要走这个 API**，
   * 还是得用 uci set + 重启服务。节点切换用的是 PUT /proxies/{组名}，那个没问题。
   */
  private clashRequest(url: string, secret: string, method: http.RequestMethod, body: string): Promise<HttpResult> {
    return new Promise<HttpResult>((resolve) => {
      const client: http.HttpRequest = http.createHttp();

      const headers: Record<string, string> = {};
      headers['Content-Type'] = 'application/json';
      if (secret.length > 0) {
        headers['Authorization'] = `Bearer ${secret}`;
      }

      let options: http.HttpRequestOptions;
      if (body.length > 0) {
        options = {
          method: method,
          header: headers,
          extraData: body,
          connectTimeout: 6000,
          readTimeout: 15000
        };
      } else {
        options = {
          method: method,
          header: headers,
          connectTimeout: 6000,
          readTimeout: 15000
        };
      }

      client.request(url, options, (err: BusinessError | null, data: http.HttpResponse) => {
        client.destroy();
        if (err) {
          resolve({ success: false, error: '请求失败: ' + err.message });
          return;
        }
        const code: number = data.responseCode;
        const text: string = data.result ? String(data.result) : '';
        if (code >= 200 && code < 300) {
          resolve({ success: true, data: text, statusCode: code });
        } else {
          resolve({ success: false, data: text, error: 'HTTP ' + code, statusCode: code });
        }
      });
    });
  }

  /**
   * 汇总 OpenClash 概览。
   *
   * 一共发 4 个请求：/version、/configs、/proxies、/connections。
   * 连不上控制 API（如密钥不对）时返回 null，页面据此降级显示。
   */
  async getClashOverview(baseUrl: string, secret: string): Promise<ClashOverview | null> {
    const overview: ClashOverview = {
      version: '--',
      mode: '--',
      logLevel: '--',
      allowLan: false,
      ipv6: false,
      ports: '--',
      proxyCount: 0,
      typeSummary: '--',
      activeConnections: 0,
      downloadTotal: 0,
      uploadTotal: 0,
      memory: 0,
      groups: []
    };

    // ---- /version ----
    const versionResp: HttpResult =
      await this.clashRequest(baseUrl + '/version', secret, http.RequestMethod.GET, '');
    if (!versionResp.success) {
      return null;
    }
    try {
      const vo: Record<string, Object> = JSON.parse(versionResp.data || '{}') as Record<string, Object>;
      overview.version = String(vo['version'] || '--');
    } catch (e) {
      console.warn('[Clash] 解析 /version 失败: ' + JSON.stringify(e));
    }

    // ---- /configs ----
    const configResp: HttpResult =
      await this.clashRequest(baseUrl + '/configs', secret, http.RequestMethod.GET, '');
    if (configResp.success && configResp.data) {
      try {
        const c: Record<string, Object> = JSON.parse(configResp.data) as Record<string, Object>;
        overview.mode = String(c['mode'] || '--');
        overview.logLevel = String(c['log-level'] || '--');
        overview.allowLan = c['allow-lan'] === true;
        overview.ipv6 = c['ipv6'] === true;

        const parts: string[] = [];
        const httpPort: string = String(c['port'] || '');
        const mixedPort: string = String(c['mixed-port'] || '');
        const socksPort: string = String(c['socks-port'] || '');
        if (httpPort.length > 0) {
          parts.push('HTTP ' + httpPort);
        }
        if (mixedPort.length > 0) {
          parts.push('混合 ' + mixedPort);
        }
        if (socksPort.length > 0) {
          parts.push('SOCKS ' + socksPort);
        }
        overview.ports = parts.length > 0 ? parts.join(' · ') : '--';
      } catch (e) {
        console.warn('[Clash] 解析 /configs 失败: ' + JSON.stringify(e));
      }
    }

    // ---- /proxies ----
    const proxyResp: HttpResult =
      await this.clashRequest(baseUrl + '/proxies', secret, http.RequestMethod.GET, '');
    if (proxyResp.success && proxyResp.data) {
      try {
        const root: Record<string, Object> = JSON.parse(proxyResp.data) as Record<string, Object>;
        const proxies: Record<string, Object> | undefined = root['proxies'] as Record<string, Object>;
        if (proxies) {
          const names: string[] = Object.keys(proxies);

          // 第一遍：把每个节点的最近延迟记下来（策略组的成员要显示延迟）
          const delays: ClashDelay[] = [];
          for (let i = 0; i < names.length; i++) {
            const p: Record<string, Object> = proxies[names[i]] as Record<string, Object>;
            const d: ClashDelay = new ClashDelay();
            d.name = names[i];
            d.delay = this.extractDelay(p);
            delays.push(d);
          }

          // 第二遍：分拣策略组 / 统计节点类型
          const counts: ClashTypeCount[] = [];
          const groups: ClashGroup[] = [];

          for (let i = 0; i < names.length; i++) {
            const name: string = names[i];
            const p: Record<string, Object> = proxies[name] as Record<string, Object>;
            const type: string = String(p['type'] || '');

            // 策略组单独收集，不计入节点统计
            if (type === 'Selector' || type === 'URLTest' || type === 'Fallback' || type === 'LoadBalance') {
              if (name === 'GLOBAL') {
                continue; // 内建全局选择器，规则模式下没有意义
              }
              const members: string[] = this.toStringList(p['all']);
              const memberDelays: number[] = [];
              for (let m = 0; m < members.length; m++) {
                memberDelays.push(this.findDelay(delays, members[m]));
              }
              const g: ClashGroup = {
                name: name,
                type: type,
                now: String(p['now'] || ''),
                members: members,
                memberDelays: memberDelays,
                switchable: type === 'Selector'
              };
              groups.push(g);
              continue;
            }

            // 内建项不算节点
            if (type === 'Direct' || type === 'Reject' || type === 'RejectDrop' ||
                type === 'Pass' || type === 'Compatible' || type === 'PassRule') {
              continue;
            }

            let found: boolean = false;
            for (let k = 0; k < counts.length; k++) {
              if (counts[k].type === type) {
                counts[k].count = counts[k].count + 1;
                found = true;
              }
            }
            if (!found) {
              const tc: ClashTypeCount = new ClashTypeCount();
              tc.type = type;
              tc.count = 1;
              counts.push(tc);
            }
          }

          counts.sort((a: ClashTypeCount, b: ClashTypeCount) => b.count - a.count);

          let total: number = 0;
          const summary: string[] = [];
          for (let i = 0; i < counts.length; i++) {
            total = total + counts[i].count;
            if (i < 3) {
              summary.push(counts[i].type + ' ' + counts[i].count);
            }
          }

          overview.proxyCount = total;
          overview.typeSummary = summary.length > 0 ? summary.join(' · ') : '--';
          overview.groups = groups;
        }
      } catch (e) {
        console.warn('[Clash] 解析 /proxies 失败: ' + JSON.stringify(e));
      }
    }

    // ---- /connections ----
    const connResp: HttpResult =
      await this.clashRequest(baseUrl + '/connections', secret, http.RequestMethod.GET, '');
    if (connResp.success && connResp.data) {
      try {
        const c: Record<string, Object> = JSON.parse(connResp.data) as Record<string, Object>;
        overview.downloadTotal = this.toNumber(c['downloadTotal']);
        overview.uploadTotal = this.toNumber(c['uploadTotal']);
        overview.memory = this.toNumber(c['memory']);
        const list: Object[] | undefined = c['connections'] as Object[];
        overview.activeConnections = list ? list.length : 0;
      } catch (e) {
        console.warn('[Clash] 解析 /connections 失败: ' + JSON.stringify(e));
      }
    }

    return overview;
  }

  /** 从节点的 history 里取最近一次延迟（毫秒），取不到返回 -1 */
  private extractDelay(proxy: Record<string, Object>): number {
    const history: Object[] | undefined = proxy['history'] as Object[];
    if (!history || history.length === 0) {
      return -1;
    }
    const last: Record<string, Object> = history[history.length - 1] as Record<string, Object>;
    const d: number = this.toNumber(last['delay']);
    return d > 0 ? d : -1;
  }

  /** 在延迟表里查某个节点 */
  private findDelay(table: ClashDelay[], name: string): number {
    for (let i = 0; i < table.length; i++) {
      if (table[i].name === name) {
        return table[i].delay;
      }
    }
    return -1;
  }

  /**
   * 切换某个策略组的节点（只有 Selector 类型的组能切）。
   *
   * 实测：`PUT /proxies/{URL编码的组名}` + body `{"name":"<节点名>"}`
   * 成功返回 HTTP 204。
   */
  async switchClashNode(baseUrl: string, secret: string, group: string, node: string): Promise<boolean> {
    const url: string = `${baseUrl}/proxies/${encodeURIComponent(group)}`;
    const body: string = `{"name":${JSON.stringify(node)}}`;
    const r: HttpResult = await this.clashRequest(url, secret, http.RequestMethod.PUT, body);
    return r.success;
  }

  /**
   * Clash 外部控制 API：规则列表。
   * 出口映射表靠它找 SRC-IP-CIDR（按源子网分流）和 MATCH（默认策略组）。
   */
  async getClashRules(baseUrl: string, secret: string): Promise<ClashRule[]> {
    const out: ClashRule[] = [];
    const r: HttpResult = await this.clashRequest(baseUrl + '/rules', secret, http.RequestMethod.GET, '');
    if (!r.success || !r.data) {
      return out;
    }
    try {
      const root: Record<string, Object> = JSON.parse(r.data) as Record<string, Object>;
      const list: Object[] | undefined = root['rules'] as Object[];
      if (list) {
        for (let i = 0; i < list.length; i++) {
          const item: Record<string, Object> = list[i] as Record<string, Object>;
          const rule: ClashRule = {
            type: String(item['type'] || ''),
            payload: String(item['payload'] || ''),
            proxy: String(item['proxy'] || '')
          };
          out.push(rule);
        }
      }
    } catch (e) {
      console.warn('[Clash] 解析 /rules 失败: ' + JSON.stringify(e));
    }
    return out;
  }

  /**
   * Clash 外部控制 API：只取策略组（出口映射表要显示每个组当前选中的节点）。
   * 比 getClashOverview 省 3 个请求（那个还会拉 version/configs/connections）。
   */
  async getClashGroups(baseUrl: string, secret: string): Promise<ClashGroup[]> {
    const groups: ClashGroup[] = [];
    const r: HttpResult = await this.clashRequest(baseUrl + '/proxies', secret, http.RequestMethod.GET, '');
    if (!r.success || !r.data) {
      return groups;
    }
    try {
      const root: Record<string, Object> = JSON.parse(r.data) as Record<string, Object>;
      const proxies: Record<string, Object> | undefined = root['proxies'] as Record<string, Object>;
      if (proxies) {
        const names: string[] = Object.keys(proxies);
        for (let i = 0; i < names.length; i++) {
          const name: string = names[i];
          const p: Record<string, Object> = proxies[name] as Record<string, Object>;
          const type: string = String(p['type'] || '');
          if (type === 'Selector' || type === 'URLTest' || type === 'Fallback' || type === 'LoadBalance') {
            if (name === 'GLOBAL') {
              continue;
            }
            const g: ClashGroup = {
              name: name,
              type: type,
              now: String(p['now'] || ''),
              members: [],
              memberDelays: [],
              switchable: type === 'Selector'
            };
            groups.push(g);
          }
        }
      }
    } catch (e) {
      console.warn('[Clash] 解析 /proxies（仅策略组）失败: ' + JSON.stringify(e));
    }
    return groups;
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

  // ======================== 多 SSID / 出口映射 ========================

  /** 读 wireless 的 uci 配置原文（含被禁用射频下的 SSID，这是多 SSID 管理的权威数据源） */
  async getWirelessUci(): Promise<UbusResult<Record<string, Object>>> {
    return this.ubusCallAuth<Record<string, Object>>('uci', 'get', json('{"config":"wireless"}'));
  }

  /** 解析 uci wireless → 射频配置 + 全部 SSID 配置 */
  async getWifiConfig(): Promise<WifiConfig> {
    const devices: WifiDeviceCfg[] = [];
    const ifaces: WifiIfaceCfg[] = [];
    const r: UbusResult<Record<string, Object>> = await this.getWirelessUci();
    if (!r.success || !r.data) {
      console.error('[OpenWrtClient] getWifiConfig 读 wireless 失败: ' + (r.error || ''));
      return { devices: devices, ifaces: ifaces };
    }
    const values: Record<string, Object> | undefined = r.data['values'] as Record<string, Object>;
    if (!values) {
      return { devices: devices, ifaces: ifaces };
    }
    const names: string[] = Object.keys(values);
    for (let i = 0; i < names.length; i++) {
      const sec: Record<string, Object> = values[names[i]] as Record<string, Object>;
      const type: string = String(sec['.type'] || '');
      if (type === 'wifi-device') {
        const dev: WifiDeviceCfg = {
          section: names[i],
          band: String(sec['band'] || ''),
          channel: String(sec['channel'] || ''),
          htmode: String(sec['htmode'] || ''),
          txpower: String(sec['txpower'] || ''),
          country: String(sec['country'] || ''),
          disabled: String(sec['disabled'] || '0') === '1'
        };
        devices.push(dev);
      } else if (type === 'wifi-iface') {
        const ap: WifiIfaceCfg = {
          section: names[i],
          radio: String(sec['device'] || ''),
          network: String(sec['network'] || ''),
          mode: String(sec['mode'] || ''),
          ssid: String(sec['ssid'] || ''),
          key: String(sec['key'] || ''),
          encryption: String(sec['encryption'] || ''),
          hidden: String(sec['hidden'] || '0') === '1',
          disabled: String(sec['disabled'] || '0') === '1'
        };
        if (ap.mode === '' || ap.mode === 'ap') {
          ifaces.push(ap);
        }
      }
    }
    return { devices: devices, ifaces: ifaces };
  }

  /** 读 network 的 uci 配置并解析出 interface 段（含归一化子网） */
  async getNetworkConfigs(): Promise<NetworkCfg[]> {
    const out: NetworkCfg[] = [];
    const r: UbusResult<Record<string, Object>> = await this.ubusCallAuth<Record<string, Object>>(
      'uci', 'get', json('{"config":"network"}')
    );
    if (!r.success || !r.data) {
      return out;
    }
    const values: Record<string, Object> | undefined = r.data['values'] as Record<string, Object>;
    if (!values) {
      return out;
    }
    const names: string[] = Object.keys(values);
    for (let i = 0; i < names.length; i++) {
      const sec: Record<string, Object> = values[names[i]] as Record<string, Object>;
      if (String(sec['.type'] || '') !== 'interface') {
        continue;
      }
      let ip: string = '';
      const addr: Object | undefined = sec['ipaddr'];
      if (addr !== undefined && addr !== null && Array.isArray(addr)) {
        const arr: Object[] = addr as Object[];
        if (arr.length > 0) {
          ip = String(arr[0]);
        }
      } else if (addr !== undefined && addr !== null) {
        ip = String(addr);
      }
      const cfg: NetworkCfg = {
        name: names[i],
        proto: String(sec['proto'] || ''),
        device: String(sec['device'] || ''),
        subnet: this.toSubnet(ip)
      };
      out.push(cfg);
    }
    return out;
  }

  /**
   * 读 firewall 的 uci 配置，返回 network 名 → zone 名。
   * zone 的 network 是列表（一个 zone 可含多个 network）。
   */
  async getNetworkZones(): Promise<Record<string, string>> {
    const out: Record<string, string> = {};
    const r: UbusResult<Record<string, Object>> = await this.ubusCallAuth<Record<string, Object>>(
      'uci', 'get', json('{"config":"firewall"}')
    );
    if (!r.success || !r.data) {
      return out;
    }
    const values: Record<string, Object> | undefined = r.data['values'] as Record<string, Object>;
    if (!values) {
      return out;
    }
    const names: string[] = Object.keys(values);
    for (let i = 0; i < names.length; i++) {
      const sec: Record<string, Object> = values[names[i]] as Record<string, Object>;
      if (String(sec['.type'] || '') !== 'zone') {
        continue;
      }
      const zoneName: string = String(sec['name'] || '');
      const nets: string[] = this.toStringList(sec['network']);
      for (let k = 0; k < nets.length; k++) {
        out[nets[k]] = zoneName;
      }
    }
    return out;
  }

  /**
   * 把 uci 的 "192.168.2.1/24" 归一化成网络地址 "192.168.2.0/24"
   * （映射表要拿它跟 Clash 的 SRC-IP-CIDR 规则比对）。
   */
  private toSubnet(ipCidr: string): string {
    if (ipCidr.length === 0) {
      return '';
    }
    const parts: string[] = ipCidr.split('/');
    if (parts.length !== 2) {
      return ipCidr;
    }
    const prefix: number = parseInt(parts[1]);
    if (isNaN(prefix) || prefix < 0 || prefix > 32) {
      return ipCidr;
    }
    const octets: string[] = parts[0].split('.');
    if (octets.length !== 4) {
      return ipCidr;
    }
    const nums: number[] = [];
    for (let i = 0; i < 4; i++) {
      const n: number = parseInt(octets[i]);
      if (isNaN(n) || n < 0 || n > 255) {
        return ipCidr;
      }
      nums.push(n);
    }
    let value: number = 0;
    for (let i = 0; i < 4; i++) {
      value = value * 256 + nums[i];
    }
    const mask: number = prefix === 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) >>> 0;
    const net: number = (value & mask) >>> 0;
    const out: number[] = [
      (net >>> 24) & 0xFF, (net >>> 16) & 0xFF, (net >>> 8) & 0xFF, net & 0xFF
    ];
    return `${out[0]}.${out[1]}.${out[2]}.${out[3]}/${prefix}`;
  }

  /**
   * 新增一个 SSID（wifi-iface），返回新段名（失败返回空串）。
   *
   * 流程：uci.add 拿段名（拿不到就用前后差集兜底）→ 逐项 uci.set → 不 commit
   * （commit + 生效由调用方统一走 applyWifi()）。
   */
  async addWifiIface(radio: string, ssid: string, key: string, network: string, hidden: boolean): Promise<string> {
    const before: string[] = await this.wifiIfaceSections();
    const addRes: UbusResult<Record<string, Object>> = await this.ubusCallAuth<Record<string, Object>>(
      'uci', 'add', json('{"config":"wireless","type":"wifi-iface"}')
    );
    if (!addRes.success) {
      console.error('[OpenWrtClient] uci.add wifi-iface 失败: code=' + addRes.code);
      return '';
    }
    let section: string = '';
    if (addRes.data) {
      section = String(addRes.data['section'] || '');
    }
    if (section.length === 0) {
      const after: string[] = await this.wifiIfaceSections();
      for (let i = 0; i < after.length; i++) {
        if (before.indexOf(after[i]) < 0) {
          section = after[i];
        }
      }
    }
    if (section.length === 0) {
      console.error('[OpenWrtClient] 新增 wifi-iface 后找不到段名');
      return '';
    }

    const options: string[][] = [
      ['device', radio],
      ['mode', 'ap'],
      ['ssid', ssid],
      ['network', network],
      ['hidden', hidden ? '1' : '0'],
      ['encryption', key.length > 0 ? 'psk2' : 'none']
    ];
    for (let i = 0; i < options.length; i++) {
      const ok: boolean = await this.setWifiOption(section, options[i][0], options[i][1]);
      if (!ok) {
        console.error('[OpenWrtClient] 写 ' + options[i][0] + ' 失败，回滚删除新段');
        await this.deleteWifiIface(section);
        return '';
      }
    }
    if (key.length > 0) {
      const ok: boolean = await this.setWifiOption(section, 'key', key);
      if (!ok) {
        await this.deleteWifiIface(section);
        return '';
      }
    }
    console.info('[OpenWrtClient] 已新增 SSID 段 ' + section);
    return section;
  }

  /** 删除一个 wireless 配置项（例如把发射功率恢复成驱动默认） */
  async deleteWifiOption(section: string, option: string): Promise<boolean> {
    const r: UbusResult<Object> = await this.ubusCallAuth<Object>(
      'uci', 'delete', json(`{"config":"wireless","section":"${section}","option":"${option}"}`)
    );
    return r.success;
  }

  /** 删除一个 wifi-iface（整个 SSID）；不 commit，生效由调用方统一处理 */
  async deleteWifiIface(section: string): Promise<boolean> {
    const r: UbusResult<Object> = await this.ubusCallAuth<Object>(
      'uci', 'delete', json(`{"config":"wireless","section":"${section}"}`)
    );
    return r.success;
  }

  /** 当前配置里所有 wifi-iface 段名 */
  private async wifiIfaceSections(): Promise<string[]> {
    const out: string[] = [];
    const r: UbusResult<Record<string, Object>> = await this.getWirelessUci();
    if (!r.success || !r.data) {
      return out;
    }
    const values: Record<string, Object> | undefined = r.data['values'] as Record<string, Object>;
    if (!values) {
      return out;
    }
    const names: string[] = Object.keys(values);
    for (let i = 0; i < names.length; i++) {
      const sec: Record<string, Object> = values[names[i]] as Record<string, Object>;
      if (String(sec['.type'] || '') === 'wifi-iface') {
        out.push(names[i]);
      }
    }
    return out;
  }

  /** 该射频支持的发射功率档位（dBm） */
  async getTxPowerList(ifname: string): Promise<number[]> {
    const out: number[] = [];
    const r: UbusResult<IwinfoListResponse<Record<string, Object>>> =
      await this.ubusCallAuth<IwinfoListResponse<Record<string, Object>>>(
        'iwinfo', 'txpowerlist', json(`{"device":"${ifname}"}`)
      );
    if (!r.success || !r.data) {
      return out;
    }
    const list: Record<string, Object>[] | undefined = r.data.results;
    if (!list) {
      return out;
    }
    for (let i = 0; i < list.length; i++) {
      const dbm: number = this.toNumber(list[i]['dbm']);
      out.push(dbm);
    }
    return out;
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

  /**
   * 一次拿到**所有**网卡的收发字节数（用于算实时速率）。
   *
   * 用 `luci-rpc.getNetworkDevices`：一次请求就返回全部网卡（实测 8 个）的 stats，
   * 比逐个调 `network.device status` 便宜得多，适合秒级轮询。
   */
  async getAllDeviceStats(): Promise<NetDeviceStats[]> {
    const out: NetDeviceStats[] = [];
    const r: UbusResult<Record<string, Object>> = await this.ubusCallAuth<Record<string, Object>>(
      'luci-rpc', 'getNetworkDevices', json('{}')
    );
    if (!r.success || !r.data) {
      return out;
    }

    const names: string[] = Object.keys(r.data);
    for (let i = 0; i < names.length; i++) {
      const dev: Record<string, Object> = r.data[names[i]] as Record<string, Object>;
      const st: Record<string, Object> | undefined = dev['stats'] as Record<string, Object>;
      if (!st) {
        continue;
      }
      const item: NetDeviceStats = {
        device: names[i],
        rxBytes: this.toNumber(st['rx_bytes']),
        txBytes: this.toNumber(st['tx_bytes'])
      };
      out.push(item);
    }
    return out;
  }

  /**
   * 找出「出口」接口对应的三层设备名（用来算上网速率）。
   *
   * 优先取名为 `wan` 的接口；没有的话退回第一个带默认网关的接口。
   * 只发 1 个请求（dump），不需要逐个查 device status。
   */
  async findUplinkDevice(): Promise<string> {
    const dump: UbusResult<NetworkDump> =
      await this.ubusCallAuth<NetworkDump>('network.interface', 'dump', json('{}'));
    if (!dump.success || !dump.data) {
      return '';
    }

    const list: Object[] = dump.data.interface || [];
    let fallback: string = '';

    for (let i = 0; i < list.length; i++) {
      const r: Record<string, Object> = list[i] as Record<string, Object>;
      const name: string = String(r['interface'] || '');
      const dev: string = String(r['l3_device'] || r['device'] || '');

      if (name === 'wan') {
        return dev;
      }
      if (fallback.length === 0 && this.findGateway(r['route']).length > 0) {
        fallback = dev;
      }
    }
    return fallback;
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
      deviceOwner: '',
      rateReady: false,
      rxRate: 0,
      txRate: 0
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

      // JSON-RPC 层错误：会话过期就是 -32002 Access denied（此时没有 result 字段）
      if (ubusResp.error) {
        const rpcCode: number = Number(ubusResp.error.code);
        const rpcMsg: string = String(ubusResp.error.message || '');
        console.error(`[OpenWrtClient] JSON-RPC 错误 ${obj}.${func} -> ${rpcCode} ${rpcMsg}`);
        if (rpcCode === SESSION_EXPIRED_CODE) {
          this.fireSessionExpired();
          return { success: false, code: rpcCode, data: null, error: '登录已过期（Access denied），请重新登录' };
        }
        return { success: false, code: rpcCode, data: null, error: `RPC 错误 ${rpcCode}: ${rpcMsg}` };
      }

      // result 是定长元组 [code, data]，类型上保证长度，这里只需判断存在性
      if (!ubusResp.result) {
        return { success: false, code: -4, data: null, error: `返回体异常（既无 result 也无 error）: ${text.substring(0, 120)}` };
      }

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
    this.onSessionExpiredCb = undefined;
    try {
      this.httpClient.destroy();
    } catch (e) {
      console.error(`[OpenWrtClient] 销毁异常: ${JSON.stringify(e)}`);
    }
    this.sessionId = '';
    this.loggedIn = false;
  }
}
