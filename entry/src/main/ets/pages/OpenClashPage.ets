/**
 * OpenClash 页面
 *
 * OpenClash 没有自己的 ubus 对象，数据分三层取：
 *   1. `rc.list`                      → 进程是否在运行
 *   2. `uci.get openclash`            → 外部控制端口（cn_port）+ 面板密钥（dashboard_password）
 *   3. Clash 外部控制 API（带 Bearer 鉴权）→ 版本 / 端口 / 模式 / 节点 / 策略组 / 流量 / 连接数
 *
 * 数据来源与已实测的能力：
 *   GET  /version      → 内核版本
 *   GET  /configs      → mode、log-level、allow-lan、ipv6、各端口
 *   GET  /proxies      → 全部节点 + 策略组（含当前选中项、成员、延迟）
 *   GET  /connections  → 活动连接数、累计上下行、内核内存
 *   PUT  /proxies/{组} → 切换 Selector 策略组的节点（HTTP 204 表示成功）
 *
 * ⚠️ 切「运行模式」不能走 API：mihomo 的 /configs 只认 PATCH 做局部更新，
 *    而 HarmonyOS 的 http.RequestMethod 没有 PATCH（实测 PUT 返回 204 但不生效）。
 *    所以模式切换走 uci set + 重启服务。
 */

import { promptAction } from '@kit.ArkUI';
import { OpenWrtClient } from '../model/OpenWrtClient';
import type { OpenClashSettings, ClashGroup } from '../model/OpenWrtModels';
import {
  C_PRIMARY, C_SUCCESS, C_WARNING, C_DANGER, C_TEXT_1, C_TEXT_2, C_TEXT_3,
  C_CARD, C_DIVIDER, C_FILL,
  F_SECTION, F_BODY, F_CAPTION, F_TINY,
  R_CARD, R_CHIP, SP_S, SP_M, SP_L, SP_XL
} from '../common/Theme';

const COLOR_CARD_BG: ResourceColor = C_CARD;

/** 运行模式选项：值 → 中文标签 */
const MODE_VALUES: string[] = ['rule', 'global', 'direct'];
const MODE_LABELS: string[] = ['Rule 规则模式', 'Global 全局模式', 'Direct 直连模式'];

@Component
export struct OpenClashPage {
  private client!: OpenWrtClient;
  /** Clash 外部控制 API 地址，按 路由器IP + uci 里的 cn_port 拼出 */
  private clashApiBase: string = '';
  /** 外部控制密钥，来自 uci 的 dashboard_password，不带一律 401 */
  private clashSecret: string = '';

  @State private isLoading: boolean = true;
  @State private hasError: boolean = false;
  @State private errorMsg: string = '';
  @State private isRefreshing: boolean = false;
  @State private busy: boolean = false;
  /** 每次加载自增，强制 ForEach 重建（@Builder 值传递参数不会刷新） */
  @State private dataVersion: number = 0;

  // ---- OpenClash 自身 ----
  @State private isRunning: boolean = false;
  @State private isEnabled: boolean = false;

  // ---- Clash 控制 API ----
  /** 控制 API 是否可用（密钥不对时整块降级） */
  @State private apiAvailable: boolean = false;
  @State private version: string = '--';
  @State private mode: string = 'rule';
  @State private logLevel: string = '--';
  @State private ports: string = '--';
  @State private allowLan: boolean = false;
  @State private ipv6: boolean = false;

  // ---- 代理概览 ----
  @State private proxyCount: number = 0;
  @State private typeSummary: string = '--';
  @State private activeConnections: number = 0;
  @State private downloadTotal: number = 0;
  @State private uploadTotal: number = 0;
  @State private clashMemory: number = 0;

  // ---- 策略组 ----
  @State private groups: ClashGroup[] = [];
  /** 切换节点时的临时提示 */
  @State private switchingHint: string = '';

  aboutToAppear(): void {
    this.loadAll();
  }

