/**
 * 主页（Tab 导航容器）
 *
 * HDS 化（HarmonyOS Design System 组件）：
 *   - HdsNavigation：MINI 沉浸标题栏（标题 / 副标题 / 右侧菜单），滚动渐变模糊 + 沉浸光感材质
 *   - HdsTabs：底部悬浮胶囊标签栏（barFloatingStyle），材质与标题栏共用一份
 *   - HdsNavDestination：二级页（在线设备 / 关于）的标题栏与返回
 *   - 延续自绘的部分：渐变背景、卡片、Tab 项内容（图标 + 文字）
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
import { SpatialMaterial } from '../common/SpatialMaterial';
import {
  HdsNavigation, HdsNavDestination, HdsTabs, HdsTabsController, HdsTabsFloatingStyle,
  HdsNavigationMenuItemOptions, HdsNavigationTitleMode, HdsNavDestinationTitleMode,
  HdsTitleBarContentStyle, ScrollEffectType, DividerShowType, SystemMaterialParams
} from '@kit.UIDesignKit';

import { OpenClashPage } from './OpenClashPage';
import {
  C_PRIMARY, C_BG_TOP, C_BG_MID, C_BG_BOTTOM, C_TEXT_1, C_TEXT_2, C_TEXT_3, C_DANGER,
  C_FILL, C_DIVIDER, F_TINY, ICON_L, SP_S, SP_M, colorString
} from '../common/Theme';

/**
 * HDS 标题栏在页面上占掉的高度（MINI 标题栏 56vp + 一点间距）。
 *
 * HDS 标题栏是**浮在内容之上**的（内容从它下面滚过去被渐变模糊），所以它不吃布局：
 * 一级页（写进 `safeTop` 给四个 Tab 页读）得自己垫出这一条，第一张卡片才不会钻到标题下面。
 * 二级页同理，只是它们本体自带上内边距，垫得少一点（见 HDS_MINI_TITLE_BAR_HEIGHT）。
 */
const HDS_TITLE_BAR_SPACE: number = 72;

/**
 * HDS MINI 标题栏本身的高度（vp）：二级页内容按「状态栏 + 它」自己垫。
 *
 * 比一级页的 HDS_TITLE_BAR_SPACE 小一圈，是因为二级页本体（关于 / 在线设备）
 * 自己还带一条顶部内边距，再垫 72 就显得空。
 */
