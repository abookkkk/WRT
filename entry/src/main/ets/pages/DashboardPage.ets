/**
 * 首页仪表盘页面
 * 
 * 展示路由器关键状态信息。
 */

import { promptAction } from '@kit.ArkUI';
import { OpenWrtClient } from '../model/OpenWrtClient';
import type { SystemBoard, SystemInfo } from '../model/OpenWrtModels';

const COLOR_PRIMARY: ResourceColor = '#0078D4';
const COLOR_SECONDARY: ResourceColor = '#666666';
const COLOR_GREEN: ResourceColor = '#4CAF50';
const COLOR_ORANGE: ResourceColor = '#FF9800';
const COLOR_RED: ResourceColor = '#F44336';
// 自动刷新间隔（毫秒）
const AUTO_REFRESH_INTERVAL_MS: number = 1000;

@Component
export struct DashboardPage {
  private client!: OpenWrtClient;

  @State private isLoading: boolean = true;
  @State private deviceModel: string = '--';
  @State private firmwareVersion: string = '--';
  @State private kernelVersion: string = '--';
  @State private hostname: string = '--';
  @State private uptime: string = '--';
  @State private cpuLoad1: string = '--';
  @State private cpuLoad5: string = '--';
  @State private cpuLoad15: string = '--';
  @State private memoryTotal: string = '--';
  @State private memoryUsed: string = '--';
  @State private memoryPercent: number = 0;
  @State private onlineDevices: number = 0;
  @State private hasError: boolean = false;
  @State private errorMsg: string = '';
  private refreshTimer: number = -1;

  aboutToAppear(): void {
    this.loadAllData();
    this.startAutoRefresh();
  }

  aboutToDisappear(): void {
    this.stopAutoRefresh();
  }

  build() {
    Stack() {
      // 主内容区域
      if (!this.isLoading && !this.hasError) {
        Scroll() {
          Column() {
            // 卡片 1：路由器信息
            Column() {
              Text('路由器信息').fontSize(16).fontWeight(FontWeight.Bold).width('100%');
              this.routerInfoRows();
            }
            .width('100%').padding(20).backgroundColor('#F2FFFFFF').borderRadius(20).shadow(ShadowStyle.OUTER_DEFAULT_SM).margin({ bottom: 14 });

            // 卡片 2：运行状态
            Column() {
              Text('运行状态').fontSize(16).fontWeight(FontWeight.Bold).width('100%');
              this.runStatusRows();
            }
            .width('100%').padding(20).backgroundColor('#F2FFFFFF').borderRadius(20).shadow(ShadowStyle.OUTER_DEFAULT_SM).margin({ bottom: 14 });

            // 卡片 3：内存使用率
            Column() {
              Text('内存使用率').fontSize(16).fontWeight(FontWeight.Bold).width('100%').margin({ bottom: 12 });
              Row() {
                Text(this.memoryUsed).fontSize(20).fontWeight(FontWeight.Bold);
                Text(`/ ${this.memoryTotal}`).fontSize(14).fontColor(COLOR_SECONDARY).margin({ left: 4 });
              }
              Progress({ value: this.memoryPercent, total: 100, type: ProgressType.Linear })
                .width('100%').height(8).borderRadius(4)
                .color(this.memoryPercent < 50 ? COLOR_GREEN : (this.memoryPercent < 80 ? COLOR_ORANGE : COLOR_RED));
              Text(`${this.memoryPercent}%`)
                .fontSize(12).fontColor(COLOR_SECONDARY).width('100%').textAlign(TextAlign.End).margin({ top: 4 });
            }
            .width('100%').padding(20).backgroundColor('#F2FFFFFF').borderRadius(20).shadow(ShadowStyle.OUTER_DEFAULT_SM).margin({ bottom: 14 });

            // 卡片 4：在线设备
            Column() {
              Text('在线设备').fontSize(16).fontWeight(FontWeight.Bold).width('100%');
              Text(String(this.onlineDevices))
                .fontSize(40).fontWeight(FontWeight.Bold)
                .fontColor(this.onlineDevices > 0 ? COLOR_PRIMARY : '#000000');
              Text('台设备在线').fontSize(14).fontColor(COLOR_SECONDARY).margin({ top: 4 });
            }
            .width('100%').padding(20).backgroundColor('#F2FFFFFF').borderRadius(20).shadow(ShadowStyle.OUTER_DEFAULT_SM).margin({ bottom: 14 });

            // 刷新按钮
            Button('刷新数据')
              .width('100%').height(40).type(ButtonType.Capsule)
              .margin({ top: 4, bottom: 32 })
              .onClick(() => this.onRefresh());
          }
          .width('100%').padding(16)
        }
        .width('100%').height('100%')
        .scrollable(ScrollDirection.Vertical)
        .edgeEffect(EdgeEffect.Spring);
      }

      // 加载中
      if (this.isLoading) {
        Column() {
          LoadingProgress().width(32).height(32);
          Text('正在获取数据...').fontSize(14).margin({ top: 12 });
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center);
      }

      // 错误提示
      if (this.hasError) {
        Column() {
          Text('⚠️').fontSize(40);
          Text(this.errorMsg).fontSize(14).margin({ top: 12 });
          Button('重试').type(ButtonType.Capsule).margin({ top: 16 })
            .onClick(() => this.loadAllData());
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center);
      }
    }
    .width('100%').height('100%')
  }

