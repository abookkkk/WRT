/**
 * 网络接口页面
 *
 * 数据来源：
 *   - `network.interface dump`  → 逻辑接口（lan / wan / wan6 / loopback）的地址、路由、DNS、运行时长
 *   - `network.device status`   → 底层设备的流量统计、MTU、速率、MAC、网桥成员
 *
 * 注意：dump 里**没有流量**（data 字段是空的），流量必须另外查 device status，
 * 这部分已经在 OpenWrtClient.getNetworkInterfaces() 里合并好了。
 */

import { OpenWrtClient } from '../model/OpenWrtClient';
import type { NetworkInterface, NetAddress, NetDeviceStats } from '../model/OpenWrtModels';
import {
  C_PRIMARY, C_SUCCESS, C_WARNING, C_TEXT_1, C_TEXT_2, C_TEXT_3,
  C_CARD, C_DIVIDER, C_FILL, C_SUCCESS_CHIP, C_WARNING_CHIP,
  F_SECTION, F_BODY, F_CAPTION, F_TINY,
  R_CARD, R_CHIP, SP_S, SP_M, SP_L, SP_XL, TAB_BAR_SPACE, ICON_S
} from '../common/Theme';
import { shouldShowErrorPage, shouldToast, notifyLoadFailed } from '../common/RefreshPolicy';
import type { LoadKind } from '../common/RefreshPolicy';

const COLOR_CARD_BG: ResourceColor = C_CARD;

/** 实时速率的采样间隔（毫秒）。一次采样只要 1 个 ubus 请求。 */
const RATE_SAMPLE_MS: number = 3000;

/** 上一次采样记录，用来算差值 */
class RateSample {
  device: string = '';
  rx: number = 0;
  tx: number = 0;
}

@Component
export struct NetworkPage {
  /** 悬浮顶栏 / 标签栏的避让：HomePage 量好安全区后写进 AppStorage，值变化时这里会自动重排 */
  @StorageProp('safeTop') safeTop: number = 100;
  @StorageProp('safeBottom') safeBottom: number = TAB_BAR_SPACE + 16;  private client!: OpenWrtClient;

  @State private interfaces: NetworkInterface[] = [];
  @State private isLoading: boolean = true;
  @State private isRefreshing: boolean = false;
  @State private hasError: boolean = false;
  @State private errorMsg: string = '';
  /** 每次加载 / 速率更新自增，强制 ForEach 重建卡片（否则 @Builder 的值传递参数不会刷新） */
  @State private dataVersion: number = 0;

  /** 速率采样定时器；-1 表示未启动 */
  private rateTimer: number = -1;
  /** 页面是否可见 —— 不可见就跳过采样，别白白打扰路由器 */
  private pageVisible: boolean = true;
  private prevSamples: RateSample[] = [];
  private prevStamp: number = 0;

  aboutToAppear(): void {
    this.loadData();
    this.startRateSampler();
  }

  aboutToDisappear(): void {
    this.stopRateSampler();
  }

  build() {
    Stack() {
      if (!this.isLoading && !this.hasError) {
        // 下拉刷新用 Refresh 组件 —— 这是全 App 唯一的刷新手势（规范见 common/RefreshPolicy.ets）。
        // 下拉只切 isRefreshing（顶部指示器），不切 isLoading，所以内容不会被卸载重建。
        // 绝不要用 Scroll/List 的 onReachStart —— 列表初始就在顶部会立刻触发，
        // 数据更新又引起重渲染，于是反复触发，形成无限刷新循环。
        Refresh({ refreshing: this.isRefreshing }) {
          Scroll() {
            Column() {
              ForEach(this.interfaces, (iface: NetworkInterface) => {
                this.buildInterfaceCard(iface);
              }, (iface: NetworkInterface, index?: number) => {
                return iface.name + '#' + this.dataVersion;
              });
            }
            .width('100%')
            .padding({ left: SP_L, right: SP_L, top: this.safeTop, bottom: this.safeBottom })
          }
          .width('100%')
          .height('100%')
          .edgeEffect(EdgeEffect.Spring)
        }
        .width('100%')
        .height('100%')
        .onRefreshing(() => this.onPullRefresh())
      }

      if (this.isLoading) {
        LoadingProgress().width(32).height(32);
      }

      if (this.hasError) {
        Column() {
          Text('⚠️').fontSize(40);
          Text(this.errorMsg).fontSize(F_BODY).margin({ top: SP_M });
          Button('重试').type(ButtonType.Capsule).margin({ top: SP_L })
            .onClick(() => this.loadData());
        }
      }
    }
    .width('100%')
    .height('100%')
    // 页面滑出屏幕后暂停速率采样，别在后台一直打扰路由器
    .onVisibleAreaChange([0.0, 0.5], (isVisible: boolean, ratio: number) => {
      this.pageVisible = isVisible;
    })
  }