const HDS_MINI_TITLE_BAR_HEIGHT: number = 56;
/** 底部悬浮胶囊标签栏高度（不含手势条高度与两侧留边）：页面底部留白按它算 */
const TAB_BAR_CONTENT_HEIGHT: number = 60;

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

  /** HdsTabs 的控制器（点悬浮栏 / 折叠迷你栏时由 HDS 自己切页） */
  private tabsController: HdsTabsController = new HdsTabsController();

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
      AppStorage.setOrCreate('safeTop', this.topInset + HDS_TITLE_BAR_SPACE);
      // 胶囊栏是"浮"在屏幕下沿上方的：底部让开手势条 + 下边距，页面底部留白要按这个总高度算
      AppStorage.setOrCreate('safeBottom', this.bottomInset + TAB_BAR_CONTENT_HEIGHT + 16);
      console.info(`[HomePage] 安全区：状态栏 ${this.topInset}vp / 手势条 ${this.bottomInset}vp`);
    } catch (e) {
      // 拿不到就退回 0：两根栏少铺一点，功能不受影响
      console.warn('[HomePage] 读取安全区失败: ' + JSON.stringify(e));
    }
  }

  /** 亮色模式判定：约束 5（亮色下 EXQUISITE 可能压白叠层）用它决定降档 */
  private isLightMode(): boolean {
    return this.appearance === 'light';
  }

  /** 当前该用的沉浸光感参数（HDS 标题栏与 HdsTabs 悬浮栏共用同一份） */
  private materialParams(): SystemMaterialParams {
    return SpatialMaterial.params('adaptive', this.isLightMode());
  }

  /**
   * HDS 标题栏的配色：默认那套跟的是**系统**深浅色，跟本 App 的
   * 「跟随系统 / 强制浅色 / 强制深色」不一致 —— 强制浅色时会出现白字压在浅色背景上。
   * 这里改用本项目的颜色资源（base/dark 两套，随 App 色彩模式自动换）。
   */
  private titleContentStyle(): HdsTitleBarContentStyle {
    return {
      titleStyle: {
        mainTitleColor: C_TEXT_1,
        subTitleColor: C_TEXT_3
      },
      menuStyle: {
        iconColor: C_TEXT_2,
        backgroundColor: C_FILL
      },
      backIconStyle: {
        iconColor: C_TEXT_1,
        backgroundColor: C_FILL
      },
      dividerStyle: {
        dividerColor: C_DIVIDER
      }
    };
  }

  /**
   * HdsTabs 悬浮胶囊样式：左右留边 + 让开手势条的那点下边距，材质与标题栏共用一份。
   * 页面底部留白仍按 safeBottom 给（内容从胶囊下面滚过去，靠 barOverlap）。
   */
  private floatingStyle(): HdsTabsFloatingStyle {
    return {
      barSideMargin: SP_M,
      barBottomMargin: SP_S,
      systemMaterialEffect: this.materialParams()
    };
  }

  /** 外观按钮的图标（跟随系统 / 深色 / 浅色） */
  private appearanceSymbol(): Resource {
    if (this.appearance === 'light') {
      return $r('sys.symbol.sun_max');
    }
    if (this.appearance === 'dark') {
      return $r('sys.symbol.moon_fill');
    }
    return $r('sys.symbol.auto_sun_max_fill');
  }

  /**
   * HDS 标题栏右侧的菜单项：原来自绘顶栏那三个按钮 —— 关于 / 外观 / 退出。
   * HDS 标题栏默认最多显示 3 个（maxCount 默认 3），这里正好 3 个，不会折进"更多"里。
   */
  private titleMenu(): Array<HdsNavigationMenuItemOptions> {
    const items: Array<HdsNavigationMenuItemOptions> = [];
    items.push({
      content: {
        icon: $r('sys.symbol.info_circle'),
        label: '关于',
        action: () => this.openAbout()
      }
    });
    items.push({
      content: {
        icon: this.appearanceSymbol(),
        label: this.appearanceLabel(),
        action: () => this.cycleAppearance()
      }
    });
    items.push({
      content: {
        icon: $r('sys.symbol.power'),
        label: '退出',
        action: () => this.handleLogout()
      }
    });
    return items;
  }

  build() {
    // 二级页面（在线设备）用 Navigation 的页面栈：推入的 NavDestination 会盖住整页（含底部标签栏），
    // 自带返回手势与系统返回键处理，比"再塞一个 Tab"更像正常的二级页面。
    HdsNavigation(this.pathStack) {
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

          // ===== Tab 内容 + HDS 悬浮胶囊标签栏 =====
          // 原来那条自绘胶囊交给 HdsTabs 的悬浮样式：胶囊的圆角 / 两侧留边 / 避让手势条 /
          // 沉浸光感材质都由系统负责，点选与左右滑动切页也还是 Tabs 的老行为。
          HdsTabs({ barPosition: BarPosition.End, index: this.currentIndex, controller: this.tabsController }) {
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
          .barMode(BarMode.Fixed)
          // 内容从胶囊下面滚过去（页面自身的底部留白仍按 safeBottom 给）
          .barOverlap(true)
          .barBackgroundColor(Color.Transparent)
          // 悬浮胶囊：留边 + 沉浸光感（参数与 HDS 标题栏共用一份）
          .barFloatingStyle(this.floatingStyle())
          // 左右滑动切页（Tabs 的默认能力，这里显式写出来表明是刻意保留的）
          .scrollable(true)
          .animationDuration(280)
          .onChange((index: number) => {
            this.currentIndex = index;
          })
          .layoutWeight(1);

        }
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
    }
    .titleBar({
      // 标题 / 菜单交给 HDS 标题栏：沉浸光感材质、滚动渐变模糊、状态栏避让都由它负责，
      // 自绘那条顶栏（含 ⓘ / 外观 / 退出 三个按钮）整块删掉。
      style: {
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR
        },
        systemMaterialEffect: this.materialParams(),
        // 静止 / 滚动后两态的配色都走本项目的资源（见 titleContentStyle）
        originalStyle: { contentStyle: this.titleContentStyle() },
        scrollEffectStyle: { contentStyle: this.titleContentStyle() }
      },
      content: {
        title: {
          mainTitle: 'OpenWrt 管理',
          subTitle: 'AX3000T · Filogic 820'
        },
        menu: { value: this.titleMenu() },
        // 分隔线跟着滚动出现 / 消失（HDS 默认行为，这里写出来表明是刻意保留的）
        divider: { showType: DividerShowType.AUTO }
      },
      // 全屏布局下标题栏默认从屏幕物理顶端排，右侧菜单会压到状态栏的电量 / 信号图标上：
      // 打开避让，让标题栏自己让出状态栏这一条
      avoidLayoutSafeArea: true
    })
    .mode(NavigationMode.Stack)
    .hideTitleBar(false)
    .titleMode(HdsNavigationTitleMode.MINI)
    // 首页是页面栈的根，没有上一级：MINI 标题栏默认会给一个返回箭头，这里关掉
    .hideBackButton(true)
    // HDS 组件默认跟**系统**深浅色走，而本 App 的外观是应用级 setColorMode（可强制浅/深）。
    // 打开这个开关，标题栏（以及范围内的 HdsTabs）才跟着 App 的色彩模式换色 ——
    // 否则强制浅色时会出现"白字压在浅色背景上"看不见的标题
    .withTheme({ enableThemeColorMode: true })
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

  /**
   * 二级页面：在线设备（从仪表盘「在线设备」卡片点进来）。
   *
   * 标题栏也交给 HDS（HdsNavDestination 的 MINI 模式：返回箭头 + 标题）：
   * 返回箭头走系统默认的 pop，系统返回键与侧滑返回仍由 Navigation 负责。
   */
  @Builder
  devicesDestination() {
    HdsNavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        this.navBackground();

        // 设备列表（复用在线设备页本体）：HDS 标题栏浮在上面，内容自己垫出一条
        Column() {
          DevicesPage({ client: this.client })
        }
        .width('100%')
        .height('100%')
        .padding({ top: this.topInset + HDS_MINI_TITLE_BAR_HEIGHT });
      }
      .width('100%')
      .height('100%');
    }
    .titleBar({
      style: { systemMaterialEffect: this.materialParams(), originalStyle: { contentStyle: this.titleContentStyle() } },
      content: { title: { mainTitle: '在线设备' } },
      // 与首页同理：全屏布局下 HDS 标题栏要自己让开状态栏那一条，
      // 否则返回箭头会压到状态栏的时钟上
      avoidLayoutSafeArea: true
    })
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .hideTitleBar(false)
    .withTheme({ enableThemeColorMode: true });
  }

  /** 二级页面：关于（版本信息 / 联系方式 / 检查更新并自动下载） */
  @Builder
  aboutDestination() {
    HdsNavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        this.navBackground();

        Column() {
          AboutPage()
        }
        .width('100%')
        .height('100%')
        .padding({ top: this.topInset + HDS_MINI_TITLE_BAR_HEIGHT });
      }
      .width('100%')
      .height('100%');
    }
    .titleBar({
      style: { systemMaterialEffect: this.materialParams(), originalStyle: { contentStyle: this.titleContentStyle() } },
      content: { title: { mainTitle: '关于' } },
      avoidLayoutSafeArea: true
    })
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .hideTitleBar(false)
    .withTheme({ enableThemeColorMode: true });
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
