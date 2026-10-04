/** 实时网速二级页：测量路由器出口链路的延迟与瞬时吞吐。 */

import { promptAction } from '@kit.ArkUI';
import http from '@ohos.net.http';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { OpenWrtClient } from '../model/OpenWrtClient';
import type { NetDeviceStats } from '../model/OpenWrtModels';
import { GlobalContext } from '../model/GlobalContext';
import { SpeedTestHistory, SpeedTestRecord } from '../model/SpeedTestHistory';
import {
  C_PRIMARY, C_SUCCESS, C_WARNING, C_TEXT_1, C_TEXT_2, C_TEXT_3,
  C_CARD, C_FILL, F_HERO, F_SECTION, F_BODY, F_TINY,
  R_CARD, SP_S, SP_M, SP_L, SP_XL
} from '../common/Theme';

type TestPhase = 'idle' | 'latency' | 'download' | 'upload' | 'done';

@Component
export struct SpeedTestPage {
  private client!: OpenWrtClient;
  @State private phase: TestPhase = 'idle';
  @State private progress: number = 0;
  @State private latency: number = 0;
  @State private downloadRate: number = 0;
  @State private uploadRate: number = 0;
  @State private wanDevice: string = '--';
  @State private lastTest: string = '';
  @State private statusText: string = '准备测试你的网络质量';
  private cancelled: boolean = false;
  /** 测速期间持续读取路由器网卡计数，让结果在传输过程中实时变化。 */
  private liveTimer: number = -1;
  private livePrevRx: number = 0;
  private livePrevTx: number = 0;
  private livePrevStamp: number = 0;
  @State private history: SpeedTestRecord[] = [];
  private historyStore: SpeedTestHistory = new SpeedTestHistory();
  private historyReady: Promise<void> | null = null;

  aboutToAppear(): void {
    this.loadDevice();
    this.historyReady = this.loadHistory();
  }

  aboutToDisappear(): void {
    this.cancelled = true;
    this.stopLiveMeter();
  }

