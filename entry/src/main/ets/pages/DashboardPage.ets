/**
 * 首页仪表盘页面
 * 
 * 展示路由器关键状态信息。
 */

import { OpenWrtClient } from '../model/OpenWrtClient';
import type { SystemBoard, SystemInfo, NetDeviceStats } from '../model/OpenWrtModels';
import {
  C_PRIMARY, C_SUCCESS, C_WARNING, C_DANGER, C_DIVIDER,
  C_TEXT_1, C_TEXT_2, C_TEXT_3, C_CARD,
  F_SECTION, F_TINY, R_CARD, SP_S, SP_M, SP_XL, ICON_S,
  colorString, colorRgba
} from '../common/Theme';
import { shouldShowErrorPage, shouldToast, notifyLoadFailed } from '../common/RefreshPolicy';
import type { LoadKind } from '../common/RefreshPolicy';

// 颜色统一走 Theme 里的资源（浅色/深色两套自动切换），页面内不再写死色值
const COLOR_PRIMARY: ResourceColor = C_PRIMARY;
const COLOR_SECONDARY: ResourceColor = C_TEXT_2;
const COLOR_GREEN: ResourceColor = C_SUCCESS;
const COLOR_ORANGE: ResourceColor = C_WARNING;
const COLOR_RED: ResourceColor = C_DANGER;
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
  /** 点「在线设备」卡片 → 打开二级页面（由 HomePage 传入） */
  onOpenDevices: () => void = () => {};
  /** 点「实时网速」卡片 → 打开「测网速」二级页面 */
  onOpenSpeedTest: () => void = () => {};

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
  @State private memoryAvailable: string = '--';
  @State private memoryPercent: number = 0;
  @State private onlineDevices: number = 0;
  @State private hasError: boolean = false;
  @State private errorMsg: string = '';
  /** 下拉刷新中：只驱动 Refresh 的顶部指示器，不参与整页 Loading */
  @State private isRefreshing: boolean = false;
  private refreshTimer: number = -1;

  // ---- 实时网速 ----
  @State private wanRxRate: number = 0;
  @State private wanTxRate: number = 0;
  @State private rateReady: boolean = false;
  @State private wanDevice: string = '';
  /** 上下行各自的量程峰值（双 Y 轴，两条曲线互不压缩） */
  @State private rxPeakLabel: string = '--';
  @State private txPeakLabel: string = '--';

  private rateTimer: number = -1;
  /** 页面不可见时暂停采样 */
  private pageVisible: boolean = true;
  private rateHistory: RatePoint[] = [];
  private prevRx: number = 0;
  private prevTx: number = 0;
  private prevStamp: number = 0;
  /** 绘图用的峰值（非状态，drawChart 直接读） */
  private rxPeak: number = 0;
  private txPeak: number = 0;

  /** 趋势图画布 */
  private canvasSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private canvasCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.canvasSettings);

  aboutToAppear(): void {
    this.loadData();
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
      // 统一刷新（规范见 common/RefreshPolicy.ets）：下拉刷新是全局唯一手势，
      // 可滚动内容整体放在 Refresh 里，指示器永远出现在页面内容最上方。
      if (!this.isLoading && !this.hasError) {
        Refresh({ refreshing: this.isRefreshing }) {
          Scroll() {
            Column() {
              // ===== 卡片 0：实时网速 + 60 秒趋势图（点进去是「测网速」二级页面）=====
              Column() {
                Row() {
                  Text('实时网速')
                    .fontSize(F_SECTION)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(C_TEXT_1)
                    .layoutWeight(1);
                  // 右侧箭头表示"点得进去"
                  SymbolGlyph($r('sys.symbol.chevron_right'))
                    .fontSize(ICON_S)
                    .fontColor([C_TEXT_3])
                    .renderingStrategy(SymbolRenderingStrategy.SINGLE);
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

                    Text('峰值 ' + this.rxPeakLabel)
                      .fontSize(10)
                      .fontColor(C_SUCCESS)
                      .margin({ top: 1 });
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

                    Text('峰值 ' + this.txPeakLabel)
                      .fontSize(10)
                      .fontColor(C_WARNING)
                      .margin({ top: 1 });
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

              }
              .width('100%').padding(SP_XL).backgroundColor(C_CARD)
              .borderRadius(R_CARD).shadow(ShadowStyle.OUTER_DEFAULT_SM)
              .margin({ bottom: 14 })
              .onClick(() => this.onOpenSpeedTest());

              // 卡片 1：路由器信息
              Column() {
                Text('路由器信息').fontSize(16).fontWeight(FontWeight.Bold).width('100%');
                this.routerInfoRows();
              }
              .width('100%').padding(20).backgroundColor(C_CARD).borderRadius(20).shadow(ShadowStyle.OUTER_DEFAULT_SM).margin({ bottom: 14 });

              // 卡片 2：运行状态
              Column() {
                Text('运行状态').fontSize(16).fontWeight(FontWeight.Bold).width('100%');
                this.runStatusRows();
              }
              .width('100%').padding(20).backgroundColor(C_CARD).borderRadius(20).shadow(ShadowStyle.OUTER_DEFAULT_SM).margin({ bottom: 14 });

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

                Row() {
                  Text('可用').fontSize(12).fontColor(COLOR_SECONDARY);
                  Blank();
                  Text(this.memoryAvailable).fontSize(12).fontColor(COLOR_SECONDARY);
                }
                .width('100%').margin({ top: 6 });
              }
              .width('100%').padding(20).backgroundColor(C_CARD).borderRadius(20).shadow(ShadowStyle.OUTER_DEFAULT_SM).margin({ bottom: 14 });

              // 卡片 4：在线设备
              Column() {
                Row() {
                  Text('在线设备').fontSize(16).fontWeight(FontWeight.Bold).layoutWeight(1);
                  // 右侧箭头表示"点得进去"：点开是二级页面（HomePage.devicesDestination）
                  SymbolGlyph($r('sys.symbol.chevron_right'))
                    .fontSize(ICON_S)
                    .fontColor([C_TEXT_3])
                    .renderingStrategy(SymbolRenderingStrategy.SINGLE);
                }
                .width('100%')
                .alignItems(VerticalAlign.Center);

                Text(String(this.onlineDevices))
                  .fontSize(40).fontWeight(FontWeight.Bold)
                  .fontColor(this.onlineDevices > 0 ? COLOR_PRIMARY : C_TEXT_1);
                Text('台设备在线 · 点开看完整列表')
                  .fontSize(14).fontColor(COLOR_SECONDARY).margin({ top: 4 });
              }
              .width('100%').padding(20).backgroundColor(C_CARD).borderRadius(20).shadow(ShadowStyle.OUTER_DEFAULT_SM).margin({ bottom: 14 })
              .onClick(() => this.onOpenDevices());
            }
            .width('100%').padding(16)
          }
          .width('100%').height('100%')
          .scrollable(ScrollDirection.Vertical)
          .edgeEffect(EdgeEffect.Spring);
        }
        .width('100%')
        .height('100%')
        .onRefreshing(() => this.onPullRefresh());
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
            .onClick(() => this.loadData());
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
   * （loadData('quiet') 不切换 isLoading、内容不重建）时这几行永远停在旧值。
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

  /**
   * 加载仪表盘数据 —— 本页唯一的取数入口（刷新规范见 common/RefreshPolicy.ets）。
   * kind 决定 Loading 与失败反馈：'first' 首屏 / 'pull' 下拉刷新 / 'quiet' 定时器与后台重载。
   */
  private async loadData(kind: LoadKind = 'first'): Promise<void> {
    if (kind === 'first') {
      this.isLoading = true;
    }

    try {
      if (!this.client.isLoggedIn()) {
        this.failLoad('客户端未登录', kind);
        return;
      }

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
        this.failLoad(`获取系统信息失败: ${boardResult.error || '未知错误'}`, kind);
        return;
      }

      if (infoResult.success && infoResult.data) {
        const info: SystemInfo = infoResult.data;
        this.uptime = this.formatUptime(info.uptime);
        const load: number[] = info.load || [];
        this.cpuLoad1 = load.length > 0 ? this.normalizeLoad(load[0]).toFixed(2) : '--';
        this.cpuLoad5 = load.length > 1 ? this.normalizeLoad(load[1]).toFixed(2) : '--';
        this.cpuLoad15 = load.length > 2 ? this.normalizeLoad(load[2]).toFixed(2) : '--';

        const mem = info.memory;
        const used: number = mem.total - mem.free - mem.buffered - (mem.cached || 0);
        this.memoryPercent = Math.round((used / mem.total) * 100);
        this.memoryTotal = this.formatBytes(mem.total);
        this.memoryUsed = this.formatBytes(used);
        this.memoryAvailable = mem.available ? this.formatBytes(mem.available) : '--';
      } else {
        this.failLoad(`获取运行信息失败: ${infoResult.error || '未知错误'}`, kind);
        return;
      }

      this.onlineDevices = deviceCount;
      // 成功就清掉错误页：即使已经停在错误页，后台的静默刷新也能把它自动救回来
      this.hasError = false;
    } catch (e) {
      this.failLoad('数据加载失败: ' + JSON.stringify(e), kind);
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
    console.error('[Dashboard] ' + msg);
    if (shouldShowErrorPage(kind)) {
      this.hasError = true;
      this.errorMsg = msg;
    } else if (shouldToast(kind)) {
      notifyLoadFailed(msg);
    }
  }

  /** 下拉刷新的统一入口：挂给 Refresh 的 onRefreshing */
  private onPullRefresh(): void {
    if (this.isRefreshing) {
      return;
    }
    this.isRefreshing = true;
    this.loadData('pull');
  }

  private startAutoRefresh(): void {
    if (this.refreshTimer >= 0) {
      return;
    }
    this.refreshTimer = setInterval(() => {
      // 后台静默刷新：不显示 Loading，失败也不打扰用户（数据留在屏幕上）
      this.loadData('quiet');
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
      this.recomputePeaks();
      this.drawChart();
    }

    this.prevRx = cur.rxBytes;
    this.prevTx = cur.txBytes;
    this.prevStamp = now;
  }

  /** 统计当前窗口内上下行各自的峰值（用作双 Y 轴的量程） */
  private recomputePeaks(): void {
    let rx: number = 0;
    let tx: number = 0;
    for (let i = 0; i < this.rateHistory.length; i++) {
      if (this.rateHistory[i].rx > rx) {
        rx = this.rateHistory[i].rx;
      }
      if (this.rateHistory[i].tx > tx) {
        tx = this.rateHistory[i].tx;
      }
    }
    this.rxPeak = rx;
    this.txPeak = tx;
    this.rxPeakLabel = this.formatRate(rx);
    this.txPeakLabel = this.formatRate(tx);
  }

  /**
   * 画最近 60 秒的速率曲线（双 Y 轴）。
   *
   * 上下行**各自独立缩放**：两条曲线都尽量铺满画布高度，
   * 这样即使下行比上行大几十倍，上行曲线也不会被压成一条直线。
   * 代价是两条曲线的纵向高度不能直接横向比较，所以峰值分别标注出来。
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

    // 各自量程：留 8% 顶部余量，曲线不会贴顶；下限 1 KB/s 防除零
    let rxScale: number = this.rxPeak > 1024 ? this.rxPeak * 1.08 : 1024;
    let txScale: number = this.txPeak > 1024 ? this.txPeak * 1.08 : 1024;

    const padTop: number = 3;
    const usable: number = h - padTop;
    const stepX: number = w / (RATE_HISTORY - 1);
    const x0: number = w - (n - 1) * stepX;

    // 基线
    this.canvasCtx.beginPath();
    this.canvasCtx.lineWidth = 1;
    this.canvasCtx.strokeStyle = colorString(C_DIVIDER, '#14000000');
    this.canvasCtx.moveTo(0, h - 0.5);
    this.canvasCtx.lineTo(w, h - 0.5);
    this.canvasCtx.stroke();

    // 下行：先填充曲线下方（按下行自己的刻度）
    this.canvasCtx.beginPath();
    this.canvasCtx.moveTo(x0, h);
    for (let i = 0; i < n; i++) {
      const x: number = x0 + i * stepX;
      const y: number = padTop + usable * (1 - this.rateHistory[i].rx / rxScale);
      this.canvasCtx.lineTo(x, y);
    }
    this.canvasCtx.lineTo(x0 + (n - 1) * stepX, h);
    this.canvasCtx.closePath();
    this.canvasCtx.fillStyle = colorRgba(C_SUCCESS, '#1DB954', 0.16);
    this.canvasCtx.fill();

    // 下行：描边
    this.canvasCtx.beginPath();
    this.canvasCtx.lineWidth = 2;
    this.canvasCtx.lineJoin = 'round';
    this.canvasCtx.lineCap = 'round';
    this.canvasCtx.strokeStyle = colorString(C_SUCCESS, '#1DB954');
    for (let i = 0; i < n; i++) {
      const x: number = x0 + i * stepX;
      const y: number = padTop + usable * (1 - this.rateHistory[i].rx / rxScale);
      if (i === 0) {
        this.canvasCtx.moveTo(x, y);
      } else {
        this.canvasCtx.lineTo(x, y);
      }
    }
    this.canvasCtx.stroke();

    // 上行：只描边（按上行自己的刻度）
    this.canvasCtx.beginPath();
    this.canvasCtx.lineWidth = 2;
    this.canvasCtx.lineJoin = 'round';
    this.canvasCtx.lineCap = 'round';
    this.canvasCtx.strokeStyle = colorString(C_WARNING, '#FF9500');
    for (let i = 0; i < n; i++) {
      const x: number = x0 + i * stepX;
      const y: number = padTop + usable * (1 - this.rateHistory[i].tx / txScale);
      if (i === 0) {
        this.canvasCtx.moveTo(x, y);
      } else {
        this.canvasCtx.lineTo(x, y);
      }
    }
    this.canvasCtx.stroke();
  }

  /**
   * 把 OpenWrt 的 load average 还原成真实值。
   *
   * 坑：`system.info` 返回的 load 是**定点整数**，放大了 65536 倍
   *   /proc/loadavg → 0.24 0.20 0.10
   *   system.info  → [15680, 12800, 6784]
   *   15680 / 65536 = 0.239 ✔
   * 直接用会显示成 "15680.00" 这种离谱数字。
   *
   * 用阈值判断是为了兼容返回浮点数的版本（真实 load 基本不可能超过 100）。
   */
  private normalizeLoad(raw: number): number {
    if (raw > 100) {
      return raw / 65536;
    }
    return raw;
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
