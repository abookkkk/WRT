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
import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { OpenWrtClient } from '../model/OpenWrtClient';
import { SessionStore } from '../model/SessionStore';
import { GlobalContext } from '../model/GlobalContext';
import { ThemeSettings, AppearanceMode } from '../model/ThemeSettings';
import { DashboardPage } from './DashboardPage';
import { NetworkPage } from './NetworkPage';
import { WifiPage } from './WifiPage';
import { DevicesPage } from './DevicesPage';

import { OpenClashPage } from './OpenClashPage';
import {
  C_PRIMARY, C_BG_TOP, C_BG_MID, C_BG_BOTTOM, C_TEXT_1, C_TEXT_2, C_TEXT_3, C_DANGER,
  C_FILL, C_BAR, C_DANGER_CHIP,
  F_HERO, F_SECTION, F_CAPTION, F_TINY, ICON_L, ICON_M, SP_XS, SP_S, SP_M, SP_L, colorString
} from '../common/Theme';

@Component
export struct HomePage {
  private client!: OpenWrtClient;
  private onLogout!: () => void;

  @State private currentIndex: number = 0;
  /**
   * 底部安全区（手势条 / 导航栏）高度，单位 vp，用来给标签栏下面补一条同色底。
   *
   * 背景：页面内容默认只铺到安全区边界，标签栏也就止步于手势条上方，
   * 屏幕最底部会露出一条没被填充的页面底色（实测 1316×2832 截图里是 96px，
   * 颜色 245,246,248 正是渐变尾色），看起来像界面没做完。
   * 拿窗口避让区的真实高度来铺这一条，比写死数值更稳（平板 / 三键导航都不一样）。
   */
  @State private bottomInset: number = 0;

  /** 当前外观模式（跟随系统 / 浅色 / 深色）：按钮文案与图标都用它 */
  @State private appearance: AppearanceMode = 'system';

