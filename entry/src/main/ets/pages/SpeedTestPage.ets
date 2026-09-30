/**
 * 「测网速」二级页面（从仪表盘的「实时网速」卡片点进来）
 *
 * 界面照着「花瓣测速」的路子做：一个大表盘 + 指针 + 中间的大数字，下面一排结果
 * （延迟 / 抖动 / 下载 / 上传），一个开始 / 停止按钮。
 *
 * 表盘刻度是**对数**的（0 / 1 / 5 / 10 / 50 / 100 / 500），不是等距 ——
 * 等距的话 0~10 Mbps 会挤成一小段，慢链路上指针几乎不动；对数刻度下
 * 1 Mbps 和 100 Mbps 都看得清（这也是花瓣那种表盘看着"匀"的原因）。
 *
 * 测速本身在 `model/SpeedTest.ets` 里（流式下载 + POST 上传），本页只负责画和交互。
 * 注意：本页**没有下拉刷新** —— 它不是数据列表，动作就是「开始测速」，
 * 统一刷新规范（common/RefreshPolicy.ets）管的是那几个数据页。
 */

import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { GlobalContext } from '../model/GlobalContext';
import { SpeedTestRunner, SpeedTestOptions, SpeedTestResult, SpeedTestHooks, SpeedPhase, DEFAULT_SPEED_BASE } from '../model/SpeedTest';
import { SpeedTestSettings } from '../model/SpeedTestSettings';
import {
  C_PRIMARY, C_SUCCESS, C_WARNING, C_TEXT_1, C_TEXT_2, C_TEXT_3,
  C_CARD, C_FILL, C_DIVIDER,
  F_SECTION, F_BODY, F_TINY, R_CARD, SP_M, SP_L, SP_XL, colorString
} from '../common/Theme';

/** 表盘量程上限（Mbps） */
const SCALE_MAX_MBPS: number = 500;
/** 表盘刻度标签（对数分布，和 scaleRatio() 对应） */
const TICK_LABELS: number[] = [0, 1, 5, 10, 50, 100, 500];

@Component
export struct SpeedTestPage {
  @State private phase: SpeedPhase = 'idle';
  @State private liveMbps: number = 0;
  @State private livePing: number = 0;
  /** 延迟阶段结束后的平均值 / 抖动值：后面的阶段继续显示，不要空着 */
  @State private pingAvg: number = 0;
  @State private jitterAvg: number = 0;
  /** 下载 / 上传阶段跑完后的平均速率：下一个阶段继续显示 */
  @State private downAvg: number = 0;
  @State private upAvg: number = 0;
  private pingSum: number = 0;
  private pingCount: number = 0;
  private pingPrev: number = 0;
  private jitterSum: number = 0;
  private jitterCount: number = 0;
  @State private result: SpeedTestResult = new SpeedTestResult();
  @State private hasResult: boolean = false;
  @State private hint: string = '';
  /** 测速服务器地址（可改，存在本机） */
  @State private baseUrl: string = DEFAULT_SPEED_BASE;

  private runner: SpeedTestRunner = new SpeedTestRunner();
  private settings: SpeedTestSettings = new SpeedTestSettings();

