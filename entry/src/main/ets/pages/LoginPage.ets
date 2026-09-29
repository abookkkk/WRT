/**
 * 登录页面
 *
 * 视觉：整屏渐变背景 + 玻璃拟态表单卡片 + 系统符号图标（SymbolGlyph）
 * 逻辑：输入路由器地址 / 用户名 / 密码，登录成功后把 Session 存到本地，下次自动恢复。
 */

import { promptAction } from '@kit.ArkUI';
import { OpenWrtClient } from '../model/OpenWrtClient';
import { SessionStore } from '../model/SessionStore';
import { GlobalContext } from '../model/GlobalContext';
import {
  C_PRIMARY, C_ACCENT, C_TEXT_1, C_TEXT_2, C_TEXT_3, C_TEXT_ON_PRIMARY,
  C_CARD, C_FILL, C_DANGER,
  F_HERO, F_BODY, F_CAPTION, F_TINY,
  R_CARD, R_INPUT, R_BTN, SP_S, SP_M, SP_L, SP_XL, ICON_M
} from '../common/Theme';

/** 字段行统一样式用的高度 */
const FIELD_HEIGHT: number = 50;

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
    Stack({ alignContent: Alignment.TopStart }) {
      // ===== 整屏渐变背景（沉浸式，延伸到状态栏后面）=====
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 170,
          colors: [
            [C_PRIMARY, 0.00],
            ['#3D7BFF', 0.28],
            ['#F0F4FF', 0.62],
            ['#F5F6F8', 1.00]
          ]
        })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]);

      Scroll() {
        Column() {
          // ===== 头部 Logo 区 =====
          Column() {
            Stack() {
              Circle().width(88).height(88).fill('#33FFFFFF');
              SymbolGlyph($r('sys.symbol.wifi'))
                .fontSize(46)
                .fontColor([Color.White])
                .renderingStrategy(SymbolRenderingStrategy.SINGLE);
            }
            .width(88)
            .height(88);

            Text('OpenWrt 管理')
              .fontSize(F_HERO)
              .fontWeight(FontWeight.Bold)
              .fontColor(C_TEXT_ON_PRIMARY)
              .margin({ top: SP_M });

            Text('路由器控制台')
              .fontSize(F_CAPTION)
              .fontColor('#CCFFFFFF')
              .margin({ top: 2 });
          }
          .width('100%')
          .padding({ top: 36, bottom: 24 })
          .alignItems(HorizontalAlign.Center);

          // ===== 表单卡片（玻璃拟态）=====
          Column() {
            Text('连接到路由器后台')
              .fontSize(F_BODY)
              .fontColor(C_TEXT_2)
              .width('100%')
              .margin({ bottom: SP_XL });

            // --- 地址 + 端口 ---
            Row() {
              SymbolGlyph($r('sys.symbol.house'))
                .fontSize(18)
                .fontColor([C_TEXT_3])
                .margin({ right: SP_S });

              TextInput({ placeholder: '路由器 IP 地址', text: this.host })
                .layoutWeight(1)
                .backgroundColor(Color.Transparent)
                .padding(0)
                .fontSize(F_BODY)
                .placeholderFont({ size: F_BODY })
                .onChange((v: string) => { this.host = v.trim(); });

              TextInput({ placeholder: '端口', text: this.port })
                .width(64)
                .type(InputType.Number)
                .backgroundColor(Color.Transparent)
                .padding(0)
                .fontSize(F_BODY)
                .textAlign(TextAlign.End)
                .onChange((v: string) => { this.port = v.trim(); });
            }
            .width('100%')
            .height(FIELD_HEIGHT)
            .padding({ left: SP_M, right: SP_M })
            .backgroundColor(C_FILL)
            .borderRadius(R_INPUT)
            .margin({ bottom: SP_M });

            // --- HTTPS 开关 ---
            Row() {
              SymbolGlyph($r('sys.symbol.lock'))
                .fontSize(18)
                .fontColor([C_TEXT_3])
                .margin({ right: SP_S });
              Text('使用 HTTPS').fontSize(F_BODY).fontColor(C_TEXT_1).layoutWeight(1);
              Toggle({ type: ToggleType.Switch, isOn: this.useHttps })
                .onChange((v: boolean) => { this.useHttps = v; });
            }
            .width('100%')
            .height(FIELD_HEIGHT)
            .padding({ left: SP_M, right: SP_S })
            .backgroundColor(C_FILL)
            .borderRadius(R_INPUT)
            .margin({ bottom: SP_M });

            // --- 用户名 ---
            Row() {
              SymbolGlyph($r('sys.symbol.person'))
                .fontSize(18)
                .fontColor([C_TEXT_3])
                .margin({ right: SP_S });
              TextInput({ placeholder: '用户名', text: this.username })
                .layoutWeight(1)
                .backgroundColor(Color.Transparent)
                .padding(0)
                .fontSize(F_BODY)
                .placeholderFont({ size: F_BODY })
                .onChange((v: string) => { this.username = v.trim(); });
            }
            .width('100%')
            .height(FIELD_HEIGHT)
            .padding({ left: SP_M, right: SP_M })
            .backgroundColor(C_FILL)
            .borderRadius(R_INPUT)
            .margin({ bottom: SP_M });

            // --- 密码 ---
            Row() {
              SymbolGlyph($r('sys.symbol.lock_fill'))
                .fontSize(18)
                .fontColor([C_TEXT_3])
                .margin({ right: SP_S });
              TextInput({ placeholder: '密码', text: this.password })
                .layoutWeight(1)
                .type(this.showPassword ? InputType.Normal : InputType.Password)
                // ⚠️ 必须关掉 TextInput 自带的密码可见性图标：
                // InputType.Password 默认会在输入框末尾画一个自己的眼睛图标（颜色跟随文字色），
                // 而下面又加了一个灰色的 SymbolGlyph 眼睛，实测会并排显示成两个图标（截图里是两个闭眼）。
                // 关掉之后只剩自定义图标，密码显隐完全由 this.showPassword 驱动，状态不会不同步。
                .showPasswordIcon(false)
                .backgroundColor(Color.Transparent)
                .padding(0)
                .fontSize(F_BODY)
                .placeholderFont({ size: F_BODY })
                // 键盘会盖住下面的登录按钮，所以把键盘的「前往」键直接接到登录上
                .enterKeyType(EnterKeyType.Go)
                .onSubmit(() => this.handleLogin())
                .onChange((v: string) => { this.password = v; });

              // $r 的资源名必须是字面量，所以用 if/else 而不是三元表达式
              if (this.showPassword) {
                SymbolGlyph($r('sys.symbol.eye'))
                  .fontSize(ICON_M)
                  .fontColor([C_TEXT_3])
                  .onClick(() => { this.showPassword = false; });
              } else {
                SymbolGlyph($r('sys.symbol.eye_slash'))
                  .fontSize(ICON_M)
                  .fontColor([C_TEXT_3])
                  .onClick(() => { this.showPassword = true; });
              }
            }
            .width('100%')
            .height(FIELD_HEIGHT)
            .padding({ left: SP_M, right: SP_M })
            .backgroundColor(C_FILL)
            .borderRadius(R_INPUT)
            .margin({ bottom: SP_XL });

            // --- 登录按钮 ---
            Button(this.isLoggingIn ? '登录中...' : '登 录')
              .width('100%')
              .height(50)
              .type(ButtonType.Capsule)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(C_TEXT_ON_PRIMARY)
              .linearGradient({
                angle: 90,
                colors: [[C_PRIMARY, 0.0], [C_ACCENT, 1.0]]
              })
              .shadow(ShadowStyle.OUTER_FLOATING_SM)
              .enabled(!this.isLoggingIn)
              .onClick(() => this.handleLogin());

            if (this.isLoggingIn) {
              LoadingProgress()
                .width(28)
                .height(28)
                .color(C_PRIMARY)
                .margin({ top: SP_L });
            }
          }
          .width('100%')
          .padding(SP_XL)
          .backgroundColor(C_CARD)
          .borderRadius(R_CARD)
          .shadow(ShadowStyle.OUTER_FLOATING_MD)
          .alignItems(HorizontalAlign.Center);

          Text('数据通过路由器自带的 ubus 接口获取，不经过第三方服务器')
            .fontSize(F_TINY)
            // 这行在卡片下方，背景已经是渐变尾部的近白色（#F5F6F8）。
            // 原来用 #99FFFFFF（60% 白），实测对比只有 2~8 级，等于看不见；
            // 白色系颜色只适用于顶部的深蓝区域。
            .fontColor(C_TEXT_3)
            .textAlign(TextAlign.Center)
            .width('100%')
            .margin({ top: SP_XL, bottom: SP_XL });
        }
        .width('100%')
        .padding({ left: SP_XL, right: SP_XL })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring);
    }
    .width('100%')
    .height('100%');
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