  build() {
    Scroll() {
      Column() {
        // 顶部视觉区
        Column() {
          Stack({ alignContent: Alignment.Center }) {
            Progress({ value: this.progress, total: 100, type: ProgressType.Ring })
              .width(166).height(166)
              .color(this.phase === 'done' ? C_SUCCESS : C_PRIMARY)
              .backgroundColor(C_FILL);
            Column() {
              if (this.phase === 'idle') {
                SymbolGlyph($r('sys.symbol.bolt'))
                  .fontSize(38).fontColor([C_PRIMARY])
                  .renderingStrategy(SymbolRenderingStrategy.SINGLE);
              } else if (this.phase === 'done') {
                Text(this.formatRate(this.downloadRate)).fontSize(F_HERO)
                  .fontWeight(FontWeight.Bold).fontColor(C_TEXT_1);
                Text('Mbps 下载').fontSize(F_TINY).fontColor(C_TEXT_2).margin({ top: 2 });
              } else {
                Text(String(Math.round(this.progress)) + '%').fontSize(F_HERO)
                  .fontWeight(FontWeight.Bold).fontColor(C_TEXT_1);
              }
            }
          }
          .width('100%').height(188);
          Text(this.statusText).fontSize(F_BODY).fontColor(C_TEXT_2).margin({ top: SP_M });
          Text(this.wanDevice === '--' ? '正在识别出口设备…' : ('出口设备  ·  ' + this.wanDevice))
            .fontSize(F_TINY).fontColor(C_TEXT_3).margin({ top: 5 });
        }
        .width('100%').padding({ top: SP_XL, bottom: SP_XL })
        .backgroundColor(C_CARD).borderRadius(R_CARD).shadow(ShadowStyle.OUTER_DEFAULT_SM)
        .margin({ bottom: 14 });

        // 三项结果
        Row() {
          this.latencyMetric();
          this.downloadMetric();
          this.uploadMetric();
        }
        .width('100%').padding({ top: SP_L, bottom: SP_L })
        .backgroundColor(C_CARD).borderRadius(R_CARD).shadow(ShadowStyle.OUTER_DEFAULT_SM)
        .margin({ bottom: 14 });

        Column() {
          Row() {
            Column() {
              Text(this.phase === 'done' ? '测试完成' : '网络质量测试')
                .fontSize(F_SECTION).fontWeight(FontWeight.Bold).fontColor(C_TEXT_1);
              Text(this.phase === 'done' ? '数据来自最近一次测量' : '测试期间请尽量保持网络空闲')
                .fontSize(F_TINY).fontColor(C_TEXT_3).margin({ top: 4 });
            }.alignItems(HorizontalAlign.Start).layoutWeight(1);
            if (this.phase === 'done') {
              SymbolGlyph($r('sys.symbol.house'))
                .fontSize(24).fontColor([C_SUCCESS])
                .renderingStrategy(SymbolRenderingStrategy.SINGLE);
            }
          }.width('100%').alignItems(VerticalAlign.Center);

          Button(this.phase === 'idle' || this.phase === 'done' ? '开始测速' : '测速进行中…')
            .width('100%').height(46).margin({ top: SP_L })
            .fontSize(F_BODY).fontWeight(FontWeight.Medium)
            .type(ButtonType.Capsule).backgroundColor(C_PRIMARY)
            .enabled(this.phase === 'idle' || this.phase === 'done')
            .onClick(() => this.startTest());

          if (this.lastTest.length > 0) {
            Text('上次测试  ·  ' + this.lastTest).fontSize(F_TINY).fontColor(C_TEXT_3)
              .width('100%').textAlign(TextAlign.Center).margin({ top: SP_M });
          }
        }
        .width('100%').padding(SP_XL).backgroundColor(C_CARD).borderRadius(R_CARD)
        .shadow(ShadowStyle.OUTER_DEFAULT_SM);

        // 近三个月历史记录
        Column() {
          Row() {
            Column() {
              Text('测速记录').fontSize(F_SECTION).fontWeight(FontWeight.Bold).fontColor(C_TEXT_1);
              Text('仅保留最近 90 天').fontSize(F_TINY).fontColor(C_TEXT_3).margin({ top: 4 });
            }.alignItems(HorizontalAlign.Start).layoutWeight(1);
            Text(String(this.history.length) + ' 次').fontSize(F_TINY).fontColor(C_TEXT_3);
          }.width('100%').alignItems(VerticalAlign.Center);

          if (this.history.length === 0) {
            Text('完成测速后，记录会显示在这里')
              .fontSize(F_TINY).fontColor(C_TEXT_3).width('100%').textAlign(TextAlign.Center)
              .margin({ top: SP_XL, bottom: SP_S });
          } else {
            ForEach(this.history, (item: SpeedTestRecord) => {
              this.historyRow(item);
            }, (item: SpeedTestRecord) => String(item.timestamp));
          }
        }
        .width('100%').padding(SP_XL).backgroundColor(C_CARD).borderRadius(R_CARD)
        .shadow(ShadowStyle.OUTER_DEFAULT_SM).margin({ top: 14 });
      }
      .width('100%').padding({ left: SP_L, right: SP_L, top: 12, bottom: 28 });
    }
    .width('100%').height('100%').edgeEffect(EdgeEffect.Spring);
  }

  /** 这些 Builder 直接读取 @State，确保异步测速结果变化时一定触发重绘。 */
  @Builder
  latencyMetric() {
    Column() {
      Text('延迟').fontSize(F_TINY).fontColor(C_TEXT_2);
      Row() {
        Text(this.latencyLabel()).fontSize(20).fontWeight(FontWeight.Bold).fontColor(C_TEXT_1);
        Text('ms').fontSize(F_TINY).fontColor(C_PRIMARY).margin({ left: 3, top: 6 });
      }.alignItems(VerticalAlign.Bottom).margin({ top: 4 });
    }.layoutWeight(1).alignItems(HorizontalAlign.Center);
  }

  @Builder
  downloadMetric() {
    Column() {
      Text('下载').fontSize(F_TINY).fontColor(C_TEXT_2);
      Row() {
        Text(this.rateLabel(this.downloadRate)).fontSize(20).fontWeight(FontWeight.Bold).fontColor(C_TEXT_1);
        Text('Mbps').fontSize(F_TINY).fontColor(C_SUCCESS).margin({ left: 3, top: 6 });
      }.alignItems(VerticalAlign.Bottom).margin({ top: 4 });
    }.layoutWeight(1).alignItems(HorizontalAlign.Center);
  }

