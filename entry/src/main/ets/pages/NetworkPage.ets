/**
 * 网络接口页面
 * 
 * 列出路由器所有网络接口的状态：
 * 接口名、运行状态、IP 地址、收发流量统计。
 */

import { promptAction } from '@kit.ArkUI';
import { OpenWrtClient } from '../model/OpenWrtClient';
import type { NetworkInterface } from '../model/OpenWrtModels';

/** 颜色常量 */
const COLOR_CARD_BG: ResourceColor = '#FFFFFF';
const COLOR_SECONDARY: ResourceColor = '#666666';

@Component
export struct NetworkPage {
  private client!: OpenWrtClient;

  @State private interfaces: NetworkInterface[] = [];
  @State private isLoading: boolean = true;
  @State private hasError: boolean = false;
  @State private errorMsg: string = '';

  aboutToAppear(): void {
    this.loadNetworkData();
  }

  build() {
    Stack() {
      if (!this.isLoading && !this.hasError) {
        Scroll() {
          Column() {
            ForEach(this.interfaces, (iface: NetworkInterface) => {
              this.buildInterfaceCard(iface);
            }, (iface: NetworkInterface, index?: number) => {
              return iface.interface + String(index);
            });
          }
          .width('100%')
          .padding(16)
        }
        .width('100%')
        .height('100%')
        .edgeEffect(EdgeEffect.Spring)
        .onReachStart(() => this.refreshData())
      }

      if (this.isLoading) {
        LoadingProgress().width(32).height(32);
      }

      if (this.hasError) {
        Column() {
          Text('⚠️').fontSize(40);
          Text(this.errorMsg).fontSize(14).margin({ top: 12 });
          Button('重试').type(ButtonType.Capsule).margin({ top: 16 })
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
      // 头部：接口名 + 状态标识
      Row() {
        Text(iface.interface.startsWith('wan') ? '🌐' : '📶')
          .fontSize(20)
          .margin({ right: 8 });

        Text(iface.interface.toUpperCase())
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1);

        Text(iface.up ? '已连接' : '已断开')
          .fontSize(12)
          .fontColor(Color.White)
          .padding({ left: 10, right: 10, top: 3, bottom: 3 })
          .backgroundColor(iface.up ? Color.Green : Color.Gray)
          .borderRadius(10);
      }
      .width('100%')
      .margin({ bottom: 12 });

      // 详情行
      if (iface.proto) {
        this.buildDetailRow('协议', iface.proto.toUpperCase());
      }
      if (iface.device) {
        this.buildDetailRow('设备', iface.device);
      }
      if (iface.ipaddr) {
        this.buildDetailRow('IPv4', iface.ipaddr);
      }
      if (iface.gateway) {
        this.buildDetailRow('网关', iface.gateway);
      }
      if (iface.netmask) {
        this.buildDetailRow('子网掩码', iface.netmask);
      }
      if (iface.dns && iface.dns.length > 0) {
        this.buildDetailRow('DNS', iface.dns.join(', '));
      }

      // 流量统计
      if (iface.data) {
        Divider().margin({ top: 8, bottom: 8 });
        Row() {
          Column() {
            Text('↓ 接收').fontSize(12).fontColor(COLOR_SECONDARY);
            Text(this.formatTraffic(iface.data?.rx_bytes || 0))
              .fontSize(16).fontWeight(FontWeight.Bold)
              .fontColor(Color.Green);
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start);

          Column() {
            Text('↑ 发送').fontSize(12).fontColor(COLOR_SECONDARY);
            Text(this.formatTraffic(iface.data?.tx_bytes || 0))
              .fontSize(16).fontWeight(FontWeight.Bold)
              .fontColor(Color.Orange);
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.End);
        }
        .width('100%');
      }
    }
    .width('100%')
    .padding(20)
    .backgroundColor(COLOR_CARD_BG)
    .borderRadius(20)
    .shadow(ShadowStyle.OUTER_DEFAULT_SM)
    .margin({ bottom: 14 })
  }

  @Builder
  buildDetailRow(label: string, value: string) {
    Row() {
      Text(label).fontSize(13).fontColor(COLOR_SECONDARY).width(70);
      Text(value).fontSize(13).fontWeight(FontWeight.Medium)
        .layoutWeight(1)
        .textAlign(TextAlign.End)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
    }
    .width('100%')
    .margin({ bottom: 4 })
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
      const result = await this.client.getNetworkDump();
      console.info('[NetworkPage] API 响应: ' + JSON.stringify(result));

      if (result.success && result.data) {
        console.info('[NetworkPage] 接口数据: ' + JSON.stringify(result.data));
        this.interfaces = result.data.interface || [];
        console.info('[NetworkPage] 解析到 ' + this.interfaces.length + ' 个接口');
      } else {
        this.hasError = true;
        this.errorMsg = result.error || '获取接口数据失败';
        console.error('[NetworkPage] 错误: ' + this.errorMsg);
      }
    } catch (e) {
      this.hasError = true;
      this.errorMsg = '请求异常: ' + JSON.stringify(e);
      console.error('[NetworkPage] 异常: ' + JSON.stringify(e));
    } finally {
      this.isLoading = false;
    }
  }

  private refreshData(): void {
    promptAction.showToast({ message: '正在刷新...', duration: 800 });
    this.loadNetworkData();
  }

  // ==================== 工具方法 ====================

  private formatTraffic(bytes: number): string {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)} KB`;
    if (bytes < 1073741824) return `${(bytes / 1048576).toFixed(1)} MB`;
    if (bytes < 1099511627776) return `${(bytes / 1073741824).toFixed(1)} GB`;
    return `${(bytes / 1099511627776).toFixed(1)} TB`;
  }
}
