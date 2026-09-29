/**
 * 登录页面
 * 
 * 输入路由器地址、用户名、密码登录 OpenWrt。
 * 登录成功后保存 Session 到本地，下次自动恢复。
 */

import { promptAction } from '@kit.ArkUI';
import { OpenWrtClient } from '../model/OpenWrtClient';
import { SessionStore } from '../model/SessionStore';
import { GlobalContext } from '../model/GlobalContext';

/** 颜色常量 */
const COLOR_PRIMARY: ResourceColor = '#0078D4';
const COLOR_SECONDARY: ResourceColor = '#666666';
const COLOR_CARD_BG: ResourceColor = '#FFFFFF';
const COLOR_PAGE_BG: ResourceColor = '#F5F5F5';

@Component
export struct LoginPage {
  @State private host: string = '192.168.2.1';
  @State private port: string = '80';
  @State private useHttps: boolean = false;
  @State private username: string = 'root';
  @State private password: string = '';
  @State private isLoggingIn: boolean = false;
  @State private showPassword: boolean = false;

  private onLoginSuccess?: (client: OpenWrtClient) => void;

  aboutToAppear(): void {
    this.restoreLastConfig();
  }

  private async restoreLastConfig(): Promise<void> {
    try {
      const ctx = GlobalContext.getInstance().getContext();
      if (!ctx) return;

      const store = new SessionStore();
      await store.init(ctx);
      const saved = await store.load();
      if (saved) {
        this.host = saved.host;
        this.port = String(saved.port);
        this.useHttps = saved.useHttps;
        this.username = saved.username;
      }
    } catch (e) {
      console.error('[LoginPage] 恢复配置失败: ' + JSON.stringify(e));
    }
  }

  build() {
    Column() {
      // ===== 顶部区域 =====
      Column() {
        Text('🔧')
          .fontSize(48);
        Text('OpenWrt 管理')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .margin({ top: 8 });
      }
      .width('100%')
      .height('25%')
      .justifyContent(FlexAlign.Center)
      .backgroundColor(COLOR_PRIMARY)

      // ===== 登录表单卡片 =====
      Column() {
        Text('连接到路由器后台')
          .fontSize(14)
          .fontColor(COLOR_SECONDARY)
          .margin({ top: 8, bottom: 24 });

        // 路由器地址 + 端口
        Row() {
          TextInput({ placeholder: '路由器 IP 地址', text: this.host })
            .layoutWeight(1)
            .onChange((v: string) => { this.host = v.trim(); });

          TextInput({ placeholder: '端口', text: this.port })
            .width(72)
            .type(InputType.Number)
            .onChange((v: string) => { this.port = v.trim(); });
        }
        .margin({ bottom: 12 });

        // HTTPS 开关
        Row() {
          Text('使用 HTTPS').fontSize(14);
          Toggle({ type: ToggleType.Switch, isOn: this.useHttps })
            .onChange((v: boolean) => { this.useHttps = v; });
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .margin({ bottom: 12 });

        // 用户名
        TextInput({ placeholder: '用户名', text: this.username })
          .onChange((v: string) => { this.username = v.trim(); })
          .margin({ bottom: 12 });

        // 密码
        TextInput({ placeholder: '密码', text: this.password })
          .type(this.showPassword ? InputType.Normal : InputType.Password)
          .onChange((v: string) => { this.password = v; })
          .margin({ bottom: 24 });

        // 登录按钮
        Button('登录')
          .width('100%')
          .height(44)
          .type(ButtonType.Capsule)
          .stateEffect(true)
          .enabled(!this.isLoggingIn)
          .onClick(() => this.handleLogin());

        // 加载指示
        if (this.isLoggingIn) {
          LoadingProgress()
            .width(32).height(32)
            .margin({ top: 16 });
        }
      }
      .width('90%')
      .padding(24)
      .backgroundColor(COLOR_CARD_BG)
      .borderRadius(16)
      .shadow({ radius: 12, color: '#1A000000', offsetY: 4 })
      .position({ y: '18%' })
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(COLOR_PAGE_BG)
  }

  private async handleLogin(): Promise<void> {
    if (!this.host) {
      this.showToast('请输入路由器地址');
      return;
    }
    if (!this.username) {
      this.showToast('请输入用户名');
      return;
    }
    if (!this.password) {
      this.showToast('请输入密码');
      return;
    }

    this.isLoggingIn = true;

    try {
      const portNum: number = parseInt(this.port) || 80;
      const client: OpenWrtClient = new OpenWrtClient(this.host, portNum, this.useHttps);
      const ok: boolean = await client.login(this.username, this.password);

      if (ok) {
        await this.saveSession(client);
        this.showToast('登录成功');
        this.onLoginSuccess?.(client);
      } else {
        this.showToast('登录失败，请检查用户名和密码');
        client.destroy();
      }
    } catch (e) {
      this.showToast('连接失败：' + JSON.stringify(e));
    } finally {
      this.isLoggingIn = false;
    }
  }

  private async saveSession(client: OpenWrtClient): Promise<void> {
    try {
      const ctx = GlobalContext.getInstance().getContext();
      if (!ctx) return;

      const store = new SessionStore();
      await store.init(ctx);
      await store.save({
        host: this.host,
        port: parseInt(this.port) || 80,
        useHttps: this.useHttps,
        username: this.username,
        sessionId: client.getSessionId()
      });
    } catch (e) {
      console.error('[LoginPage] 保存 Session 失败: ' + JSON.stringify(e));
    }
  }

  private showToast(msg: string): void {
    promptAction.showToast({ message: msg, duration: 2000 });
  }
}