  @Builder
  uploadMetric() {
    Column() {
      Text('上传').fontSize(F_TINY).fontColor(C_TEXT_2);
      Row() {
        Text(this.rateLabel(this.uploadRate)).fontSize(20).fontWeight(FontWeight.Bold).fontColor(C_TEXT_1);
        Text('Mbps').fontSize(F_TINY).fontColor(C_WARNING).margin({ left: 3, top: 6 });
      }.alignItems(VerticalAlign.Bottom).margin({ top: 4 });
    }.layoutWeight(1).alignItems(HorizontalAlign.Center);
  }

  @Builder
  historyRow(item: SpeedTestRecord) {
    Column() {
      Row() {
        Text(this.formatRecordDate(item.timestamp)).fontSize(F_TINY).fontColor(C_TEXT_2).layoutWeight(1);
        Text(String(item.latency) + ' ms').fontSize(F_TINY).fontColor(C_PRIMARY);
      }.width('100%').margin({ bottom: 7 });
      Row() {
        this.historyValue('↓', this.formatRate(item.download), C_SUCCESS);
        this.historyValue('↑', this.formatRate(item.upload), C_WARNING);
      }.width('100%');
    }
    .width('100%').padding({ top: SP_M, bottom: SP_M })
    .border({ width: { bottom: 1 }, color: C_FILL })
  }

  @Builder
  historyValue(label: string, value: string, color: ResourceColor) {
    Row() {
      Text(label).fontSize(F_BODY).fontWeight(FontWeight.Bold).fontColor(color);
      Text(value + ' Mbps').fontSize(F_TINY).fontColor(C_TEXT_1).margin({ left: 5 });
    }.layoutWeight(1);
  }

  private async loadDevice(): Promise<void> {
    try {
      this.wanDevice = (await this.client.findUplinkDevice()) || '--';
    } catch (e) {
      console.warn('[SpeedTest] 找出口设备失败: ' + JSON.stringify(e));
    }
  }

  private async loadHistory(): Promise<void> {
    const context: common.Context | null = GlobalContext.getInstance().getContext();
    if (context === null) return;
    await this.historyStore.init(context);
    this.history = this.historyStore.snapshot();
  }

  private async startTest(): Promise<void> {
    if (this.phase !== 'idle' && this.phase !== 'done') return;
    this.cancelled = false;
    if (this.wanDevice === '--') {
      await this.loadDevice();
    }
    if (this.wanDevice === '--') {
      this.statusText = '暂时无法识别出口设备';
      promptAction.showToast({ message: '无法识别出口设备', duration: 1800 });
      return;
    }
    if (this.historyReady !== null) await this.historyReady;
    this.phase = 'latency'; this.progress = 5; this.statusText = '正在测试连接延迟…';
    this.latency = 0; this.downloadRate = 0; this.uploadRate = 0;
    this.startLiveMeter();
    try {
      let total: number = 0;
      let count: number = 0;
      for (let i = 0; i < 3; i++) {
        if (this.cancelled) return;
        const begin: number = Date.now();
        const result = await this.client.getSystemBoard();
        if (result.success) {
          const currentLatency: number = Math.max(1, Date.now() - begin);
          total += currentLatency;
          count++;
          // 每次请求结束立即显示一次，而不是等三次全部结束。
          this.latency = Math.round(total / count);
        }
        this.progress = 8 + i * 8;
      }
      this.latency = count > 0 ? Math.max(1, Math.round(total / count)) : 0;

      this.phase = 'download'; this.progress = 32; this.statusText = '正在测量下载速度…';
      const down = await this.measureDownload();
      if (this.cancelled) return;
      this.downloadRate = down;
      this.phase = 'upload'; this.progress = 68; this.statusText = '正在测量上传速度…';
      const up = await this.measureUpload();
      if (this.cancelled) return;
      this.uploadRate = up;
      this.progress = 100; this.phase = 'done'; this.statusText = '测速完成，网络状态良好';
      this.lastTest = this.timeLabel();
      const record: SpeedTestRecord = new SpeedTestRecord();
      record.timestamp = Date.now();
      record.latency = this.latency;
      record.download = this.downloadRate;
      record.upload = this.uploadRate;
      await this.historyStore.add(record);
      this.history = this.historyStore.snapshot();
    } catch (e) {
      this.phase = 'idle'; this.progress = 0; this.statusText = '测速失败，请检查路由器连接';
      promptAction.showToast({ message: '测速失败，请稍后重试', duration: 1800 });
      console.error('[SpeedTest] ' + JSON.stringify(e));
    } finally {
      this.stopLiveMeter();
    }
  }

