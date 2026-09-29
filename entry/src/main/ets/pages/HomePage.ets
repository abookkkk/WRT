/**
 * 主页（Tab 导航容器）
 *
 * 使用 Tabs 组件包含五个标签页：
 * 仪表盘、网络接口、无线网络、在线设备、OpenClash
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

@Component
export struct HomePage {
  private client!: OpenWrtClient;
  private onLogout!: () => void;

  @State private currentIndex: number = 0;

  build() {
    Column() {
      // ===== 顶部标题栏 =====
      Row() {
        Text('OpenWrt 管理')
          .fontSize(20)
          .fontWeight(FontWeight.Bold);

        Blank();

        Button('退出')
          .fontSize(14)
          .fontColor('#E84040')
          .type(ButtonType.Normal)
          .onClick(() => this.handleLogout());
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 4 });

      // ===== Tab 内容区 =====
      Tabs({ barPosition: BarPosition.End }) {
        // Tab 1：仪表盘
        TabContent() {
          DashboardPage({ client: this.client })
        }
        .tabBar('仪表盘')

        // Tab 2：网络接口
        TabContent() {
          NetworkPage({ client: this.client })
        }
        .tabBar('网络接口')

        // Tab 3：无线网络
        TabContent() {
          WifiPage({ client: this.client })
        }
        .tabBar('无线网络')

        // Tab 4：在线设备
        TabContent() {
          DevicesPage({ client: this.client })
        }
        .tabBar('在线设备')

        // Tab 5：OpenClash
        TabContent() {
          OpenClashPage({ client: this.client })
        }
        .tabBar('OpenClash')
      }
      .layoutWeight(1)
      .width('100%')
      // 5 个标签在手机宽度下放不下，改成可横向滚动的标签栏
      .barMode(BarMode.Scrollable)
      .onChange((index: number) => {
        this.currentIndex = index;
      })
      .scrollable(true)
      .animationDuration(300)
    }
    .width('100%')
    .height('100%')
  }

  private async handleLogout(): Promise<void> {
    const result = await promptAction.showDialog({
      title: '确认登出',
      message: '确定要退出登录吗？',
      buttons: [
        { text: '取消', color: '#666666' },
        { text: '登出', color: '#E84040' }
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
