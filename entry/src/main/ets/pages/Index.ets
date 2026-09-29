/**
 * 应用根入口页面
 * 
 * 管理页面状态切换：
 * - 未登录 → 显示 LoginPage
 * - 已登录 → 显示 HomePage（Tab 导航）
 * 
 * 启动时自动尝试从本地恢复 Session。
 */

import { OpenWrtClient } from '../model/OpenWrtClient';
import { SessionStore } from '../model/SessionStore';
import { GlobalContext } from '../model/GlobalContext';
import { LoginPage } from './LoginPage';
import { HomePage } from './HomePage';

@Entry
@Component
struct Index {
  /** 页面状态：login = 登录页, home = 主页 */
  @State private currentPage: 'login' | 'home' = 'login';
  /** 客户端实例 */
  @State private client: OpenWrtClient | null = null;

  aboutToAppear(): void {
    // 启动时尝试自动恢复登录
    this.tryAutoLogin();
  }

  build() {
    Stack() {
      if (this.currentPage === 'login') {
        LoginPage({
          onLoginSuccess: (client: OpenWrtClient) => {
            this.client = client;
            this.currentPage = 'home';
          }
        })
      } else if (this.client) {
        HomePage({
          client: this.client,
          onLogout: () => {
            this.client = null;
            this.currentPage = 'login';
          }
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 尝试从本地恢复上次的登录 Session
   * 如果成功则直接进入主页，无需重新登录
   */
  private async tryAutoLogin(): Promise<void> {
    try {
      const ctx = GlobalContext.getInstance().getContext();
      if (!ctx) return;

      const store = new SessionStore();
      await store.init(ctx);

      const saved = await store.load();
      if (!saved || !saved.sessionId) return;

      // 创建客户端并恢复 Session
      const client = new OpenWrtClient(saved.host, saved.port, saved.useHttps);
      client.restoreSession(saved.sessionId);

      // 验证 Session 是否仍然有效（尝试调用 system.board）
      const boardResult = await client.getSystemBoard();

      if (boardResult.success) {
        // Session 有效，直接进入主页
        this.client = client;
        this.currentPage = 'home';
        console.info('[Index] Session 自动恢复成功');
      } else {
        // Session 已过期，销毁客户端，留在登录页
        console.warn('[Index] Session 已过期，需要重新登录');
        client.destroy();
        // 清除已过期的本地 Session
        await store.clear();
      }
    } catch (e) {
      console.warn('[Index] 自动登录失败: ' + JSON.stringify(e));
      // 失败就留在登录页，什么也不做
    }
  }
}