  /** 读取出口网卡计数，实时显示测速请求经过路由器时的上下行吞吐。 */
  private startLiveMeter(): void {
    this.stopLiveMeter();
    this.livePrevRx = 0;
    this.livePrevTx = 0;
    this.livePrevStamp = 0;
    this.liveTimer = setInterval(() => {
      this.sampleLiveMeter();
    }, 400);
  }

  private stopLiveMeter(): void {
    if (this.liveTimer >= 0) {
      clearInterval(this.liveTimer);
      this.liveTimer = -1;
    }
  }

  private async sampleLiveMeter(): Promise<void> {
    if (this.cancelled || this.wanDevice === '--' || this.phase === 'idle' || this.phase === 'done') {
      return;
    }
    const stats: NetDeviceStats[] = await this.client.getAllDeviceStats();
    let current: NetDeviceStats | null = null;
    for (let i = 0; i < stats.length; i++) {
      if (stats[i].device === this.wanDevice) {
        current = stats[i];
        break;
      }
    }
    if (current === null) return;
    const now: number = Date.now();
    if (this.livePrevStamp > 0) {
      const seconds: number = (now - this.livePrevStamp) / 1000;
      if (seconds > 0) {
        const rx: number = Math.max(0, current.rxBytes - this.livePrevRx) * 8 / seconds / 1000000;
        const tx: number = Math.max(0, current.txBytes - this.livePrevTx) * 8 / seconds / 1000000;
        if (this.phase === 'download') this.downloadRate = rx;
        if (this.phase === 'upload') this.uploadRate = tx;
      }
    }
    this.livePrevRx = current.rxBytes;
    this.livePrevTx = current.txBytes;
    this.livePrevStamp = now;
  }

  /**
   * 实际下载 5 MB 测试数据，按请求耗时计算吞吐。
   * Cloudflare Speed 是公开的测速端点；原生 HTTP 请求不受网页 CORS 限制。
   */
  private async measureDownload(): Promise<number> {
    const bytes: number = 5 * 1024 * 1024;
    const elapsed: number = await this.transfer('https://speed.cloudflare.com/__down?bytes=' + String(bytes), false, '');
    return bytes * 8 / elapsed / 1000;
  }

  /** 实际向测速端点上传 2 MB 数据，按请求耗时计算吞吐。 */
  private async measureUpload(): Promise<number> {
    const bytes: number = 2 * 1024 * 1024;
    let payload: string = '';
    for (let i = 0; i < bytes; i++) payload += '0';
    const elapsed: number = await this.transfer('https://speed.cloudflare.com/__up', true, payload);
    return bytes * 8 / elapsed / 1000;
  }

  /** 完成一次真实 HTTP 传输，返回毫秒耗时。 */
  private transfer(url: string, upload: boolean, payload: string): Promise<number> {
    return new Promise<number>((resolve, reject) => {
      const request: http.HttpRequest = http.createHttp();
      const start: number = Date.now();
      const headers: Record<string, string> = { 'Accept': 'application/json' };
      if (upload) headers['Content-Type'] = 'application/octet-stream';
      const options: http.HttpRequestOptions = {
        method: upload ? http.RequestMethod.POST : http.RequestMethod.GET,
        header: headers,
        extraData: payload,
        connectTimeout: 10000,
        readTimeout: 30000,
        usingCache: false
      };
      request.request(url, options, (err: BusinessError | null, response: http.HttpResponse) => {
        request.destroy();
        if (err) {
          reject(err);
          return;
        }
        if (response.responseCode < 200 || response.responseCode >= 300) {
          reject(new Error('HTTP ' + String(response.responseCode)));
          return;
        }
        resolve(Math.max(1, Date.now() - start));
      });
    });
  }

  private formatRate(value: number): string { return value >= 100 ? value.toFixed(0) : value.toFixed(1); }
  private rateLabel(value: number): string {
    if (this.phase === 'idle' && value <= 0) return '--';
    if (this.phase !== 'idle' && this.phase !== 'done' && value <= 0) return '…';
    return this.formatRate(value);
  }
  private latencyLabel(): string {
    if (this.phase === 'idle' && this.latency <= 0) return '--';
    return this.latency > 0 ? String(this.latency) : '…';
  }
  private timeLabel(): string {
    const d: Date = new Date();
    return String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
  }

  private formatRecordDate(timestamp: number): string {
    const d: Date = new Date(timestamp);
    return String(d.getMonth() + 1) + '月' + String(d.getDate()) + '日  ' +
      String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
  }
}
