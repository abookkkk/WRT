/**
 * 首页仪表盘页面
 * 
 * 展示路由器关键状态信息。
 */

import { promptAction } from '@kit.ArkUI';
import { OpenWrtClient } from '../model/OpenWrtClient';
import type { SystemBoard, SystemInfo, NetDeviceStats } from '../model/OpenWrtModels';
import {
  C_SUCCESS, C_WARNING, C_TEXT_1, C_TEXT_2, C_TEXT_3, C_CARD,
  F_SECTION, F_TINY, R_CARD, SP_S, SP_M, SP_XL, ICON_S
} from '../common/Theme';

const COLOR_PRIMARY: ResourceColor = '#0078D4';
const COLOR_SECONDARY: ResourceColor = '#666666';
const COLOR_GREEN: ResourceColor = '#4CAF50';
const COLOR_ORANGE: ResourceColor = '#FF9800';
const COLOR_RED: ResourceColor = '#F44336';
// 自动刷新间隔（毫秒）
// 注意：每次刷新要发 3 个 ubus 请求（system.board + system.info + luci-rpc.getDHCPLeases），
// 原来写 1000（1 秒）等于每秒 3 次请求去轰炸一台 256MB 的路由器，太长不看也得改。
// 30 秒足够体现 CPU/内存的变化，对路由器也友好。
const AUTO_REFRESH_INTERVAL_MS: number = 30000;

/** 实时网速的采样间隔（毫秒）。一次采样只要 1 个 ubus 请求。 */
const RATE_SAMPLE_MS: number = 2000;
/** 趋势图保留的采样点数：30 × 2 秒 = 最近 60 秒 */
const RATE_HISTORY: number = 30;