  /**
   * 路由器信息行。
   *
   * 重要：必须**直接读 this.deviceModel 这些 @State**，不能把值当参数传进来。
   * ArkUI 的 @Builder 值传递参数不会建立状态依赖 —— 参数变了 UI 不会刷新。
   * 之前写成 row(label, value) 传参，导致静默自动刷新
   * （loadAllData(true) 不切换 isLoading、内容不重建）时这几行永远停在旧值。
   */
  @Builder
  routerInfoRows() {
    Column() {
      Row() {
        Text('设备型号').fontSize(14).fontColor(COLOR_SECONDARY);
        Text(this.deviceModel).fontSize(14).fontWeight(FontWeight.Medium)
          .layoutWeight(1).textAlign(TextAlign.End).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      .width('100%').justifyContent(FlexAlign.SpaceBetween).margin({ bottom: 8 })

      Row() {
        Text('OpenWrt 版本').fontSize(14).fontColor(COLOR_SECONDARY);
        Text(this.firmwareVersion).fontSize(14).fontWeight(FontWeight.Medium)
          .layoutWeight(1).textAlign(TextAlign.End).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      .width('100%').justifyContent(FlexAlign.SpaceBetween).margin({ bottom: 8 })

      Row() {
        Text('内核版本').fontSize(14).fontColor(COLOR_SECONDARY);
        Text(this.kernelVersion).fontSize(14).fontWeight(FontWeight.Medium)
          .layoutWeight(1).textAlign(TextAlign.End).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      .width('100%').justifyContent(FlexAlign.SpaceBetween).margin({ bottom: 8 })

      Row() {
        Text('主机名').fontSize(14).fontColor(COLOR_SECONDARY);
        Text(this.hostname).fontSize(14).fontWeight(FontWeight.Medium)
          .layoutWeight(1).textAlign(TextAlign.End).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      .width('100%').justifyContent(FlexAlign.SpaceBetween).margin({ bottom: 8 })
    }
    .width('100%')
  }

  /** 运行状态行（同上，直接读 @State 才能响应静默刷新） */
  @Builder
  runStatusRows() {
    Column() {
      Row() {
        Text('运行时长').fontSize(14).fontColor(COLOR_SECONDARY);
        Text(this.uptime).fontSize(14).fontWeight(FontWeight.Medium)
          .layoutWeight(1).textAlign(TextAlign.End).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      .width('100%').justifyContent(FlexAlign.SpaceBetween).margin({ bottom: 8 })

      Row() {
        Text('CPU 负载 (1min)').fontSize(14).fontColor(COLOR_SECONDARY);
        Text(this.cpuLoad1).fontSize(14).fontWeight(FontWeight.Medium)
          .layoutWeight(1).textAlign(TextAlign.End).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      .width('100%').justifyContent(FlexAlign.SpaceBetween).margin({ bottom: 8 })

      Row() {
        Text('CPU 负载 (5min)').fontSize(14).fontColor(COLOR_SECONDARY);
        Text(this.cpuLoad5).fontSize(14).fontWeight(FontWeight.Medium)
          .layoutWeight(1).textAlign(TextAlign.End).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      .width('100%').justifyContent(FlexAlign.SpaceBetween).margin({ bottom: 8 })

      Row() {
        Text('CPU 负载 (15min)').fontSize(14).fontColor(COLOR_SECONDARY);
        Text(this.cpuLoad15).fontSize(14).fontWeight(FontWeight.Medium)
          .layoutWeight(1).textAlign(TextAlign.End).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      .width('100%').justifyContent(FlexAlign.SpaceBetween).margin({ bottom: 8 })
    }
    .width('100%')
  }

  // ==================== 数据加载 ====================

  private async loadAllData(silent: boolean = false): Promise<void> {
    if (!this.client.isLoggedIn()) {
      this.hasError = true;
      this.errorMsg = '客户端未登录';
      this.isLoading = false;
      return;
    }

    if (!silent) {
      this.isLoading = true;
    }
    this.hasError = false;

    try {
      const boardResult = await this.client.getSystemBoard();
      const infoResult = await this.client.getSystemInfo();
      const deviceCount = await this.client.getOnlineDeviceCount();

      if (boardResult.success && boardResult.data) {
        const board: SystemBoard = boardResult.data;
        this.deviceModel = board.model || '--';
        this.firmwareVersion = board.release?.version || '--';
        this.kernelVersion = board.kernel || '--';
        this.hostname = board.hostname || '--';
      } else {
        this.hasError = true;
        this.errorMsg = `获取系统信息失败: ${boardResult.error || '未知错误'}`;
        return;
      }

      if (infoResult.success && infoResult.data) {
        const info: SystemInfo = infoResult.data;
        this.uptime = this.formatUptime(info.uptime);
        const load: number[] = info.load || [];
        this.cpuLoad1 = load.length > 0 ? load[0].toFixed(2) : '--';
        this.cpuLoad5 = load.length > 1 ? load[1].toFixed(2) : '--';
        this.cpuLoad15 = load.length > 2 ? load[2].toFixed(2) : '--';

        const mem = info.memory;
        const used: number = mem.total - mem.free - mem.buffered - (mem.cached || 0);
        this.memoryPercent = Math.round((used / mem.total) * 100);
        this.memoryTotal = this.formatBytes(mem.total);
        this.memoryUsed = this.formatBytes(used);
      } else {
        this.hasError = true;
        this.errorMsg = `获取运行信息失败: ${infoResult.error || '未知错误'}`;
        return;
      }

      this.onlineDevices = deviceCount;
    } catch (e) {
      this.hasError = true;
      this.errorMsg = '数据加载失败: ' + JSON.stringify(e);
    } finally {
      this.isLoading = false;
    }
  }

  private onRefresh(): void {
    promptAction.showToast({ message: '正在刷新...', duration: 1000 });
    this.loadAllData(true);
  }

  private startAutoRefresh(): void {
    if (this.refreshTimer >= 0) {
      return;
    }
    this.refreshTimer = setInterval(() => {
      this.loadAllData(true);
    }, AUTO_REFRESH_INTERVAL_MS);
  }

  private stopAutoRefresh(): void {
    if (this.refreshTimer >= 0) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = -1;
    }
  }

  private formatUptime(seconds: number): string {
    const days: number = Math.floor(seconds / 86400);
    const hours: number = Math.floor((seconds % 86400) / 3600);
    const mins: number = Math.floor((seconds % 3600) / 60);
    const parts: string[] = [];
    if (days > 0) parts.push(`${days}天`);
    if (hours > 0) parts.push(`${hours}小时`);
    if (mins > 0) parts.push(`${mins}分钟`);
    if (parts.length === 0) parts.push('不到1分钟');
    return parts.join(' ');
  }

  private formatBytes(bytes: number): string {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)} KB`;
    if (bytes < 1073741824) return `${(bytes / 1048576).toFixed(1)} MB`;
    return `${(bytes / 1073741824).toFixed(1)} GB`;
  }
}