  build() {
    Stack() {
      // 下拉刷新用 Refresh 组件。
      // 绝不要用 Scroll 的 onReachStart —— 初始就在顶部会立刻触发，
      // 数据更新又引起重渲染，于是反复触发，形成无限刷新循环。
      Refresh({ refreshing: this.isRefreshing }) {
        Scroll() {
          Column() {
            this.statusCard();
            this.overviewCard();
            this.groupsCard();
            this.actionCard();
            this.helpCard();
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
        this.refreshAll();
      });

      if (this.isLoading) {
        LoadingProgress().width(32).height(32);
      }
      if (this.hasError) {
        Column() {
          Text('⚠️').fontSize(40);
          Text(this.errorMsg).fontSize(F_BODY).margin({ top: SP_M });
          Button('重试').type(ButtonType.Capsule).margin({ top: SP_L })
            .onClick(() => this.loadAll());
        }
      }
    }
    .width('100%')
    .height('100%')
  }

  // ==================== 卡片 ====================

  /** 状态卡片：进程状态 + 版本 + 端口/模式等配置 */
  @Builder
  statusCard() {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.bolt'))
          .fontSize(22)
          .fontColor([this.isRunning ? C_PRIMARY : C_TEXT_3])
          .renderingStrategy(SymbolRenderingStrategy.SINGLE);

        Column() {
          Text('OpenClash')
            .fontSize(F_SECTION).fontWeight(FontWeight.Bold).fontColor(C_TEXT_1);
          Text(this.apiAvailable ? ('内核 ' + this.version) : '内核状态未知')
            .fontSize(F_TINY).fontColor(C_TEXT_3).margin({ top: 2 });
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: SP_M });

        Row() {
          Circle()
            .width(7).height(7)
            .fill(this.isRunning ? C_SUCCESS : C_TEXT_3)
            .margin({ right: 5 });
          Text(this.isRunning ? '运行中' : '已停止')
            .fontSize(F_TINY)
            .fontColor(this.isRunning ? C_SUCCESS : C_TEXT_3);
        }
        .padding({ left: SP_S, right: SP_S, top: 3, bottom: 3 })
        .backgroundColor(this.isRunning ? '#1A1DB954' : C_FILL)
        .borderRadius(R_CHIP);
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: SP_M });

      Divider().color(C_DIVIDER).margin({ bottom: SP_M });

      if (this.apiAvailable) {
        // 运行模式可切换（改完需要重启 OpenClash 才生效）
        Row() {
          Text('运行模式').fontSize(F_CAPTION).fontColor(C_TEXT_2).layoutWeight(1);
          Select(this.modeOptions())
            .selected(this.modeIndex())
            .value(this.modeLabel())
            .font({ size: F_CAPTION })
            .enabled(!this.busy)
            .onSelect((index: number, value?: string) => {
              this.confirmModeChange(index);
            });
        }
        .width('100%').alignItems(VerticalAlign.Center).margin({ bottom: 6 });

        this.infoRow('监听端口', this.ports);
        this.infoRow('日志级别', this.logLevel);
        this.infoRow('允许局域网', this.allowLan ? '是' : '否');
        this.infoRow('IPv6 转发', this.ipv6 ? '已开启' : '已关闭');
      } else if (this.isRunning) {
        Text('读不到内核配置。请确认 uci 里的 dashboard_password 与运行时配置一致，' +
             '并且「外部控制」端口已放开。')
          .fontSize(F_TINY).fontColor(C_WARNING).lineHeight(16).width('100%');
      } else {
        Text('OpenClash 当前未运行，开启后这里会显示内核信息')
          .fontSize(F_CAPTION).fontColor(C_TEXT_3).width('100%');
      }
    }
    .width('100%').padding(SP_XL).backgroundColor(COLOR_CARD_BG)
    .borderRadius(R_CARD).shadow(ShadowStyle.OUTER_DEFAULT_SM)
    .margin({ bottom: 14 })
  }

  /** 代理概览：节点数 / 连接数 / 累计流量 / 内核内存 */
  @Builder
  overviewCard() {
    Column() {
      Text('代理概览')
        .fontSize(F_SECTION).fontWeight(FontWeight.Bold).fontColor(C_TEXT_1)
        .width('100%').margin({ bottom: SP_M });

      if (this.apiAvailable) {
        Row() {
          this.statBlock('节点总数', String(this.proxyCount), C_TEXT_1);
          this.statBlock('活动连接', String(this.activeConnections), C_PRIMARY);
        }
        .width('100%').margin({ bottom: SP_M });

        Row() {
          this.statBlock('累计下载', this.formatBytes(this.downloadTotal), C_SUCCESS);
          this.statBlock('累计上传', this.formatBytes(this.uploadTotal), C_WARNING);
        }
        .width('100%').margin({ bottom: SP_M });

        this.infoRow('节点类型', this.typeSummary);
        this.infoRow('内核内存', this.formatBytes(this.clashMemory));
      } else {
        Text('需要 Clash 控制 API 可用才能读取')
          .fontSize(F_CAPTION).fontColor(C_TEXT_3).width('100%');
      }
    }
    .width('100%').padding(SP_XL).backgroundColor(COLOR_CARD_BG)
    .borderRadius(R_CARD).shadow(ShadowStyle.OUTER_DEFAULT_SM)
    .margin({ bottom: 14 })
  }

  /** 策略组：显示当前节点，Selector 可直接切换 */
  @Builder
  groupsCard() {
    Column() {
      Row() {
        Text('节点组')
          .fontSize(F_SECTION).fontWeight(FontWeight.Bold).fontColor(C_TEXT_1)
          .layoutWeight(1);
        if (this.switchingHint.length > 0) {
          Text(this.switchingHint).fontSize(F_TINY).fontColor(C_PRIMARY);
        }
      }
      .width('100%').alignItems(VerticalAlign.Center).margin({ bottom: SP_M });

      if (this.groups.length === 0) {
        Text(this.apiAvailable ? '没有找到策略组' : '需要 Clash 控制 API 可用才能读取')
          .fontSize(F_CAPTION).fontColor(C_TEXT_3).width('100%');
      }

      ForEach(this.groups, (g: ClashGroup) => {
        this.groupBlock(g);
      }, (g: ClashGroup) => g.name + '#' + this.dataVersion);
    }
    .width('100%').padding(SP_XL).backgroundColor(COLOR_CARD_BG)
    .borderRadius(R_CARD).shadow(ShadowStyle.OUTER_DEFAULT_SM)
    .margin({ bottom: 14 })
  }

  @Builder
  groupBlock(g: ClashGroup) {
    Column() {
      Row() {
        Text(g.name)
          .fontSize(F_BODY).fontWeight(FontWeight.Medium).fontColor(C_TEXT_1)
          .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(g.type + ' · ' + g.members.length + ' 个')
          .fontSize(F_TINY).fontColor(C_TEXT_3);
      }
      .width('100%').alignItems(VerticalAlign.Center).margin({ bottom: 6 });

      if (g.switchable) {
        // Selector 类型可以手动切节点，用下拉框（选项里带延迟）
        Select(this.groupOptions(g))
          .selected(this.groupIndex(g))
          .value(this.currentLabel(g))
          .font({ size: F_CAPTION })
          .enabled(!this.busy)
          .onSelect((index: number, value?: string) => {
            this.doSwitchNode(g, index);
          });
      } else {
        // URLTest / Fallback 是自动选择的，只展示
        Row() {
          Text('自动选中').fontSize(F_TINY).fontColor(C_TEXT_2);
          Text(this.currentLabel(g))
            .fontSize(F_CAPTION).fontColor(C_TEXT_1).layoutWeight(1)
            .textAlign(TextAlign.End).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
        }
        .width('100%').alignItems(VerticalAlign.Center);
      }
    }
    .width('100%').padding(SP_M)
    .backgroundColor(C_FILL).borderRadius(14)
    .margin({ bottom: SP_S })
  }

  /** 操作卡片：重启 */
  @Builder
  actionCard() {
    Column() {
      if (this.client.isLoggedIn() && this.isRunning) {
        Button('重启 OpenClash')
          .width('100%').height(46)
          .type(ButtonType.Capsule)
          .fontSize(F_BODY)
          .fontColor(Color.White)
          .backgroundColor(C_WARNING)
          .enabled(!this.busy)
          .onClick(() => this.confirmRestart());
      }
      if (this.apiAvailable) {
        Text('切换节点立即生效；切换运行模式需要重启 OpenClash')
          .fontSize(F_TINY).fontColor(C_TEXT_3)
          .width('100%').textAlign(TextAlign.Center)
          .margin({ top: SP_S });
      }
    }
    .width('100%')
    .margin({ bottom: 14 })
  }

  @Builder
  helpCard() {
    Column() {
      Text('说明').fontSize(F_SECTION).fontWeight(FontWeight.Bold).fontColor(C_TEXT_1)
        .width('100%').margin({ bottom: SP_S });
      Text('· 进程状态来自 ubus rc.list')
        .fontSize(F_TINY).fontColor(C_TEXT_3).margin({ bottom: 4 });
      Text('· 端口与面板密钥来自 uci 的 openclash 配置')
        .fontSize(F_TINY).fontColor(C_TEXT_3).margin({ bottom: 4 });
      Text('· 其余数据来自 Clash 外部控制 API（带 Bearer 密钥）')
        .fontSize(F_TINY).fontColor(C_TEXT_3).margin({ bottom: 4 });
      Text('· 节点延迟是内核上次测速的结果，可能不是最新的')
        .fontSize(F_TINY).fontColor(C_TEXT_3).margin({ bottom: 4 });
      Text('· 完整面板：浏览器打开路由器 LuCI → 服务 → OpenClash')
        .fontSize(F_TINY).fontColor(C_TEXT_3);
    }
    .width('100%').padding(SP_XL).backgroundColor(COLOR_CARD_BG)
    .borderRadius(R_CARD).shadow(ShadowStyle.OUTER_DEFAULT_SM)
  }

  // ==================== 通用小部件 ====================

  /** 详情行：直接读 this，保证状态变化能刷新 */
  @Builder
  infoRow(label: string, value: string) {
    Row() {
      Text(label).fontSize(F_CAPTION).fontColor(C_TEXT_2);
      Text(value)
        .fontSize(F_CAPTION).fontWeight(FontWeight.Medium).fontColor(C_TEXT_1)
        .layoutWeight(1).textAlign(TextAlign.End)
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis });
    }
    .width('100%').alignItems(VerticalAlign.Top).margin({ bottom: 6 })
  }

  /** 概览里的大数字块 */
  @Builder
  statBlock(label: string, value: string, color: ResourceColor) {
    Column() {
      Text(value)
        .fontSize(20).fontWeight(FontWeight.Bold).fontColor(color)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
      Text(label).fontSize(F_TINY).fontColor(C_TEXT_3).margin({ top: 2 });
    }
    .layoutWeight(1).alignItems(HorizontalAlign.Start)
  }

  // ==================== 数据加载 ====================

  private async loadAll(): Promise<void> {
    if (!this.client.isLoggedIn()) {
      this.hasError = true;
      this.errorMsg = '未登录';
      this.isLoading = false;
      return;
    }

    this.isLoading = true;
    this.hasError = false;

    try {
      // 1) 进程状态：用 rc.list（直接给 running / enabled）
      const state = await this.client.getServiceState('openclash');
      this.isRunning = state !== null && state.running === true;
      this.isEnabled = state !== null && state.enabled === true;

      // 2) uci：拿外部控制端口和面板密钥
      const settings: OpenClashSettings | null = await this.client.getOpenClashSettings();
      if (settings) {
        this.clashApiBase = `http://${this.client.getHost()}:${settings.apiPort}`;
        this.clashSecret = settings.apiSecret;
        this.isEnabled = settings.enabled;
      }

      // 3) Clash 控制 API
      this.apiAvailable = false;
      if (this.isRunning && this.clashApiBase.length > 0) {
        const ov = await this.client.getClashOverview(this.clashApiBase, this.clashSecret);
        if (ov !== null) {
          this.apiAvailable = true;
          this.version = ov.version;
          this.mode = ov.mode;
          this.logLevel = ov.logLevel;
          this.ports = ov.ports;
          this.allowLan = ov.allowLan;
          this.ipv6 = ov.ipv6;
          this.proxyCount = ov.proxyCount;
          this.typeSummary = ov.typeSummary;
          this.activeConnections = ov.activeConnections;
          this.downloadTotal = ov.downloadTotal;
          this.uploadTotal = ov.uploadTotal;
          this.clashMemory = ov.memory;
          this.groups = ov.groups;
        }
      }
      this.dataVersion = this.dataVersion + 1;
    } catch (e) {
      this.hasError = true;
      this.errorMsg = '数据加载失败: ' + JSON.stringify(e);
    } finally {
      this.isLoading = false;
      this.isRefreshing = false;
    }
  }

  /** 下拉刷新入口（带并发保护） */
  private refreshAll(): void {
    if (this.isRefreshing) return;
    this.isRefreshing = true;
    this.loadAll();
  }

  // ==================== 操作 ====================

  /** 切换 Selector 策略组的节点 */
  private async doSwitchNode(g: ClashGroup, index: number): Promise<void> {
    if (index < 0 || index >= g.members.length) {
      return;
    }
    const node: string = g.members[index];

    this.busy = true;
    this.switchingHint = '切换中...';
    try {
      const ok: boolean = await this.client.switchClashNode(
        this.clashApiBase, this.clashSecret, g.name, node
      );
      if (ok) {
        promptAction.showToast({ message: '已切换到 ' + node, duration: 2000 });
        await this.sleep(600);
        await this.loadAll();
        this.switchingHint = '';
      } else {
        this.switchingHint = '';
        promptAction.showToast({ message: '切换失败', duration: 2000 });
      }
    } catch (e) {
      this.switchingHint = '';
      promptAction.showToast({ message: '切换异常: ' + JSON.stringify(e), duration: 2500 });
    } finally {
      this.busy = false;
      this.switchingHint = '';
    }
  }

  /** 切换运行模式：需要重启 OpenClash 才生效 */
  private confirmModeChange(index: number): void {
    if (index < 0 || index >= MODE_VALUES.length) {
      return;
    }
    const target: string = MODE_VALUES[index];
    if (target === this.mode) {
      return;
    }

    promptAction.showDialog({
      title: '切换运行模式',
      message: '将模式改为「' + MODE_LABELS[index] + '」。\n' +
               '注意：需要重启 OpenClash 才生效，期间代理会中断几秒。',
      buttons: [
        { text: '取消', color: '#666666' },
        { text: '切换', color: '#0A59F7' }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index === 1) {
        this.applyMode(target);
      }
    });
  }

  private async applyMode(mode: string): Promise<void> {
    this.busy = true;
    promptAction.showToast({ message: '正在切换模式...', duration: 2000 });
    try {
      const saved: boolean = await this.client.setOpenClashMode(mode);
      if (!saved) {
        promptAction.showToast({ message: '写入配置失败', duration: 2000 });
        return;
      }
      const restarted = await this.client.restartService('openclash');
      if (!restarted.success) {
        promptAction.showToast({ message: '重启失败: ' + (restarted.error || ''), duration: 2500 });
        return;
      }
      // OpenClash 重启要几秒，等一下再回来读状态
      await this.sleep(8000);
      await this.loadAll();
      promptAction.showToast({ message: '模式已切换', duration: 2000 });
    } catch (e) {
      promptAction.showToast({ message: '切换异常: ' + JSON.stringify(e), duration: 2500 });
    } finally {
      this.busy = false;
    }
  }

  private confirmRestart(): void {
    promptAction.showDialog({
      title: '确认重启',
      message: '确定要重启 OpenClash 吗？代理会中断几秒钟。',
      buttons: [
        { text: '取消', color: '#666666' },
        { text: '确定', color: '#FF9500' }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index === 1) {
        this.doRestart();
      }
    });
  }

  private async doRestart(): Promise<void> {
    this.busy = true;
    promptAction.showToast({ message: '正在重启 OpenClash...', duration: 2000 });
    try {
      // 服务名就叫 openclash，没有叫 clash 的服务
      const result = await this.client.restartService('openclash');
      if (result.success) {
        await this.sleep(8000);
        await this.loadAll();
        promptAction.showToast({ message: '已重启', duration: 2000 });
      } else {
        promptAction.showToast({ message: '重启失败: ' + (result.error || '未知错误'), duration: 2500 });
      }
    } catch (e) {
      promptAction.showToast({ message: '重启异常: ' + JSON.stringify(e), duration: 2500 });
    } finally {
      this.busy = false;
    }
  }

  // ==================== 工具 ====================

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => { resolve(); }, ms);
    });
  }

  private modeOptions(): SelectOption[] {
    const opts: SelectOption[] = [];
    for (let i = 0; i < MODE_LABELS.length; i++) {
      const o: SelectOption = { value: MODE_LABELS[i] };
      opts.push(o);
    }
    return opts;
  }

  private modeIndex(): number {
    for (let i = 0; i < MODE_VALUES.length; i++) {
      if (MODE_VALUES[i] === this.mode) {
        return i;
      }
    }
    return 0;
  }

  private modeLabel(): string {
    const idx: number = this.modeIndex();
    return MODE_LABELS[idx];
  }

  /** 策略组的成员下拉选项，标签里带上延迟 */
  private groupOptions(g: ClashGroup): SelectOption[] {
    const opts: SelectOption[] = [];
    for (let i = 0; i < g.members.length; i++) {
      const delay: number = i < g.memberDelays.length ? g.memberDelays[i] : -1;
      const label: string = delay > 0
        ? (g.members[i] + '  ·  ' + delay + ' ms')
        : g.members[i];
      const o: SelectOption = { value: label };
      opts.push(o);
    }
    return opts;
  }

  /** 当前选中项在成员数组里的下标 */
  private groupIndex(g: ClashGroup): number {
    for (let i = 0; i < g.members.length; i++) {
      if (g.members[i] === g.now) {
        return i;
      }
    }
    return -1;
  }

  /** 当前节点的显示文本（带延迟） */
  private currentLabel(g: ClashGroup): string {
    const idx: number = this.groupIndex(g);
    if (idx >= 0 && idx < g.memberDelays.length && g.memberDelays[idx] > 0) {
      return g.now + '  ·  ' + g.memberDelays[idx] + ' ms';
    }
    return g.now;
  }

  private formatBytes(bytes: number): string {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1048576) return (bytes / 1024).toFixed(1) + ' KB';
    if (bytes < 1073741824) return (bytes / 1048576).toFixed(1) + ' MB';
    if (bytes < 1099511627776) return (bytes / 1073741824).toFixed(2) + ' GB';
    return (bytes / 1099511627776).toFixed(2) + ' TB';
  }
}
