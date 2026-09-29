/**
 * OpenClash 状态页面
 * 
 * 由于 OpenClash 没有 ubus 对象，采用两种方式获取状态：
 * 1. ubus service.list 检查 openclash 进程是否在运行
 * 2. 直接请求 Clash 面板 API（默认 192.168.2.1:9090）获取详细信息
 */

import http from '@ohos.net.http';
import { promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { OpenWrtClient } from '../model/OpenWrtClient';
import type { OpenClashSettings } from '../model/OpenWrtModels';

const COLOR_CARD_BG: ResourceColor = '#F2FFFFFF';
const COLOR_SECONDARY: ResourceColor = '#666666';
const COLOR_TERTIARY: ResourceColor = '#999999';

@Component
export struct OpenClashPage {
  private client!: OpenWrtClient;
  /** Clash 外部控制 API 地址，按 路由器IP + uci 里的 cn_port 动态拼出 */
  private clashApiBase: string = '';
  /** Clash 外部控制密钥，来自 uci 的 dashboard_password，不带一律 401 */
  private clashSecret: string = '';

  @State private isLoading: boolean = true;
  @State private hasError: boolean = false;
  @State private errorMsg: string = '';
  @State private isRunning: boolean = false;
  @State private isEnabled: boolean = false;
  @State private version: string = '--';
  @State private mode: string = '--';
  @State private clashPort: string = '--';
  @State private allowLan: boolean = false;

  aboutToAppear(): void {
    this.loadAll();
  }

  build() {
    Stack() {
      Scroll() {
        Column() {
          // 状态卡片
          Column() {
            Row() {
              Circle()
                .width(16).height(16)
                .fill(this.isRunning ? Color.Green : Color.Gray)
                .margin({ right: 8 });

              Text('OpenClash')
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .layoutWeight(1);

              Text(this.isRunning ? '运行中' : '已停止')
                .fontSize(12)
                .fontColor(Color.White)
                .padding({ left: 10, right: 10, top: 3, bottom: 3 })
                .backgroundColor(this.isRunning ? Color.Green : Color.Gray)
                .borderRadius(10);
            }
            .width('100%')
            .margin({ bottom: 12 });

            if (this.isRunning) {
              this.clashInfoRows();
            }
          }
          .width('100%')
          .padding(16)
          .backgroundColor(COLOR_CARD_BG)
          .borderRadius(20)
          .shadow(ShadowStyle.OUTER_DEFAULT_SM)
          .margin({ bottom: 12 });

          // 重启按钮
          if (this.client.isLoggedIn() && this.isRunning) {
            Button('重启 OpenClash')
              .width('100%').height(44)
              .type(ButtonType.Capsule)
              .backgroundColor(Color.Orange)
              .margin({ top: 8 })
              .onClick(() => this.confirmRestart());
          }

          // 说明卡片
          Column() {
            Text('说明').fontSize(16).fontWeight(FontWeight.Bold)
              .width('100%').margin({ bottom: 8 });
            Text('OpenClash 没有 ubus 对象，本页通过以下方式取数据：')
              .fontSize(13).fontColor(COLOR_SECONDARY).lineHeight(20);
            Text('1. ubus rc.list —— 判断 openclash 进程是否在运行')
              .fontSize(13).fontColor(COLOR_TERTIARY).margin({ top: 8 });
            Text('2. uci 读 openclash 配置 —— 拿外部控制端口和面板密钥')
              .fontSize(13).fontColor(COLOR_TERTIARY).margin({ top: 4 });
            Text('3. Clash 外部控制 API（带 Bearer 密钥）—— 取版本和运行模式')
              .fontSize(13).fontColor(COLOR_TERTIARY).margin({ top: 4 });
            Text('如需查看完整面板，请在浏览器中打开 http://192.168.2.1/cgi-bin/luci/admin/services/openclash')
              .fontSize(13).fontColor(COLOR_TERTIARY).margin({ top: 8 }).lineHeight(20);
          }
          .width('100%').padding(16)
          .backgroundColor(COLOR_CARD_BG).borderRadius(20).shadow(ShadowStyle.OUTER_DEFAULT_SM);
        }
        .width('100%').padding(16)
      }
      .width('100%').height('100%')
      .edgeEffect(EdgeEffect.Spring)
      .onReachStart(() => this.loadAll());

      if (this.isLoading) {
        LoadingProgress().width(32).height(32);
      }
      if (this.hasError) {
        Column() {
          Text('⚠️').fontSize(40);
          Text(this.errorMsg).fontSize(14).margin({ top: 12 });
          Button('重试').type(ButtonType.Capsule).margin({ top: 16 })
            .onClick(() => this.loadAll());
        }
      }
    }
    .width('100%').height('100%')
  }

  /**
   * OpenClash 详情行。
   *
   * 重要：这里必须**直接读 this.version / this.mode 这些 @State**，
   * 不能把值当参数传给 @Builder —— ArkUI 的 @Builder 值传递参数
   * 不会建立状态依赖，参数变了 UI 也不会刷新（页面上会一直停在旧值）。
   * DevicesPage 里把设备卡片全部内联，就是为了绕开同一个坑。
   */
  @Builder
  clashInfoRows() {
    Column() {
      Row() {
        Text('版本').fontSize(14).fontColor(COLOR_SECONDARY);
        Text(this.version).fontSize(14).fontWeight(FontWeight.Medium)
          .layoutWeight(1).textAlign(TextAlign.End).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      .width('100%').justifyContent(FlexAlign.SpaceBetween).margin({ bottom: 6 })

      Row() {
        Text('运行模式').fontSize(14).fontColor(COLOR_SECONDARY);
        Text(this.mode).fontSize(14).fontWeight(FontWeight.Medium)
          .layoutWeight(1).textAlign(TextAlign.End).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      .width('100%').justifyContent(FlexAlign.SpaceBetween).margin({ bottom: 6 })

      Row() {
        Text('HTTP 端口').fontSize(14).fontColor(COLOR_SECONDARY);
        Text(this.clashPort).fontSize(14).fontWeight(FontWeight.Medium)
          .layoutWeight(1).textAlign(TextAlign.End).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      .width('100%').justifyContent(FlexAlign.SpaceBetween).margin({ bottom: 6 })

      Row() {
        Text('允许局域网').fontSize(14).fontColor(COLOR_SECONDARY);
        Text(this.allowLan ? '是' : '否').fontSize(14).fontWeight(FontWeight.Medium)
          .layoutWeight(1).textAlign(TextAlign.End).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      .width('100%').justifyContent(FlexAlign.SpaceBetween).margin({ bottom: 6 })
    }
    .width('100%')
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
      // 1) 服务状态用 rc.list（直接返回 running / enabled）。
      //    原来用 service.list 的顶层 running 永远取不到值 ——
      //    真实结构嵌在 data["openclash"].instances["openclash"].running 里。
      const state = await this.client.getServiceState('openclash');
      this.isRunning = state !== null && state.running === true;
      this.isEnabled = state !== null && state.enabled === true;

      // 2) uci 配置：拿外部控制端口和面板密钥
      const settings: OpenClashSettings | null = await this.client.getOpenClashSettings();
      if (settings) {
        this.clashApiBase = `http://${this.client.getHost()}:${settings.apiPort}`;
        this.clashSecret = settings.apiSecret;
        this.isEnabled = settings.enabled;
      }

      // 3) Clash 外部控制 API（必须带 Bearer 密钥，否则 401）
      if (this.isRunning && this.clashApiBase.length > 0) {
        await this.fetchClashInfo();
      }
    } catch (e) {
      this.hasError = true;
      this.errorMsg = '数据加载失败: ' + JSON.stringify(e);
    } finally {
      this.isLoading = false;
    }
  }

  private async fetchClashInfo(): Promise<void> {
    try {
      const versionStr: string = await this.httpGet(`${this.clashApiBase}/version`);
      const versionObj: Record<string, Object> = JSON.parse(versionStr) as Record<string, Object>;
      this.version = String(versionObj['version'] || '未知');

      const configStr: string = await this.httpGet(`${this.clashApiBase}/configs`);
      const configObj: Record<string, Object> = JSON.parse(configStr) as Record<string, Object>;

      // 解析 mode
      const rawMode: Object | undefined = configObj['mode'];
      const modeStr: string = rawMode ? String(rawMode) : '';
      if (modeStr === 'rule') {
        this.mode = 'Rule 规则模式';
      } else if (modeStr === 'global') {
        this.mode = 'Global 全局模式';
      } else if (modeStr === 'direct') {
        this.mode = 'Direct 直连模式';
      } else {
        this.mode = modeStr || '未知';
      }

      // 解析端口（mixed-port 优先）
      const mixedPort: Object | undefined = configObj['mixed-port'];
      const port: Object | undefined = configObj['port'];
      if (mixedPort) {
        this.clashPort = String(mixedPort);
      } else if (port) {
        this.clashPort = String(port);
      } else {
        this.clashPort = '--';
      }

      // 解析 allow-lan
      const allowLanVal: Object | undefined = configObj['allow-lan'];
      this.allowLan = allowLanVal === true;

    } catch (e) {
      console.warn('[OpenClashPage] Clash API 请求失败: ' + JSON.stringify(e));
      this.version = '(API 不可用)';
      this.mode = '(API 不可用)';
    }
  }

  private httpGet(url: string): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      const httpClient = http.createHttp();
      // Clash 的外部控制 API 必须鉴权，否则一律返回 401 未经授权
      const headers: Record<string, string> = {};
      if (this.clashSecret.length > 0) {
        headers['Authorization'] = `Bearer ${this.clashSecret}`;
      }
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 5000,
        readTimeout: 5000
      };
      httpClient.request(url, options, (err: BusinessError | null, data: http.HttpResponse) => {
        httpClient.destroy();
        if (err) {
          console.warn(`[OpenClashPage] httpGet 出错 url=${url} code=${err.code} msg=${err.message}`);
          reject(err);
        } else {
          resolve(data.result as string);
        }
      });
    });
  }

  private confirmRestart(): void {
    promptAction.showDialog({
      title: '确认重启',
      message: '确定要重启 OpenClash 吗？',
      buttons: [
        { text: '取消', color: '#666666' },
        { text: '确定', color: '#FF6600' }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index === 1) {
        this.doRestart();
      }
    });
  }

  private async doRestart(): Promise<void> {
    promptAction.showToast({ message: '正在重启 OpenClash...', duration: 2000 });

    try {
      // 服务名就叫 openclash，没有名为 clash 的服务
      const result = await this.client.restartService('openclash');

      if (result.success) {
        promptAction.showToast({ message: '重启指令已发送', duration: 2000 });
        setTimeout(() => this.loadAll(), 3000);
      } else {
        promptAction.showToast({ message: '重启失败: ' + (result.error || '未知错误'), duration: 3000 });
      }
    } catch (e) {
      promptAction.showToast({ message: '重启异常: ' + JSON.stringify(e), duration: 3000 });
    }
  }
}