  /** 二级页面栈：目前只有「在线设备」（从仪表盘的卡片进入，不再占一个底部 Tab） */
  private pathStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    this.measureBottomInset();
    // 启动时 EntryAbility 已经应用过外观，这里读一次只为让按钮显示正确的状态
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      this.appearance = ThemeSettings.load(ctx);
    } catch (e) {
      console.warn('[HomePage] 读取外观设置失败: ' + JSON.stringify(e));
    }
  }

  /** 外观按钮文案 */
  private appearanceLabel(): string {
    if (this.appearance === 'light') {
      return '浅色';
    }
    if (this.appearance === 'dark') {
      return '深色';
    }
    return '跟随系统';
  }

  /**
   * 点一下循环切换：跟随系统 → 深色 → 浅色 → 跟随系统。
   * 默认是跟随系统，所以点一下就先落进夜间模式（需求里最常用的那个方向）。
   */
  private cycleAppearance(): void {
    let next: AppearanceMode = 'dark';
    if (this.appearance === 'system') {
      next = 'dark';
    } else if (this.appearance === 'dark') {
      next = 'light';
    } else {
      next = 'system';
    }
    this.appearance = next;
    const ctx = getContext(this) as common.UIAbilityContext;
    ThemeSettings.save(ctx, next);
    ThemeSettings.apply(ctx, next);
    promptAction.showToast({ message: '外观已切换为：' + this.appearanceLabel(), duration: 1500 });
  }

  /** 读窗口底部避让区（取系统区与手势条区的较大值），换算成 vp */
  private async measureBottomInset(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const win: window.Window = await window.getLastWindow(ctx);
      const systemArea: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const indicatorArea: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const px: number = Math.max(systemArea.bottomRect.height, indicatorArea.bottomRect.height);
      this.bottomInset = px2vp(px);
      console.info(`[HomePage] 底部安全区 ${px}px = ${this.bottomInset}vp`);
    } catch (e) {
      // 拿不到就退回 0：标签栏少铺一条，功能不受影响
      console.warn('[HomePage] 读取底部安全区失败: ' + JSON.stringify(e));
    }
  }

  build() {
    // 二级页面（在线设备）用 Navigation 的页面栈：推入的 NavDestination 会盖住整页（含底部标签栏），
    // 自带返回手势与系统返回键处理，比"再塞一个 Tab"更像正常的二级页面。
    Navigation(this.pathStack) {
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

            // ===== 外观切换按钮：跟随系统 / 深色 / 浅色，点一下循环 =====
            Button() {
              Row() {
                if (this.appearance === 'light') {
                  SymbolGlyph($r('sys.symbol.sun_max'))
                    .fontSize(ICON_M)
                    .fontColor([C_TEXT_2])
                    .renderingStrategy(SymbolRenderingStrategy.SINGLE);
                } else if (this.appearance === 'dark') {
                  SymbolGlyph($r('sys.symbol.moon_fill'))
                    .fontSize(ICON_M)
                    .fontColor([C_TEXT_2])
                    .renderingStrategy(SymbolRenderingStrategy.SINGLE);
                } else {
                  SymbolGlyph($r('sys.symbol.auto_sun_max_fill'))
                    .fontSize(ICON_M)
                    .fontColor([C_TEXT_2])
                    .renderingStrategy(SymbolRenderingStrategy.SINGLE);
                }
                Text(this.appearanceLabel())
                  .fontSize(F_CAPTION)
                  .fontColor(C_TEXT_2)
                  .margin({ left: SP_XS });
              }
              .alignItems(VerticalAlign.Center);
            }
            .height(32)
            .type(ButtonType.Capsule)
            .backgroundColor(C_FILL)
            .padding({ left: SP_M, right: SP_M })
            .margin({ right: SP_S })
            .onClick(() => this.cycleAppearance());

            Button('退出')
              .fontSize(F_CAPTION)
              .fontColor(C_DANGER)
              .backgroundColor(C_DANGER_CHIP)
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
              DashboardPage({ client: this.client, onOpenDevices: () => this.openDevices() })
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
              OpenClashPage({ client: this.client })
            }
            .tabBar(this.tabItem(3, 'Clash'))
          }
          .layoutWeight(1)
          .width('100%')
          .barHeight(62)
          .barMode(BarMode.Fixed)
          .barBackgroundColor(C_BAR)
          .barBackgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
          .animationDuration(280)
          .onChange((index: number) => {
            this.currentIndex = index;
          });
        }
        .width('100%')
        .height('100%')

        // ===== 标签栏下方的安全区补白 =====
        // 标签栏只会铺到安全区边界，屏幕最底部那条手势条区域露出的是页面渐变底色，
        // 看着像界面没做完。这里补一条与标签栏同色、同样模糊的色带，把标签栏"接"到屏幕物理底部。
        //
        // 为什么用绝对定位（下面这些都在模拟器上逐像素比对过）：
        //   · 给 Tabs 加 barHeight + expandSafeArea → 无效：标签栏始终锚在安全区边界，
        //     expandSafeArea 只让 Tabs 盒子变大，标签栏反而向上多吃 28vp 内容区，底下灰带照旧；
        //   · 让内容列 expandSafeArea 再把补白条当子元素 → 同样无效：expandSafeArea 只让
        //     **叶子节点**的绘制区域外扩（渐变背景能吃到底部就是这个原因），容器里的子元素不会被挪进安全区。
        //   · 现在这样：补白条脱离布局流，绝对定位到内容框下沿（y='100%' 即安全区底边）再往下铺 bottomInset，
        //     正好落在手势条区域，且不会挤压 Tabs、不影响标签栏位置。
        Column()
          .width('100%')
          .height(this.bottomInset)
          .backgroundColor(C_BAR)
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
          .position({ x: 0, y: '100%' })
          .hitTestBehavior(HitTestMode.None)
      }
      .width('100%')
      .height('100%')
    }
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .navDestination(this.pageMap)
    .width('100%')
    .height('100%')
  }

  // ==================== 二级页面 ====================

  /** 打开二级页面：在线设备 */
  private openDevices(): void {
    this.pathStack.pushPathByName('devices', null);
  }


  /**
   * 页面栈分发。Navigation 的 navDestination 只回调页面名，
   * 所以在这里按 name 选页面（目前只有一个）。
   */
  @Builder
  pageMap(name: string) {
    if (name === 'devices') {
      this.devicesDestination();
    }
  }

  /** 二级页面通用背景：标签栏被盖住了，得自己铺一层渐变（含状态栏 / 手势条区域） */
  @Builder
  navBackground() {
    Column()
      .width('100%')
      .height('100%')
      .linearGradient({
        angle: 180,
        colors: [[C_BG_TOP, 0.0], [C_BG_MID, 0.35], [C_BG_BOTTOM, 1.0]]
      })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]);
  }

  /** 二级页面通用标题栏：返回 + 标题（两个二级页共用，样式一致） */
  @Builder
  navTitleBar(title: string) {
    Row() {
      Button() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(ICON_M)
          .fontColor([C_TEXT_1])
          .renderingStrategy(SymbolRenderingStrategy.SINGLE);
      }
      .height(32)
      .type(ButtonType.Capsule)
      .backgroundColor(C_FILL)
      .padding({ left: SP_M, right: SP_M })
      .onClick(() => this.pathStack.pop());

      Text(title)
        .fontSize(F_SECTION)
        .fontWeight(FontWeight.Bold)
        .fontColor(C_TEXT_1)
        .layoutWeight(1)
        .margin({ left: SP_M });
    }
    .width('100%')
    .padding({ left: SP_L, right: SP_L, top: SP_S, bottom: SP_S })
    .alignItems(VerticalAlign.Center);
  }

  /**
   * 二级页面：在线设备（从仪表盘「在线设备」卡片点进来）。
   *
   * 推入的 NavDestination 会整页盖住标签栏，所以背景和标题栏都自己来：
   * 返回按钮走 pathStack.pop()，系统返回键与侧滑返回由 Navigation 负责。
   */
  @Builder
  devicesDestination() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        this.navBackground();

        Column() {
          this.navTitleBar('在线设备');

          // 设备列表（复用在线设备页本体）
          Column() {
            DevicesPage({ client: this.client })
          }
          .layoutWeight(1)
          .width('100%');
        }
        .width('100%')
        .height('100%');
      }
      .width('100%')
      .height('100%');
    }
    .hideTitleBar(true);
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
        { text: '取消', color: colorString(C_TEXT_2, '#666666') },
        { text: '登出', color: colorString(C_DANGER, '#F53F3F') }
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