  @Builder
  buildInterfaceCard(iface: NetworkInterface) {
    Column() {
      // ===== 头部：图标 + 接口名 + 设备名 + 状态 =====
      Row() {
        SymbolGlyph($r('sys.symbol.rectangle_stack'))
          .fontSize(22)
          .fontColor([iface.up ? C_PRIMARY : C_TEXT_3])
          .renderingStrategy(SymbolRenderingStrategy.SINGLE);

        Column() {
          Text(iface.name.toUpperCase())
            .fontSize(F_SECTION)
            .fontWeight(FontWeight.Bold)
            .fontColor(C_TEXT_1);
          Text(iface.l3Device)
            .fontSize(F_TINY)
            .fontColor(C_TEXT_3)
            .fontFamily('monospace')
            .margin({ top: 2 });
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: SP_M });

        Row() {
          Circle()
            .width(7).height(7)
            .fill(iface.up ? C_SUCCESS : C_TEXT_3)
            .margin({ right: 5 });
          Text(iface.up ? '已连接' : '已断开')
            .fontSize(F_TINY)
            .fontColor(iface.up ? C_SUCCESS : C_TEXT_3);
        }
        .padding({ left: SP_S, right: SP_S, top: 3, bottom: 3 })
        .backgroundColor(iface.up ? C_SUCCESS_CHIP : C_FILL)
        .borderRadius(R_CHIP);
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: SP_M });

      Divider().color(C_DIVIDER).margin({ bottom: SP_M });

      // ===== 详情 =====
      this.detailRow('协议', iface.proto.toUpperCase());
      this.detailRow('运行时长', this.formatUptime(iface.uptime));

      if (iface.ipv4.length > 0) {
        this.detailRow('IPv4', this.formatAddresses(iface.ipv4));
      }
      if (iface.ipv6.length > 0) {
        this.detailRow('IPv6', this.formatAddresses(iface.ipv6));
      }
      if (iface.gateway.length > 0) {
        this.detailRow('网关', iface.gateway);
      }
      if (iface.dns.length > 0) {
        this.detailRow('DNS', iface.dns.join('\n'));
      }
      if (iface.dhcpServer.length > 0) {
        this.detailRow('DHCP 服务器', iface.dhcpServer);
      }
      if (iface.leaseTime > 0) {
        this.detailRow('租期', this.formatDuration(iface.leaseTime));
      }
      // 设备级信息（MTU / 速率 / MAC / 桥接成员 / 流量）只在
      // 「第一个用到该物理设备的接口」上展示，避免 wan 和 wan6 重复显示同一份数据
      if (iface.showDeviceStats) {
        if (iface.mtu > 0) {
          this.detailRow('MTU', String(iface.mtu));
        }
        if (iface.speed.length > 0) {
          this.detailRow('链路速率', this.formatSpeed(iface.speed));
        }
        if (this.hasRealMac(iface.mac)) {
          this.detailRow('MAC', iface.mac.toUpperCase());
        }
        if (iface.bridgeMembers.length > 0) {
          this.detailRow('桥接成员', iface.bridgeMembers.join(', '));
        }
      } else if (iface.deviceOwner.length > 0) {
        Text('该接口与「' + iface.deviceOwner + '」共用物理设备 ' + iface.l3Device +
             '，MTU、速率、MAC 与流量统计见那张卡片')
          .fontSize(F_TINY)
          .fontColor(C_TEXT_3)
          .lineHeight(16)
          .width('100%');
      }

