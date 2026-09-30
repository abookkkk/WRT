/**
 * 主页（Tab 导航容器）
 *
 * 视觉特性（HarmonyOS 6）：
 *   - 沉浸式：expandSafeArea 让内容延伸到状态栏 / 导航栏区域
 *   - 渐变背景：浅蓝 → 灰白过渡
 *   - 液态玻璃上下栏：透明底 + backgroundEffect 纯模糊（内容从栏下滚过）
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
import { AboutPage } from './AboutPage';

import { OpenClashPage } from './OpenClashPage';
import {
  C_PRIMARY, C_BG_TOP, C_BG_MID, C_BG_BOTTOM, C_TEXT_1, C_TEXT_2, C_TEXT_3, C_DANGER,
  C_FILL, C_DANGER_CHIP, C_DIVIDER, C_PRIMARY_SOFT,
  F_HERO, F_TITLE, F_SECTION, F_CAPTION, F_TINY, ICON_L, ICON_M, SP_XS, SP_S, SP_M, SP_L, colorString
} from '../common/Theme';

/** 顶栏内容高度（标题那一行 + 上下内边距，不含状态栏高度）：页面顶部留白按它算 */
const HEADER_CONTENT_HEIGHT: number = 72;
/** 底部悬浮胶囊标签栏高度（不含手势条高度与两侧留边） */
const TAB_BAR_CONTENT_HEIGHT: number = 60;
/** 胶囊内单个 Tab 的高度：比胶囊矮一圈，选中时的药丸高亮才不会贴到胶囊边 */
const TAB_ITEM_HEIGHT: number = TAB_BAR_CONTENT_HEIGHT - 12;

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

  /** 顶部安全区（状态栏）高度，单位 vp：顶栏自己垫这么高，内容才能从它后面滚过去 */
  @State private topInset: number = 0;

  /** 自绘悬浮标签栏要用它切页（系统标签栏已置 0 高） */
  private tabsController: TabsController = new TabsController();

  /** 当前外观模式（跟随系统 / 浅色 / 深色）：按钮文案与图标都用它 */
  @State private appearance: AppearanceMode = 'system';

  /** 二级页面栈：目前只有「在线设备」（从仪表盘的卡片进入，不再占一个底部 Tab） */
  private pathStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    this.measureInsets();
    // 全屏布局是在 EntryAbility 的 loadContent 回调里切的，可能晚于本页 aboutToAppear ——
    // 稍后再量一次避让区（值变了 @StorageProp 会让各页自动重排）
    setTimeout(() => {
      this.measureInsets();
    }, 600);
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

  /**
   * 读窗口避让区（状态栏 / 手势条），换算成 vp。
   *
   * 全屏布局（ThemeSettings 里 setWindowLayoutFullScreen(true)）之后，页面从屏幕物理顶端开始铺，
   * 两根悬浮栏的避让就得**页面自己留白**：算好写进 AppStorage，
   * 各页用 @StorageProp('safeTop' / 'safeBottom') 读（值变化时页面会自动重排）。
   */
  private async measureInsets(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const win: window.Window = await window.getLastWindow(ctx);
      const systemArea: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const indicatorArea: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const bottomPx: number = Math.max(systemArea.bottomRect.height, indicatorArea.bottomRect.height);
      this.topInset = px2vp(systemArea.topRect.height);
      this.bottomInset = px2vp(bottomPx);
      AppStorage.setOrCreate('safeTop', this.topInset + HEADER_CONTENT_HEIGHT);
      // 胶囊栏是"浮"在屏幕下沿上方的：底部让开手势条 + 下边距，页面底部留白要按这个总高度算
      AppStorage.setOrCreate('safeBottom', this.bottomInset + TAB_BAR_CONTENT_HEIGHT + 16);
      console.info(`[HomePage] 安全区：状态栏 ${this.topInset}vp / 手势条 ${this.bottomInset}vp`);
    } catch (e) {
      // 拿不到就退回 0：两根栏少铺一点，功能不受影响
      console.warn('[HomePage] 读取安全区失败: ' + JSON.stringify(e));
    }
  }

  /** 切 Tab（自绘悬浮标签栏用） */
  private switchTab(index: number): void {
    if (index === this.currentIndex) {
      return;
    }
    this.currentIndex = index;
    this.tabsController.changeIndex(index);
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
              // 顶栏塞了 ⓘ / 外观 / 退出 三个按钮，空间紧（外观按钮最长会显示「跟随系统」）。
              // 用自适应字号：放得下就 22 号，放不下自动缩到最小 16 号 —— 不会换行、也不会被省略号截掉
              Text('OpenWrt 管理')
                .maxFontSize(F_TITLE)
                .minFontSize(16)
                .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
                .fontWeight(FontWeight.Bold)
                .fontColor(C_TEXT_1)
                .maxLines(1);
              Text('AX3000T · Filogic 820')
                .fontSize(F_CAPTION)
                .fontColor(C_TEXT_3)
                .margin({ top: 2 });
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1);

            // ===== 关于（二级页面：版本 / 联系方式 / 检查更新）=====
          Button() {
            SymbolGlyph($r('sys.symbol.info_circle'))
              .fontSize(ICON_M)
              .fontColor([C_TEXT_2])
              .renderingStrategy(SymbolRenderingStrategy.SINGLE);
          }
          .height(32)
          .type(ButtonType.Capsule)
          .backgroundColor(C_FILL)
          .padding({ left: SP_M, right: SP_M })
          .margin({ right: SP_S })
          .onClick(() => this.openAbout());

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
            .padding({ left: SP_S, right: SP_S })
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
          // 顶部垫出状态栏高度：栏的毛玻璃因此从屏幕物理顶端开始铺（盖住状态栏那条），
          // 但栏里的文字/按钮仍落在状态栏下方，不会和时钟、电量图标打架
          .padding({ left: SP_L, right: SP_L, top: this.topInset + SP_S, bottom: SP_S })
          .alignItems(VerticalAlign.Center)
          // 「液态玻璃」：底色**完全透明**、不加任何色调，只对背后的内容做模糊（再轻微提一点饱和度），
          // 让玻璃有存在感但不遮挡内容。要更糊就把 radius 调大
          .backgroundColor(Color.Transparent)
          .backgroundEffect({ radius: 20, saturation: 1.4, brightness: 1.0, color: Color.Transparent })
          .border({ width: { bottom: 1 }, color: C_DIVIDER })
          // 脱离布局流、绝对定位到屏幕顶端：Tabs 因此能占满整屏，卡片可以从顶栏后面滚过去被虚化
          .position({ x: 0, y: 0 })
          .zIndex(2);

          // ===== Tab 内容 + 自绘悬浮标签栏 =====
          Stack({ alignContent: Alignment.Bottom }) {
            Tabs({ barPosition: BarPosition.End, index: this.currentIndex, controller: this.tabsController }) {
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
            .width('100%')
            .height('100%')
            // 系统标签栏置 0 高：栏改由下面自绘那条担任（它才能浮在内容之上 + 铺到屏幕物理底部）
            .barHeight(0)
            .barMode(BarMode.Fixed)
            .animationDuration(280)
            .onChange((index: number) => {
              this.currentIndex = index;
            });

            // ===== 自绘悬浮胶囊标签栏 =====
            // 样式：不贴边、独立圆角胶囊、选中项带药丸高亮（当下流行的那种）。
            // 为什么自绘（这几点都在模拟器上试过）：
            //   · 全屏布局后，系统的 BarPosition.End 标签栏会贴到屏幕**物理**底部 —— 掉进手势条里；
            //   · 想只把栏往上抬：barHeight 只会让栏变高、连带把内容区往上挤（内容就没法从栏下滚过了）；
            //   · 自绘这条：浮在内容之上、底部让开手势条，卡片能从它下面滚过去并被虚化。
            Row() {
              Column() {
                this.tabItem(0, '仪表盘')
              }
              .height(TAB_ITEM_HEIGHT)
              .layoutWeight(1)
              .borderRadius(TAB_ITEM_HEIGHT / 2)
              .backgroundColor(this.currentIndex === 0 ? C_PRIMARY_SOFT : Color.Transparent)
              .onClick(() => this.switchTab(0));

              Column() {
                this.tabItem(1, '网络')
              }
              .height(TAB_ITEM_HEIGHT)
              .layoutWeight(1)
              .borderRadius(TAB_ITEM_HEIGHT / 2)
              .backgroundColor(this.currentIndex === 1 ? C_PRIMARY_SOFT : Color.Transparent)
              .onClick(() => this.switchTab(1));

              Column() {
                this.tabItem(2, '无线')
              }
              .height(TAB_ITEM_HEIGHT)
              .layoutWeight(1)
              .borderRadius(TAB_ITEM_HEIGHT / 2)
              .backgroundColor(this.currentIndex === 2 ? C_PRIMARY_SOFT : Color.Transparent)
              .onClick(() => this.switchTab(2));

              Column() {
                this.tabItem(3, 'Clash')
              }
              .height(TAB_ITEM_HEIGHT)
              .layoutWeight(1)
              .borderRadius(TAB_ITEM_HEIGHT / 2)
              .backgroundColor(this.currentIndex === 3 ? C_PRIMARY_SOFT : Color.Transparent)
              .onClick(() => this.switchTab(3));
            }
            .height(TAB_BAR_CONTENT_HEIGHT)
            .padding({ left: 6, right: 6 })
            // 两侧留边 + 底部让开手势条：所以它是一条「浮」在屏幕下沿上方的胶囊，而不是贴边通栏
            .margin({ left: SP_M, right: SP_M, bottom: SP_S + this.bottomInset })
            .borderRadius(TAB_BAR_CONTENT_HEIGHT / 2)
            // 与顶栏同一套「液态玻璃」：透明底 + 纯模糊，整圈一条细线 + 轻微投影让它浮起来
            .backgroundColor(Color.Transparent)
            .backgroundEffect({ radius: 20, saturation: 1.4, brightness: 1.0, color: Color.Transparent })
            .border({ width: 1, color: C_DIVIDER })
            .shadow(ShadowStyle.OUTER_DEFAULT_SM)
            .clip(true);
          }
          .layoutWeight(1)
          .width('100%');
        }
        .width('100%')
        .height('100%')
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

  /** 打开二级页面：关于（版本 / 联系方式 / 检查更新） */
  private openAbout(): void {
    this.pathStack.pushPathByName('about', null);
  }


  /**
   * 页面栈分发。Navigation 的 navDestination 只回调页面名，
   * 所以在这里按 name 选页面（目前只有一个）。
   */
  @Builder
  pageMap(name: string) {
    if (name === 'devices') {
      this.devicesDestination();
    } else if (name === 'about') {
      this.aboutDestination();
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
    // 全屏布局后二级页也从屏幕物理顶端开始铺，标题栏自己垫出状态栏高度
    .padding({ left: SP_L, right: SP_L, top: this.topInset + SP_S, bottom: SP_S })
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

  /** 二级页面：关于（版本信息 / 联系方式 / 检查更新并自动下载） */
  @Builder
  aboutDestination() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        this.navBackground();

        Column() {
          this.navTitleBar('关于');

          Column() {
            AboutPage()
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
