/**
 * 在线设备页面
 * 
 * 展示路由器的 DHCP 租约列表。
 */

import { promptAction } from '@kit.ArkUI';
import { OpenWrtClient } from '../model/OpenWrtClient';
import type { DhcpLease } from '../model/OpenWrtModels';

const COLOR_CARD_BG: ResourceColor = '#F2FFFFFF';
const COLOR_SECONDARY: ResourceColor = '#666666';
const COLOR_TERTIARY: ResourceColor = '#999999';
const COLOR_PRIMARY: ResourceColor = '#0078D4';

@Component
export struct DevicesPage {
  private client!: OpenWrtClient;

  @State private devices: DhcpLease[] = [];
  @State private isLoading: boolean = true;
  @State private isRefreshing: boolean = false;
  @State private hasError: boolean = false;
  @State private errorMsg: string = '';
  @State private activeCount: number = 0;

  aboutToAppear(): void {
    this.loadDevices();
  }

  build() {
    Stack() {
      if (!this.isLoading && !this.hasError) {
        Column() {
          // 统计头部
          Row() {
            Text('在线设备').fontSize(16).fontWeight(FontWeight.Bold);
            Text(`${this.activeCount} 台`).fontSize(14).fontColor(COLOR_PRIMARY).margin({ left: 8 });
            Text(`共 ${this.devices.length} 个租约`).fontSize(12).fontColor(COLOR_SECONDARY).margin({ left: 4 });
          }
          .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 4 });

          List() {
            ForEach(this.devices, (device: DhcpLease) => {
              ListItem() {
                // 设备卡片（不拆分 @Builder，全内联）
                Column() {
                  Row() {
                    // 用文本代替 Circle 头像
                    Text(this.getInitial(device.hostname))
                      .fontSize(18)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(Color.White)
                      .textAlign(TextAlign.Center)
                      .width(40).height(40)
                      .backgroundColor(this.getDeviceColor(device.hostname))
                      .borderRadius(20)
                      .margin({ right: 12 });

                    Column() {
                      Text(device.hostname || '(未命名设备)')
                        .fontSize(15).fontWeight(FontWeight.Bold)
                        .lineHeight(20).maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis });
                      Text(device.mac)
                        .fontSize(13).fontColor(COLOR_SECONDARY)
                        .fontFamily('monospace').margin({ top: 2 });
                    }
                    .layoutWeight(1);

                    // 状态指示灯用文本替代
                    Text(this.isLeaseActive(device) ? '●' : '○')
                      .fontSize(14)
                      .fontColor(this.isLeaseActive(device) ? Color.Green : Color.Gray);
                  }
                  .width('100%').margin({ bottom: 8 });

                  Row() {
                    Text(device.ip).fontSize(14).fontWeight(FontWeight.Medium).fontFamily('monospace');
                    Text(this.formatExpiry(device.end))
                      .fontSize(12)
                      .fontColor(this.isLeaseActive(device) ? COLOR_SECONDARY : Color.Red);
                  }
                  .width('100%').justifyContent(FlexAlign.SpaceBetween);
                }
                .width('100%').padding(16).backgroundColor(COLOR_CARD_BG)
                .borderRadius(18).shadow(ShadowStyle.OUTER_DEFAULT_SM)
                .margin({ left: 16, right: 16, bottom: 10 });
              }
            }, (device: DhcpLease, index?: number) => {
              return device.mac + device.ip;
            });
          }
          .width('100%').layoutWeight(1).edgeEffect(EdgeEffect.Spring)
          .onReachStart(() => this.refreshData());
        }
        .width('100%').height('100%');
      }

      if (!this.isLoading && !this.hasError && this.devices.length === 0) {
        Column() {
          Text('📡').fontSize(48);
          Text('未找到 DHCP 租约').fontSize(16).fontColor(COLOR_SECONDARY).margin({ top: 12 });
          Text('请确保路由器开启了 DHCP 服务器').fontSize(13).fontColor(COLOR_TERTIARY).margin({ top: 4 });
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center);
      }

      if (this.isLoading) {
        LoadingProgress().width(32).height(32);
      }
      if (this.hasError) {
        Column() {
          Text('⚠️').fontSize(40);
          Text(this.errorMsg).fontSize(14).margin({ top: 12 });
          Button('重试').type(ButtonType.Capsule).margin({ top: 16 })
            .onClick(() => this.loadDevices());
        }
      }
    }
    .width('100%').height('100%')
  }

  // ==================== 数据加载 ====================

  private async loadDevices(): Promise<void> {
    if (!this.client.isLoggedIn()) {
      this.hasError = true;
      this.errorMsg = '未登录';
      this.isLoading = false;
      return;
    }

    this.isLoading = true;
    this.hasError = false;

    try {
      const result = await this.client.getDhcpLeases();
      if (result.success && result.data) {
        this.devices = result.data;
        const now: number = Math.floor(Date.now() / 1000);
        this.activeCount = result.data.filter((d: DhcpLease) => d.end > now).length;
      } else {
        this.hasError = true;
        this.errorMsg = result.error || '获取租约数据失败';
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
    this.loadDevices();
  }

  private isLeaseActive(device: DhcpLease): boolean {
    const now: number = Math.floor(Date.now() / 1000);
    return device.end > now;
  }

  private formatExpiry(endTimestamp: number): string {
    const now: number = Math.floor(Date.now() / 1000);
    const remaining: number = endTimestamp - now;
    if (remaining <= 0) return '已过期';
    const hours: number = Math.floor(remaining / 3600);
    const mins: number = Math.floor((remaining % 3600) / 60);
    if (hours > 24) return `${Math.floor(hours / 24)}天后过期`;
    if (hours > 0) return `${hours}小时${mins}分后过期`;
    return `${mins}分后过期`;
  }

  private getInitial(hostname: string): string {
    if (!hostname) return '?';
    return hostname.charAt(0).toUpperCase();
  }

  private getDeviceColor(hostname: string): ResourceColor {
    const colors: ResourceColor[] = ['#4A90D9', '#7B61FF', '#E8725A', '#50B87A', '#D9A845', '#5AB0D9', '#D96BA5', '#6BC9B0'];
    if (!hostname) return colors[0];
    let hash: number = 0;
    for (let i = 0; i < hostname.length; i++) {
      hash = hostname.charCodeAt(i) + ((hash << 5) - hash);
    }
    const idx: number = Math.abs(hash) % colors.length;
    return colors[idx];
  }
}