      // ===== 流量统计 =====
      if (iface.showDeviceStats) {
        Divider().color(C_DIVIDER).margin({ top: SP_S, bottom: SP_M });

        Row() {
          // 接收
          Column() {
            Row() {
              SymbolGlyph($r('sys.symbol.arrow_down'))
                .fontSize(ICON_S)
                .fontColor([C_SUCCESS])
                .renderingStrategy(SymbolRenderingStrategy.SINGLE);
              Text('接收')
                .fontSize(F_TINY)
                .fontColor(C_TEXT_2)
                .margin({ left: 4 });
              if (iface.rateReady) {
                Text(this.formatRate(iface.rxRate))
                  .fontSize(F_TINY)
                  .fontColor(C_SUCCESS)
                  .backgroundColor(C_SUCCESS_CHIP)
                  .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                  .borderRadius(6)
                  .margin({ left: 6 });
              }
            }
            .alignItems(VerticalAlign.Center);

            Text(this.formatTraffic(iface.rxBytes))
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor(C_TEXT_1)
              .margin({ top: 2 });

            Text(this.formatCount(iface.rxPackets) + ' 包')
              .fontSize(F_TINY)
              .fontColor(C_TEXT_3)
              .margin({ top: 1 });
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start);

          // 发送
          Column() {
            Row() {
              SymbolGlyph($r('sys.symbol.arrow_up'))
                .fontSize(ICON_S)
                .fontColor([C_WARNING])
                .renderingStrategy(SymbolRenderingStrategy.SINGLE);
              Text('发送')
                .fontSize(F_TINY)
                .fontColor(C_TEXT_2)
                .margin({ left: 4 });
              if (iface.rateReady) {
                Text(this.formatRate(iface.txRate))
                  .fontSize(F_TINY)
                  .fontColor(C_WARNING)
                  .backgroundColor(C_WARNING_CHIP)
                  .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                  .borderRadius(6)
                  .margin({ left: 6 });
              }
            }
            .alignItems(VerticalAlign.Center);

            Text(this.formatTraffic(iface.txBytes))
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor(C_TEXT_1)
              .margin({ top: 2 });

            Text(this.formatCount(iface.txPackets) + ' 包')
              .fontSize(F_TINY)
              .fontColor(C_TEXT_3)
              .margin({ top: 1 });
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start);
        }
        .width('100%');

        // 有错误包时额外提示一行
        if (iface.rxErrors > 0 || iface.txErrors > 0) {
          Text('错误包：接收 ' + iface.rxErrors + ' / 发送 ' + iface.txErrors)
            .fontSize(F_TINY)
            .fontColor(C_WARNING)
            .width('100%')
            .margin({ top: SP_S });
        }
      }
    }
    .width('100%')
    .padding(SP_XL)
    .backgroundColor(COLOR_CARD_BG)
    .borderRadius(R_CARD)
    .shadow(ShadowStyle.OUTER_DEFAULT_SM)
    .margin({ bottom: 14 })
  }

  /** 一行「标签 —— 值」，值过长自动换行右对齐 */
  @Builder
  detailRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(F_CAPTION)
        .fontColor(C_TEXT_2)
        .width(88);

      Text(value)
        .fontSize(F_CAPTION)
        .fontWeight(FontWeight.Medium)
        .fontColor(C_TEXT_1)
        .layoutWeight(1)
        .textAlign(TextAlign.End)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ bottom: 6 })
  }

  // ==================== 数据加载 ====================

  /**
   * 加载接口与流量 —— 本页唯一的取数入口（刷新规范见 common/RefreshPolicy.ets）。
   * kind 决定 Loading 与失败反馈：'first' 首屏 / 'pull' 下拉刷新。
   */
  private async loadData(kind: LoadKind = 'first'): Promise<void> {
    if (kind === 'first') {
      this.isLoading = true;
    }

    try {
      if (!this.client.isLoggedIn()) {
        this.failLoad('未登录', kind);
        return;
      }

      // 这个方法内部会 dump 一次 + 对每个 l3_device 查一次 device status（拿流量）
      const result = await this.client.getNetworkInterfaces();

      if (result.success && result.data) {
        // lan / wan 排前面，loopback 放最后
        const list: NetworkInterface[] = result.data;
        list.sort((a: NetworkInterface, b: NetworkInterface) => {
          return this.orderOf(a.name) - this.orderOf(b.name);
        });
        this.interfaces = list;
        this.dataVersion = this.dataVersion + 1;
        // 成功就清掉错误页：停在错误页时，一次下拉刷新也能把它救回来
        this.hasError = false;
      } else {
        this.failLoad(result.error || '获取接口数据失败', kind);
      }
    } catch (e) {
      this.failLoad('请求异常: ' + JSON.stringify(e), kind);
    } finally {
      this.isLoading = false;
      this.isRefreshing = false;
    }
  }

  /**
   * 统一的失败处理，三档反馈（规范见 common/RefreshPolicy.ets）：
   * 首屏失败 → 错误页；下拉刷新失败 → 保留已有数据 + 提示；静默刷新失败 → 只写日志。
   */
  private failLoad(msg: string, kind: LoadKind): void {
    console.error('[Network] ' + msg);
    if (shouldShowErrorPage(kind)) {
      this.hasError = true;
      this.errorMsg = msg;
    } else if (shouldToast(kind)) {
      notifyLoadFailed(msg);
    }
  }

  /** 下拉刷新的统一入口：挂给 Refresh 的 onRefreshing（不再弹「正在刷新…」，指示器本身就是反馈） */
  private onPullRefresh(): void {
    if (this.isRefreshing) return;
    this.isRefreshing = true;
    this.loadData('pull');
  }

  // ==================== 实时速率采样 ====================

  private startRateSampler(): void {
    if (this.rateTimer >= 0) return;
    this.rateTimer = setInterval(() => {
      if (this.pageVisible) {
        this.sampleRates();
      }
    }, RATE_SAMPLE_MS);
  }

  private stopRateSampler(): void {
    if (this.rateTimer >= 0) {
      clearInterval(this.rateTimer);
      this.rateTimer = -1;
    }
  }

  private findSample(device: string): RateSample | null {
    for (let i = 0; i < this.prevSamples.length; i++) {
      if (this.prevSamples[i].device === device) {
        return this.prevSamples[i];
      }
    }
    return null;
  }

  private findStats(list: NetDeviceStats[], device: string): NetDeviceStats | null {
    for (let i = 0; i < list.length; i++) {
      if (list[i].device === device) {
        return list[i];
      }
    }
    return null;
  }

  /**
   * 采一次样并算出实时速率。
   *
   * 速率 = (本次字节数 − 上次字节数) / 间隔秒数。
   * 只需要 1 个 ubus 请求：luci-rpc.getNetworkDevices 一次就返回所有网卡的 stats。
   */
  private async sampleRates(): Promise<void> {
    if (!this.client.isLoggedIn() || this.interfaces.length === 0) {
      return;
    }

    const stats: NetDeviceStats[] = await this.client.getAllDeviceStats();
    if (stats.length === 0) {
      return;
    }

    const now: number = Date.now();
    const dt: number = this.prevStamp > 0 ? (now - this.prevStamp) / 1000 : 0;

    const nextSamples: RateSample[] = [];
    let changed: boolean = false;

    for (let i = 0; i < this.interfaces.length; i++) {
      const it: NetworkInterface = this.interfaces[i];
      const cur: NetDeviceStats | null = this.findStats(stats, it.l3Device);
      if (cur === null) {
        continue;
      }

      const s: RateSample = new RateSample();
      s.device = it.l3Device;
      s.rx = cur.rxBytes;
      s.tx = cur.txBytes;
      nextSamples.push(s);

      const prev: RateSample | null = this.findSample(it.l3Device);
      // dt 太小算出来的速率抖动很大，跳过
      if (prev !== null && dt > 0.5) {
        let drx: number = cur.rxBytes - prev.rx;
        let dtx: number = cur.txBytes - prev.tx;
        // 计数器回绕 / 路由器重启时 delta 会变负数，钳到 0
        if (drx < 0) drx = 0;
        if (dtx < 0) dtx = 0;
        it.rxRate = drx / dt;
        it.txRate = dtx / dt;
        it.rateReady = true;
        changed = true;
      }
    }

    this.prevSamples = nextSamples;
    this.prevStamp = now;

    // 对象是原地改的，ArkUI 检测不到，所以要换一份新数组引用并 bump 版本号
    if (changed) {
      this.interfaces = this.interfaces.slice();
      this.dataVersion = this.dataVersion + 1;
    }
  }

  // ==================== 工具方法 ====================

  /** 把一个或多个地址格式化成 192.168.2.1/24 形式 */
  private formatAddresses(list: NetAddress[]): string {
    const parts: string[] = [];
    for (let i = 0; i < list.length; i++) {
      const a: NetAddress = list[i];
      if (a.address.length === 0) continue;
      parts.push(a.mask > 0 ? (a.address + '/' + a.mask) : a.address);
    }
    return parts.length > 0 ? parts.join('\n') : '--';
  }

  private formatUptime(seconds: number): string {
    if (seconds <= 0) return '--';
    const d: number = Math.floor(seconds / 86400);
    const h: number = Math.floor((seconds % 86400) / 3600);
    const m: number = Math.floor((seconds % 3600) / 60);
    if (d > 0) return d + '天' + h + '小时';
    if (h > 0) return h + '小时' + m + '分';
    return m + '分钟';
  }

  private formatDuration(seconds: number): string {
    if (seconds <= 0) return '--';
    const h: number = Math.floor(seconds / 3600);
    if (h > 0) return h + '小时';
    return Math.floor(seconds / 60) + '分钟';
  }

  /** ubus 的速率是 1000F / 100F 这种，翻译一下 */
  private formatSpeed(speed: string): string {
    if (speed === '1000F') return '1000 Mbps 全双工';
    if (speed === '100F') return '100 Mbps 全双工';
    if (speed === '10F') return '10 Mbps 全双工';
    if (speed === '1000H') return '1000 Mbps 半双工';
    if (speed === '100H') return '100 Mbps 半双工';
    if (speed === '10H') return '10 Mbps 半双工';
    return speed;
  }

  private formatTraffic(bytes: number): string {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1048576) return (bytes / 1024).toFixed(1) + ' KB';
    if (bytes < 1073741824) return (bytes / 1048576).toFixed(1) + ' MB';
    if (bytes < 1099511627776) return (bytes / 1073741824).toFixed(2) + ' GB';
    return (bytes / 1099511627776).toFixed(2) + ' TB';
  }

  private formatCount(n: number): string {
    if (n < 10000) return String(n);
    if (n < 100000000) return (n / 10000).toFixed(1) + ' 万';
    return (n / 100000000).toFixed(2) + ' 亿';
  }

  /** 字节/秒 → 人看的速率 */
  private formatRate(bytesPerSec: number): string {
    if (bytesPerSec < 1) return '0 B/s';
    if (bytesPerSec < 1024) return bytesPerSec.toFixed(0) + ' B/s';
    if (bytesPerSec < 1048576) return (bytesPerSec / 1024).toFixed(1) + ' KB/s';
    if (bytesPerSec < 1073741824) return (bytesPerSec / 1048576).toFixed(2) + ' MB/s';
    return (bytesPerSec / 1073741824).toFixed(2) + ' GB/s';
  }

  /** 全零 MAC（loopback 等虚拟设备）不显示 */
  private hasRealMac(mac: string): boolean {
    if (mac.length === 0) return false;
    const normalized: string = mac.replace(/[:-]/g, '').toLowerCase();
    return normalized !== '000000000000';
  }

  /** 排序权重：lan → wan → wan6 → 其他 → loopback（放最后） */
  private orderOf(name: string): number {
    if (name === 'lan') return 0;
    if (name === 'wan') return 1;
    if (name === 'wan6') return 2;
    if (name === 'loopback') return 99;
    return 50;
  }
}
