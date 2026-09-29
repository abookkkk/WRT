/**
 * 主页（Tab 导航容器）
 *
 * 视觉特性（HarmonyOS 6）：
 *   - 沉浸式：expandSafeArea 让内容延伸到状态栏 / 导航栏区域
 *   - 渐变背景：浅蓝 → 灰白过渡
 *   - 毛玻璃胶囊标签栏：barBackgroundBlurStyle + 半透明底
 *   - 系统符号图标：SymbolGlyph($r('sys.symbol.xxx'))，随选中态变色
 *
 * 注意：$r() 的资源名必须是**字面量**，不能用模板字符串拼，
 * 所以下面每个 Tab 的图标都老老实实写一个 if 分支。
 */

import { promptAction } from '@kit.ArkUI';
import { OpenWrtClient } from '../model/OpenWrtClient';
import { SessionStore } from '../model/SessionStore';
import { GlobalContext } from '../model/GlobalContext';
import { DashboardPage } from './DashboardPage';
import { NetworkPage } from './NetworkPage';
import { WifiPage } from './WifiPage';
import { DevicesPage } from './DevicesPage';
import { OpenClashPage } from './OpenClashPage';
import {
  C_PRIMARY, C_BG_TOP, C_BG_MID, C_BG_BOTTOM, C_TEXT_1, C_TEXT_3, C_DANGER,
  F_HERO, F_CAPTION, F_TINY, ICON_L, SP_L, SP_S
} from '../common/Theme';

@Component
export struct HomePage {
  private client!: OpenWrtClient;
  private onLogout!: () => void;

  @State private currentIndex: number = 0;

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // ===== 渐变背景 =====
      // 只让**背景**延伸到状态栏/导航栏后面（沉浸式），
      // 内容不能一起扩展，否则第一张卡片会被顶到状态栏里被裁掉。
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [[C_BG_TOP, 0.0], [C_BG_MID, 0.35], [C_BG_BOTTOM, 1.0]]
        })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]);

      Column() {
        // ===== 顶部标题栏 =====
        Row() {
          Column() {
            Text('OpenWrt 管理')
              .fontSize(F_HERO)
              .fontWeight(FontWeight.Bold)
              .fontColor(C_TEXT_1);
            Text('AX3000T · Filogic 820')
              .fontSize(F_CAPTION)
              .fontColor(C_TEXT_3)
              .margin({ top: 2 });
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1);

          Button('退出')
            .fontSize(F_CAPTION)
            .fontColor(C_DANGER)
            .backgroundColor('#1AF53F3F')
            .height(32)
            .type(ButtonType.Capsule)
            .onClick(() => this.handleLogout());
        }
        .width('100%')
        .padding({ left: SP_L, right: SP_L, top: SP_S, bottom: SP_S })
        .alignItems(VerticalAlign.Center);

        // ===== Tab 内容 =====
        Tabs({ barPosition: BarPosition.End }) {
          TabContent() {
            DashboardPage({ client: this.client })
          }
          .tabBar(this.tabItem(0, '仪表盘'))

          TabContent() {
            NetworkPage({ client: this.client })
          }
          .tabBar(this.tabItem(1, '网络'))

          TabContent() {
            WifiPage({ client: this.client })
          }
          .tabBar(this.tabItem(2, '无线'))

          TabContent() {
            DevicesPage({ client: this.client })
          }
          .tabBar(this.tabItem(3, '设备'))

          TabContent() {
            OpenClashPage({ client: this.client })
          }
          .tabBar(this.tabItem(4, 'Clash'))
        }
        .layoutWeight(1)
        .width('100%')
        .barHeight(62)
        .barMode(BarMode.Fixed)
        .barBackgroundColor('#D9FFFFFF')
        .barBackgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
        .animationDuration(280)
        .onChange((index: number) => {
          this.currentIndex = index;
        });
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 自定义 Tab 项：系统符号图标 + 文字，选中态用主色。
   * 直接读 this.currentIndex，所以切换时能正常刷新。
   */
  @Builder
  tabItem(index: number, title: string) {
    Column() {
      if (index === 0) {
        SymbolGlyph($r('sys.symbol.house'))
          .fontSize(ICON_L)
          .fontColor([this.currentIndex === index ? C_PRIMARY : C_TEXT_3])
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      } else if (index === 1) {
        SymbolGlyph($r('sys.symbol.rectangle_stack'))
          .fontSize(ICON_L)
          .fontColor([this.currentIndex === index ? C_PRIMARY : C_TEXT_3])
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      } else if (index === 2) {
        SymbolGlyph($r('sys.symbol.wifi'))
          .fontSize(ICON_L)
          .fontColor([this.currentIndex === index ? C_PRIMARY : C_TEXT_3])
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      } else if (index === 3) {
        SymbolGlyph($r('sys.symbol.person'))
          .fontSize(ICON_L)
          .fontColor([this.currentIndex === index ? C_PRIMARY : C_TEXT_3])
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      } else {
        SymbolGlyph($r('sys.symbol.bolt'))
          .fontSize(ICON_L)
          .fontColor([this.currentIndex === index ? C_PRIMARY : C_TEXT_3])
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      }

      Text(title)
        .fontSize(F_TINY)
        .fontColor(this.currentIndex === index ? C_PRIMARY : C_TEXT_3)
        .fontWeight(this.currentIndex === index ? FontWeight.Medium : FontWeight.Normal)
        .margin({ top: 2 });
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center);
  }

  private async handleLogout(): Promise<void> {
    const result = await promptAction.showDialog({
      title: '确认登出',
      message: '确定要退出登录吗？',
      buttons: [
        { text: '取消', color: '#666666' },
        { text: '登出', color: '#F53F3F' }
      ]
    });

    if (result.index === 1) {
      try {
        const ctx = GlobalContext.getInstance().getContext();
        if (ctx) {
          const store = new SessionStore();
          await store.init(ctx);
          await store.clear();
        }
      } catch (e) {
        console.error('[HomePage] 清除 Session 失败: ' + JSON.stringify(e));
      }

      this.client.destroy();
      this.onLogout();
    }
  }
}
