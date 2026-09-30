/**
 * 应用根入口页面
 *
 * 管理页面状态切换：
 * - 未登录 → 显示 LoginPage
 * - 已登录 → 显示 HomePage（Tab 导航）
 *
 * 启动时自动尝试从本地恢复 Session；
 * 运行期间一旦检测到 session 过期（rpcd 空闲 300 秒失效，返回 -32002），
 * 统一清掉本地 session 并退回登录页 —— 密码不落地，所以无法自动重登。
 */

import { promptAction } from '@kit.ArkUI';
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

  /**
   * 每次页面重新可见时校验一次 session。
   *
   * 空闲超 300 秒 session 就废了，最常见的触发场景是"切后台放一会儿再回来"。
   * 主动打一个轻量请求（system.board）让客户端自己判断：拿到 -32002 时它会回调
   * handleSessionExpired，我们不用管返回值。比等用户点「保存并应用」才发现失败好。
   */
  onPageShow(): void {
    if (this.currentPage === 'home' && this.client) {
      this.validateSession();
    }
  }

  build() {
    Stack() {
      if (this.currentPage === 'login') {
        LoginPage({
          onLoginSuccess: (client: OpenWrtClient) => {
            this.attachClient(client);
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

  /** 给客户端挂上"会话过期"回调 */
  private attachClient(client: OpenWrtClient): void {
    client.setOnSessionExpired(() => {
      this.handleSessionExpired();
    });
  }

  /** 轻量校验 session（失败时客户端内部会触发过期回调） */
  private async validateSession(): Promise<void> {
    if (!this.client) {
      return;
    }
    try {
      await this.client.getSystemBoard();
    } catch (e) {
      console.warn('[Index] 校验 session 异常: ' + JSON.stringify(e));
    }
  }

  /**
   * 会话过期统一处理：清本地 session → 销毁客户端 → 回登录页并提示。
   *
   * 已经在登录页时不处理：启动时 tryAutoLogin 自己会清掉过期 session，
   * 而且那时 currentPage 还是 'login'，不该再弹一次 toast。
   */
  private async handleSessionExpired(): Promise<void> {
    if (this.currentPage !== 'home') {
      return;
    }
    console.warn('[Index] 会话已过期，返回登录页');

    try {
      const ctx = GlobalContext.getInstance().getContext();
      if (ctx) {
        const store = new SessionStore();
        await store.init(ctx);
        await store.clear();
      }
    } catch (e) {
      console.error('[Index] 清除过期 Session 失败: ' + JSON.stringify(e));
    }

    if (this.client) {
      this.client.destroy();
    }
    this.client = null;
    this.currentPage = 'login';
    promptAction.showToast({ message: '登录已过期，请重新登录', duration: 2500 });
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
      // 先挂回调：下面那次校验请求如果撞上过期，也能走统一处理
      this.attachClient(client);

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