/** 一次速率采样 */
class RatePoint {
  rx: number = 0;
  tx: number = 0;
}

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

  // ---- 实时网速 ----
  @State private wanRxRate: number = 0;
  @State private wanTxRate: number = 0;
  @State private rateReady: boolean = false;
  @State private wanDevice: string = '';

  private rateTimer: number = -1;
  /** 页面不可见时暂停采样 */
  private pageVisible: boolean = true;
  private rateHistory: RatePoint[] = [];
  private prevRx: number = 0;
  private prevTx: number = 0;
  private prevStamp: number = 0;

  /** 趋势图画布 */
  private canvasSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private canvasCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.canvasSettings);

  aboutToAppear(): void {
    this.loadAllData();
    this.startAutoRefresh();
    this.initUplink();
    this.startRateSampler();
  }

  aboutToDisappear(): void {
    this.stopAutoRefresh();
    this.stopRateSampler();
  }

  build() {
    Stack() {
      // 主内容区域
      if (!this.isLoading && !this.hasError) {
        Scroll() {
          Column() {
            // ===== 卡片 0：实时网速 + 60 秒趋势图 =====
            Column() {
              Row() {
                Text('实时网速')
                  .fontSize(F_SECTION)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(C_TEXT_1)
                  .layoutWeight(1);
                Text(this.wanDevice.length > 0 ? ('WAN · ' + this.wanDevice) : 'WAN')
                  .fontSize(F_TINY)
                  .fontColor(C_TEXT_3)
                  .fontFamily('monospace');
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .margin({ bottom: SP_M });

              Row() {
                // 下行
                Column() {
                  Row() {
                    SymbolGlyph($r('sys.symbol.arrow_down'))
                      .fontSize(ICON_S)
                      .fontColor([C_SUCCESS])
                      .renderingStrategy(SymbolRenderingStrategy.SINGLE);
                    Text('接收').fontSize(F_TINY).fontColor(C_TEXT_2).margin({ left: 4 });
                  }
                  .alignItems(VerticalAlign.Center);

                  Text(this.rateReady ? this.formatRate(this.wanRxRate) : '--')
                    .fontSize(24)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(C_TEXT_1)
                    .margin({ top: 2 });
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start);

                // 上行
                Column() {
                  Row() {
                    SymbolGlyph($r('sys.symbol.arrow_up'))
                      .fontSize(ICON_S)
                      .fontColor([C_WARNING])
                      .renderingStrategy(SymbolRenderingStrategy.SINGLE);
                    Text('发送').fontSize(F_TINY).fontColor(C_TEXT_2).margin({ left: 4 });
                  }
                  .alignItems(VerticalAlign.Center);

                  Text(this.rateReady ? this.formatRate(this.wanTxRate) : '--')
                    .fontSize(24)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(C_TEXT_1)
                    .margin({ top: 2 });
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start);
              }
              .width('100%');

              // 趋势图（Canvas 手绘，见 drawChart()）
              Canvas(this.canvasCtx)
                .width('100%')
                .height(76)
                .margin({ top: SP_M })
                .onReady(() => {
                  this.drawChart();
                });

              Text('最近 60 秒 · 每 2 秒采样')
                .fontSize(F_TINY)
                .fontColor(C_TEXT_3)
                .width('100%')
                .margin({ top: 2 });
            }
            .width('100%').padding(SP_XL).backgroundColor('#F2FFFFFF')
            .borderRadius(R_CARD).shadow(ShadowStyle.OUTER_DEFAULT_SM)
            .margin({ bottom: 14 });

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
    // 页面滑出屏幕后暂停速率采样
    .onVisibleAreaChange([0.0, 0.5], (isVisible: boolean, ratio: number) => {
      this.pageVisible = isVisible;
    })
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

  // ==================== 实时网速 ====================

  /** 找出出口设备（优先 wan，其次第一个带默认网关的接口） */
  private async initUplink(): Promise<void> {
    try {
      const dev: string = await this.client.findUplinkDevice();
      this.wanDevice = dev;
    } catch (e) {
      console.warn('[Dashboard] 找出口设备失败: ' + JSON.stringify(e));
    }
  }

  private startRateSampler(): void {
    if (this.rateTimer >= 0) {
      return;
    }
    this.rateTimer = setInterval(() => {
      if (this.pageVisible) {
        this.sampleRate();
      }
    }, RATE_SAMPLE_MS);
  }

  private stopRateSampler(): void {
    if (this.rateTimer >= 0) {
      clearInterval(this.rateTimer);
      this.rateTimer = -1;
    }
  }

  /**
   * 采一次样并算出上/下行速率。
   * 只发 1 个请求：luci-rpc.getNetworkDevices 一次返回所有网卡的 stats。
   */
  private async sampleRate(): Promise<void> {
    if (!this.client.isLoggedIn() || this.wanDevice.length === 0) {
      return;
    }

    const stats: NetDeviceStats[] = await this.client.getAllDeviceStats();
    let cur: NetDeviceStats | null = null;
    for (let i = 0; i < stats.length; i++) {
      if (stats[i].device === this.wanDevice) {
        cur = stats[i];
      }
    }
    if (cur === null) {
      return;
    }

    const now: number = Date.now();
    const dt: number = this.prevStamp > 0 ? (now - this.prevStamp) / 1000 : 0;

    if (this.prevStamp > 0 && dt > 0.5) {
      let drx: number = cur.rxBytes - this.prevRx;
      let dtx: number = cur.txBytes - this.prevTx;
      // 路由器重启会让计数器归零，delta 变负数时钳到 0
      if (drx < 0) drx = 0;
      if (dtx < 0) dtx = 0;

      this.wanRxRate = drx / dt;
      this.wanTxRate = dtx / dt;
      this.rateReady = true;

      const p: RatePoint = new RatePoint();
      p.rx = this.wanRxRate;
      p.tx = this.wanTxRate;
      this.rateHistory.push(p);
      while (this.rateHistory.length > RATE_HISTORY) {
        this.rateHistory.shift();
      }
      this.drawChart();
    }

    this.prevRx = cur.rxBytes;
    this.prevTx = cur.txBytes;
    this.prevStamp = now;
  }

  /**
   * 画最近 60 秒的速率曲线。
   *
   * 用 Canvas + 命令式绘制（而不是声明式的 Shape）：能拿到画布真实宽高自适应屏幕，
   * 也能在数据更新时直接重绘。最新的点在右边，采样不足时曲线从左往右生长。
   * 绿色 = 下行（带渐变填充），橙色 = 上行。
   */
  private drawChart(): void {
    const w: number = this.canvasCtx.width;
    const h: number = this.canvasCtx.height;
    if (w <= 0 || h <= 0) {
      return;
    }

    this.canvasCtx.clearRect(0, 0, w, h);

    const n: number = this.rateHistory.length;
    if (n < 2) {
      return;
    }

    // Y 轴上限取窗口内最大值，下限 1 KB/s，避免除零和曲线抖动
    let max: number = 1024;
    for (let i = 0; i < n; i++) {
      if (this.rateHistory[i].rx > max) {
        max = this.rateHistory[i].rx;
      }
      if (this.rateHistory[i].tx > max) {
        max = this.rateHistory[i].tx;
      }
    }

    const padTop: number = 3;
    const usable: number = h - padTop;
    const stepX: number = w / (RATE_HISTORY - 1);
    const x0: number = w - (n - 1) * stepX;

    // 基线
    this.canvasCtx.beginPath();
    this.canvasCtx.lineWidth = 1;
    this.canvasCtx.strokeStyle = '#14000000';
    this.canvasCtx.moveTo(0, h - 0.5);
    this.canvasCtx.lineTo(w, h - 0.5);
    this.canvasCtx.stroke();

    // 下行：先填充曲线下方
    this.canvasCtx.beginPath();
    this.canvasCtx.moveTo(x0, h);
    for (let i = 0; i < n; i++) {
      const x: number = x0 + i * stepX;
      const y: number = padTop + usable * (1 - this.rateHistory[i].rx / max);
      this.canvasCtx.lineTo(x, y);
    }
    this.canvasCtx.lineTo(x0 + (n - 1) * stepX, h);
    this.canvasCtx.closePath();
    this.canvasCtx.fillStyle = 'rgba(29, 185, 84, 0.16)';
    this.canvasCtx.fill();

    // 下行：描边
    this.canvasCtx.beginPath();
    this.canvasCtx.lineWidth = 2;
    this.canvasCtx.lineJoin = 'round';
    this.canvasCtx.lineCap = 'round';
    this.canvasCtx.strokeStyle = C_SUCCESS;
    for (let i = 0; i < n; i++) {
      const x: number = x0 + i * stepX;
      const y: number = padTop + usable * (1 - this.rateHistory[i].rx / max);
      if (i === 0) {
        this.canvasCtx.moveTo(x, y);
      } else {
        this.canvasCtx.lineTo(x, y);
      }
    }
    this.canvasCtx.stroke();

    // 上行：只描边
    this.canvasCtx.beginPath();
    this.canvasCtx.lineWidth = 2;
    this.canvasCtx.lineJoin = 'round';
    this.canvasCtx.lineCap = 'round';
    this.canvasCtx.strokeStyle = C_WARNING;
    for (let i = 0; i < n; i++) {
      const x: number = x0 + i * stepX;
      const y: number = padTop + usable * (1 - this.rateHistory[i].tx / max);
      if (i === 0) {
        this.canvasCtx.moveTo(x, y);
      } else {
        this.canvasCtx.lineTo(x, y);
      }
    }
    this.canvasCtx.stroke();
  }

  /** 字节/秒 → 人看的速率 */
  private formatRate(bytesPerSec: number): string {
    if (bytesPerSec < 1) return '0 B/s';
    if (bytesPerSec < 1024) return bytesPerSec.toFixed(0) + ' B/s';
    if (bytesPerSec < 1048576) return (bytesPerSec / 1024).toFixed(1) + ' KB/s';
    if (bytesPerSec < 1073741824) return (bytesPerSec / 1048576).toFixed(2) + ' MB/s';
    return (bytesPerSec / 1073741824).toFixed(2) + ' GB/s';
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
