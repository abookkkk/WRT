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

import { promptAction } from '@kit.ArkUI';
import { OpenWrtClient } from '../model/OpenWrtClient';
import type { NetworkInterface, NetAddress } from '../model/OpenWrtModels';
import {
  C_PRIMARY, C_SUCCESS, C_WARNING, C_TEXT_1, C_TEXT_2, C_TEXT_3,
  C_CARD, C_DIVIDER, C_FILL,
  F_SECTION, F_BODY, F_CAPTION, F_TINY,
  R_CARD, R_CHIP, SP_S, SP_M, SP_L, SP_XL, ICON_S
} from '../common/Theme';

const COLOR_CARD_BG: ResourceColor = C_CARD;

@Component
export struct NetworkPage {
  private client!: OpenWrtClient;

  @State private interfaces: NetworkInterface[] = [];
  @State private isLoading: boolean = true;
  @State private isRefreshing: boolean = false;
  @State private hasError: boolean = false;
  @State private errorMsg: string = '';
  /** 每次加载自增，用来强制 ForEach 重建卡片（否则 @Builder 的值传递参数不会刷新） */
  @State private dataVersion: number = 0;

  aboutToAppear(): void {
    this.loadNetworkData();
  }

  build() {
    Stack() {
      if (!this.isLoading && !this.hasError) {
        // 下拉刷新用 Refresh 组件。
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
            .padding(SP_L)
          }
          .width('100%')
          .height('100%')
          .edgeEffect(EdgeEffect.Spring)
        }
        .width('100%')
        .height('100%')
        .onRefreshing(() => {
          this.refreshData();
        })
      }

      if (this.isLoading) {
        LoadingProgress().width(32).height(32);
      }

      if (this.hasError) {
        Column() {
          Text('⚠️').fontSize(40);
          Text(this.errorMsg).fontSize(F_BODY).margin({ top: SP_M });
          Button('重试').type(ButtonType.Capsule).margin({ top: SP_L })
            .onClick(() => this.loadNetworkData());
        }
      }
    }
    .width('100%')
    .height('100%')
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
        .backgroundColor(iface.up ? '#1A1DB954' : C_FILL)
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

  private async loadNetworkData(): Promise<void> {
    if (!this.client.isLoggedIn()) {
      this.hasError = true;
      this.errorMsg = '未登录';
      this.isLoading = false;
      return;
    }

    this.isLoading = true;
    this.hasError = false;

    try {
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
      } else {
        this.hasError = true;
        this.errorMsg = result.error || '获取接口数据失败';
      }
    } catch (e) {
      this.hasError = true;
      this.errorMsg = '请求异常: ' + JSON.stringify(e);
    } finally {
      this.isLoading = false;
      this.isRefreshing = false;
    }
  }

  private refreshData(): void {
    if (this.isRefreshing) return;
    this.isRefreshing = true;
    promptAction.showToast({ message: '正在刷新...', duration: 800 });
    this.loadNetworkData();
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