  /** 表盘画布 */
  private canvasSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private canvasCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.canvasSettings);

  aboutToAppear(): void {
    this.loadSettings();
  }

  /** 页面销毁（返回上一级）时把还在跑的测速掐掉，别留着后台请求 */
  aboutToDisappear(): void {
    this.runner.abort();
  }

  build() {
    Scroll() {
      Column() {
        // ===== 表盘 =====
        Column() {
          Stack() {
            Canvas(this.canvasCtx)
              .width('100%')
              .height(230)
              .onReady(() => {
                this.drawGauge();
              });

            // 圆心的大数字（用 Text 而不是画布文字，跟着深浅色走、也能自动换行）
            Column() {
              Row() {
                Text(this.centerText())
                  .fontSize(44)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(C_TEXT_1);
                Text(this.centerUnit())
                  .fontSize(F_TINY)
                  .fontColor(C_TEXT_3)
                  .margin({ left: 4, bottom: 6 });
              }
              .alignItems(VerticalAlign.Bottom);

              Text(this.caption())
                .fontSize(F_TINY)
                .fontColor(this.phase === 'idle' ? C_TEXT_3 : C_TEXT_2)
                .margin({ top: 2 });
            }
            .width('100%')
            .height(230)
            .justifyContent(FlexAlign.Center)
            .hitTestBehavior(HitTestMode.None);
          }
          .width('100%')
          .height(230);

          Button(this.running() ? '停止' : '开始测速')
            .width('100%')
            .height(46)
            .type(ButtonType.Capsule)
            .fontSize(16)
            .backgroundColor(this.running() ? C_WARNING : C_PRIMARY)
            .margin({ top: SP_M })
            .onClick(() => this.startOrStop());
        }
        .width('100%').padding(SP_XL)
        .backgroundColor(C_CARD).borderRadius(R_CARD).shadow(ShadowStyle.OUTER_DEFAULT_SM)
        .margin({ bottom: 14 });

        // ===== 结果 =====
        Row() {
          this.resultCell(0);
          this.resultCell(1);
          this.resultCell(2);
          this.resultCell(3);
        }
        .width('100%').padding({ top: SP_L, bottom: SP_L })
        .backgroundColor(C_CARD).borderRadius(R_CARD).shadow(ShadowStyle.OUTER_DEFAULT_SM)
        .margin({ bottom: 14 });

        // ===== 测速服务器 =====
        Column() {
          Row() {
            Text('测速服务器').fontSize(F_SECTION).fontWeight(FontWeight.Bold).fontColor(C_TEXT_1).layoutWeight(1);
            Button('恢复默认')
              .fontSize(F_TINY).height(28).type(ButtonType.Capsule)
              .backgroundColor(C_FILL).fontColor(C_TEXT_2)
              .onClick(() => {
                this.baseUrl = DEFAULT_SPEED_BASE;
                this.saveSettings();
              });
          }
          .width('100%');

          Text('下载走 <地址>/__down?bytes=N，上传走 POST <地址>/__up（当前默认是 Cloudflare 的公开测速接口，不需要密钥）')
            .fontSize(F_TINY).fontColor(C_TEXT_3).width('100%').lineHeight(16).margin({ top: 6 });

          TextInput({ text: this.baseUrl, placeholder: DEFAULT_SPEED_BASE })
            .width('100%').fontSize(F_BODY).margin({ top: 10 })
            .onChange((v: string) => {
              this.baseUrl = v.trim();
            });

          Button('保存地址')
            .width('100%').height(38).type(ButtonType.Capsule)
            .fontSize(F_BODY).backgroundColor(C_PRIMARY)
            .margin({ top: 10 })
            .onClick(() => this.saveSettings());
        }
        .width('100%').padding(SP_XL)
        .backgroundColor(C_CARD).borderRadius(R_CARD).shadow(ShadowStyle.OUTER_DEFAULT_SM)
        .margin({ bottom: 14 });

        // ===== 说明 =====
        Column() {
          Text('说明').fontSize(F_SECTION).fontWeight(FontWeight.Bold).fontColor(C_TEXT_1).width('100%').margin({ bottom: 6 });
          Text('· 测的是**这台设备当前链路**的实际速率：流量从手机出去，经路由器 / 代理到测速服务器，所以结果反映的是整条路，不只是宽带本身')
            .fontSize(F_TINY).fontColor(C_TEXT_3).width('100%').lineHeight(16).margin({ bottom: 4 });
          Text('· 下载 / 上传各跑最多 10 秒（每段 8 MB / 1 MB，到点收手）；延迟打 8 发小请求，抖动取相邻两发的差值平均')
            .fontSize(F_TINY).fontColor(C_TEXT_3).width('100%').lineHeight(16).margin({ bottom: 4 });
          Text('· 一次测速大约会跑掉 50~150 MB 流量（链路越快越多，到 10 秒就收手），请在 WiFi 或流量充足时使用')
            .fontSize(F_TINY).fontColor(C_TEXT_3).width('100%').lineHeight(16).margin({ bottom: 4 });
          Text('· 服务器回 403 / 404 就测不出数：多半是地址不对或被限流（Cloudflare 对超过 10 MB 的下载会直接回 403），换个地址或稍后再试')
            .fontSize(F_TINY).fontColor(C_TEXT_3).width('100%').lineHeight(16).margin({ bottom: 4 });
          Text('· 表盘刻度是对数的（0/1/5/10/50/100/500），慢链路上指针也看得清')
            .fontSize(F_TINY).fontColor(C_TEXT_3).width('100%').lineHeight(16);
        }
        .width('100%').padding(SP_XL)
        .backgroundColor(C_CARD).borderRadius(R_CARD).shadow(ShadowStyle.OUTER_DEFAULT_SM);
      }
      .width('100%').padding(SP_L)
    }
    .width('100%').height('100%')
    .edgeEffect(EdgeEffect.Spring);
  }

  // ==================== 结果格 ====================

  /**
   * 一格结果。**注意只传下标、不传值**：
   * @Builder 的值传递参数不建立状态依赖（参数变了不刷新），所以这里传序号，
   * 值全部在方法里直接读 this.xxx，测速过程中才会实时变。
   */
  @Builder
  resultCell(index: number) {
    Column() {
      Text(this.resultLabel(index)).fontSize(F_TINY).fontColor(C_TEXT_3);
      Row() {
        Text(this.resultValue(index)).fontSize(18).fontWeight(FontWeight.Bold).fontColor(C_TEXT_1);
        Text(this.resultUnit(index)).fontSize(F_TINY).fontColor(C_TEXT_3).margin({ left: 3, bottom: 2 });
      }
      .alignItems(VerticalAlign.Bottom)
      .margin({ top: 3 });
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center);
  }

  private resultLabel(index: number): string {
    if (index === 0) return '延迟';
    if (index === 1) return '抖动';
    if (index === 2) return '下载';
    return '上传';
  }

  private resultUnit(index: number): string {
    return index < 2 ? 'ms' : 'Mbps';
  }

  private resultValue(index: number): string {
    if (index === 0) {
      if (this.phase === 'ping' && this.livePing > 0) {
        return this.livePing.toFixed(0);
      }
      if (this.hasResult && this.result.pingMs > 0) {
        return this.result.pingMs.toFixed(0);
      }
      return this.pingAvg > 0 ? this.pingAvg.toFixed(0) : '--';
    }
    if (index === 1) {
      if (this.hasResult && this.result.jitterMs > 0) {
        return this.result.jitterMs.toFixed(0);
      }
      return this.jitterAvg > 0 ? this.jitterAvg.toFixed(0) : '--';
    }
    if (index === 2) {
      if (this.phase === 'download') {
        return this.formatMbps(this.liveMbps);
      }
      if (this.hasResult && this.result.downMbps > 0) {
        return this.formatMbps(this.result.downMbps);
      }
      return this.downAvg > 0 ? this.formatMbps(this.downAvg) : '--';
    }
    if (this.phase === 'upload') {
      return this.formatMbps(this.liveMbps);
    }
    if (this.hasResult && this.result.upMbps > 0) {
      return this.formatMbps(this.result.upMbps);
    }
    return this.upAvg > 0 ? this.formatMbps(this.upAvg) : '--';
  }

  // ==================== 表盘 ====================

  /** Mbps → 0~1（对数刻度） */
  private scaleRatio(mbps: number): number {
    if (mbps <= 0) {
      return 0;
    }
    const v: number = Math.min(mbps, SCALE_MAX_MBPS);
    return Math.log10(1 + v) / Math.log10(1 + SCALE_MAX_MBPS);
  }

  private dialValue(): number {
    if (this.phase === 'download' || this.phase === 'upload') {
      return this.liveMbps;
    }
    if (this.phase === 'done' && this.hasResult) {
      return this.result.downMbps;
    }
    return 0;
  }

  private drawGauge(): void {
    const w: number = this.canvasCtx.width;
    const h: number = this.canvasCtx.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    const ctx: CanvasRenderingContext2D = this.canvasCtx;
    ctx.clearRect(0, 0, w, h);

    const cx: number = w / 2;
    const cy: number = h / 2 + 8;
    const r: number = Math.min(w / 2, h / 2) - 30;
    if (r <= 20) {
      return;
    }
    const start: number = Math.PI * 0.75;   // 135°
    const sweep: number = Math.PI * 1.5;    // 270°
    const ratio: number = this.scaleRatio(this.dialValue());

    // 底弧
    ctx.beginPath();
    ctx.lineWidth = 10;
    ctx.lineCap = 'round';
    ctx.strokeStyle = colorString(C_DIVIDER, '#14000000');
    ctx.arc(cx, cy, r, start, start + sweep);
    ctx.stroke();

    // 当前值弧（上传阶段换色，一眼看出在测哪个方向）
    if (ratio > 0.002) {
      ctx.beginPath();
      ctx.lineWidth = 10;
      ctx.lineCap = 'round';
      ctx.strokeStyle = this.phase === 'upload'
        ? colorString(C_WARNING, '#FF9500')
        : colorString(C_SUCCESS, '#1DB954');
      ctx.arc(cx, cy, r, start, start + sweep * ratio);
      ctx.stroke();
    }

    // 刻度 + 标签
    ctx.lineWidth = 2;
    ctx.strokeStyle = colorString(C_TEXT_3, '#9C9C9C');
    ctx.fillStyle = colorString(C_TEXT_3, '#9C9C9C');
    ctx.font = '11px sans-serif';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    for (let i = 0; i < TICK_LABELS.length; i++) {
      const v: number = TICK_LABELS[i];
      const a: number = start + sweep * this.scaleRatio(v);
      const cos: number = Math.cos(a);
      const sin: number = Math.sin(a);
      ctx.beginPath();
      ctx.moveTo(cx + cos * (r - 9), cy + sin * (r - 9));
      ctx.lineTo(cx + cos * (r - 16), cy + sin * (r - 16));
      ctx.stroke();
      ctx.fillText(String(v), cx + cos * (r - 29), cy + sin * (r - 29));
    }

    // 指针
    const a2: number = start + sweep * ratio;
    ctx.beginPath();
    ctx.lineWidth = 3;
    ctx.lineCap = 'round';
    ctx.strokeStyle = colorString(C_PRIMARY, '#0A59F7');
    ctx.moveTo(cx, cy);
    ctx.lineTo(cx + Math.cos(a2) * (r - 24), cy + Math.sin(a2) * (r - 24));
    ctx.stroke();

    // 圆心
    ctx.beginPath();
    ctx.fillStyle = colorString(C_PRIMARY, '#0A59F7');
    ctx.arc(cx, cy, 4, 0, Math.PI * 2);
    ctx.fill();
  }

  // ==================== 状态文字 ====================

  private running(): boolean {
    return this.phase === 'ping' || this.phase === 'download' || this.phase === 'upload';
  }

  private centerText(): string {
    if (this.phase === 'ping') {
      return this.livePing > 0 ? this.livePing.toFixed(0) : '--';
    }
    if (this.phase === 'download' || this.phase === 'upload') {
      return this.formatMbps(this.liveMbps);
    }
    if (this.phase === 'done' && this.hasResult) {
      return this.formatMbps(this.result.downMbps);
    }
    return '0';
  }

  private centerUnit(): string {
    return this.phase === 'ping' ? 'ms' : 'Mbps';
  }

  private caption(): string {
    if (this.phase === 'ping') return '正在测延迟…';
    if (this.phase === 'download') return '正在测下载…';
    if (this.phase === 'upload') return '正在测上传…';
    if (this.phase === 'done') {
      if (this.hint.length > 0) return this.hint;
      return this.hasResult ? '下载结果' : '已停止';
    }
    return '点下面的按钮开始';
  }

  private formatMbps(v: number): string {
    if (v <= 0) {
      return '0.00';
    }
    if (v >= 100) {
      return v.toFixed(0);
    }
    if (v >= 10) {
      return v.toFixed(1);
    }
    return v.toFixed(2);
  }

  // ==================== 交互 ====================

  /** 点按钮：正在测就停，否则从头开始 */
  private startOrStop(): void {
    if (this.running()) {
      this.runner.abort();
      this.phase = 'done';
      this.liveMbps = 0;
      this.hint = '已停止（结果不完整）';
      this.drawGauge();
      return;
    }
    this.begin();
  }

  private async begin(): Promise<void> {
    this.hasResult = false;
    this.liveMbps = 0;
    this.livePing = 0;
    this.pingAvg = 0;
    this.jitterAvg = 0;
    this.downAvg = 0;
    this.upAvg = 0;
    this.pingSum = 0;
    this.pingCount = 0;
    this.pingPrev = 0;
    this.jitterSum = 0;
    this.jitterCount = 0;
    this.hint = '';
    this.phase = 'ping';
    this.drawGauge();

    const opt: SpeedTestOptions = new SpeedTestOptions();
    opt.baseUrl = this.baseUrl.length > 0 ? this.baseUrl : DEFAULT_SPEED_BASE;
    const hooks: SpeedTestHooks = {
      onPhase: (p: SpeedPhase) => {
        if (p === 'download') {
          // 延迟阶段到此结束：把均值 / 抖动定下来，后面的阶段继续显示，别空着
          this.pingAvg = this.pingCount > 0 ? this.pingSum / this.pingCount : 0;
          this.jitterAvg = this.jitterCount > 0 ? this.jitterSum / this.jitterCount : 0;
        }
        this.phase = p;
        this.drawGauge();
      },
      onSpeed: (mbps: number) => {
        this.liveMbps = mbps;
        this.drawGauge();
      },
      onPing: (ms: number) => {
        this.livePing = ms;
        this.pingSum = this.pingSum + ms;
        this.pingCount = this.pingCount + 1;
        if (this.pingPrev > 0) {
          // 抖动 = 相邻两发延迟差值的绝对值的平均
          this.jitterSum = this.jitterSum + Math.abs(ms - this.pingPrev);
          this.jitterCount = this.jitterCount + 1;
        }
        this.pingPrev = ms;
      },
      onPhaseDone: (p: SpeedPhase, mbps: number) => {
        if (p === 'download') {
          this.downAvg = mbps;
        } else if (p === 'upload') {
          this.upAvg = mbps;
        }
      }
    };

    const res: SpeedTestResult = await this.runner.run(opt, hooks);
    this.result = res;
    this.hasResult = res.stages > 0 || res.pingMs > 0;
    this.liveMbps = 0;
    if (res.error.length > 0) {
      this.hint = res.error;
    } else if (res.stages < 2) {
      this.hint = res.stages === 1 ? '只测完下载' : '只测完延迟';
    } else {
      this.hint = '';
    }
    this.drawGauge();
  }

  private async loadSettings(): Promise<void> {
    try {
      const ctx: common.Context | null = GlobalContext.getInstance().getContext();
      if (ctx === null) {
        return;
      }
      const url: string = await this.settings.load(ctx);
      this.baseUrl = url;
    } catch (e) {
      console.warn('[SpeedTest] 读取测速地址失败: ' + JSON.stringify(e));
    }
  }

  private async saveSettings(): Promise<void> {
    try {
      const ctx: common.Context | null = GlobalContext.getInstance().getContext();
      if (ctx === null) {
        promptAction.showToast({ message: '拿不到应用上下文，保存失败', duration: 2000 });
        return;
      }
      // 先 load 一次把 preferences 实例建起来（save 依赖它）
      await this.settings.load(ctx);
      const ok: boolean = await this.settings.save(this.baseUrl);
      promptAction.showToast({
        message: ok ? ('测速地址已保存：' + (this.baseUrl.length > 0 ? this.baseUrl : DEFAULT_SPEED_BASE)) : '保存失败',
        duration: 2000
      });
    } catch (e) {
      console.warn('[SpeedTest] 保存测速地址失败: ' + JSON.stringify(e));
      promptAction.showToast({ message: '保存异常: ' + JSON.stringify(e), duration: 2500 });
    }
  }
}