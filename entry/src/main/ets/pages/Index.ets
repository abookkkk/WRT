/**
 * 应用根入口页面
 *
 * 管理页面状态切换：
 * - 未登录 → 显示 LoginPage
 * - 已登录 → 显示 HomePage（Tab 导航）
 *
 * 启动时自动尝试从本地恢复 Session；
 * 运行期间一旦检测到 session 过期（rpcd 空闲 300 秒失效，返回 -32002），
 * 处理方式：登录页勾过「记住密码」就用它静默重登（在同一个客户端实例上，页面不受影响）；
 * 没记住 / 密码改过了，才清掉本地 session 退回登录页。
 */

import { promptAction } from '@kit.ArkUI';
import { OpenWrtClient } from '../model/OpenWrtClient';
import { SessionStore } from '../model/SessionStore';
import { CredentialStore, SavedCredential } from '../model/CredentialStore';
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
  /** 会话过期处理的重入保护：并发请求可能同时撞上过期 */
  private expiring: boolean = false;

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
    if (this.expiring) {
      return;
    }
    this.expiring = true;
    try {
      console.warn('[Index] 会话已过期');

      // 1) 记住过密码就直接在**同一个客户端**上重登 —— 不换实例，
      //    各页面在构造时拿到的就是它，换了它们手里的引用就废了。
      if (await this.reloginInPlace()) {
        promptAction.showToast({ message: '登录已过期，已自动重新登录', duration: 2500 });
        return;
      }

      // 2) 没记住密码 / 密码不对 → 照旧清掉本地 session，退回登录页
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
    } finally {
      this.expiring = false;
    }
  }

  /**
   * 用记住的密码在**当前客户端**上重新登录。
   * 成功返回 true，并把新 session 存回本地（下次启动可直接恢复）。
   */
  private async reloginInPlace(): Promise<boolean> {
    const client: OpenWrtClient | null = this.client;
    if (client === null) {
      return false;
    }
    try {
      const ctx = GlobalContext.getInstance().getContext();
      if (!ctx) {
        return false;
      }
      const cred: SavedCredential | null = await new CredentialStore().load(ctx);
      if (cred === null || cred.password.length === 0) {
        return false;
      }
      const username: string = cred.username.length > 0 ? cred.username : 'root';
      const ok: boolean = await client.login(username, cred.password);
      if (!ok) {
        console.warn('[Index] 自动重登失败（密码可能改过了），退回登录页');
        return false;
      }

      const store: SessionStore = new SessionStore();
      await store.init(ctx);
      const saved = await store.load();
      await store.save({
        host: saved ? saved.host : client.getHost(),
        port: saved ? saved.port : 80,
        useHttps: saved ? saved.useHttps : false,
        username: username,
        sessionId: client.getSessionId()
      });
      console.info('[Index] 已用记住的密码自动重登（同一个客户端）');
      return true;
    } catch (e) {
      console.warn('[Index] 自动重登异常: ' + JSON.stringify(e));
      return false;
    }
  }

  /**
   * 启动时用记住的密码直接登录（这条路要新建客户端，因为上一个已经销毁了）。
   * @returns 成功返回新客户端，失败返回 null
   */
  private async loginWithSavedCredential(host: string, port: number, useHttps: boolean): Promise<OpenWrtClient | null> {
    try {
      const ctx = GlobalContext.getInstance().getContext();
      if (!ctx) {
        return null;
      }
      const cred: SavedCredential | null = await new CredentialStore().load(ctx);
      if (cred === null || cred.password.length === 0) {
        return null;
      }
      const username: string = cred.username.length > 0 ? cred.username : 'root';
      const client: OpenWrtClient = new OpenWrtClient(host, port, useHttps);
      const ok: boolean = await client.login(username, cred.password);
      if (!ok) {
        client.destroy();
        console.warn('[Index] 记住的密码登录失败（可能改过了）');
        return null;
      }
      this.attachClient(client);

      const store: SessionStore = new SessionStore();
      await store.init(ctx);
      await store.save({
        host: host,
        port: port,
        useHttps: useHttps,
        username: username,
        sessionId: client.getSessionId()
      });
      console.info('[Index] 已用记住的密码自动登录');
      return client;
    } catch (e) {
      console.warn('[Index] 自动登录异常: ' + JSON.stringify(e));
      return null;
    }
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
        // Session 已过期：先试试用记住的密码直接登进去，不行再留在登录页
        console.warn('[Index] Session 已过期，尝试用记住的密码自动登录');
        client.destroy();
        // 清除已过期的本地 Session
        await store.clear();
        const auto: OpenWrtClient | null = await this.loginWithSavedCredential(saved.host, saved.port, saved.useHttps);
        if (auto !== null) {
          this.client = auto;
          this.currentPage = 'home';
        }
      }
    } catch (e) {
      console.warn('[Index] 自动登录失败: ' + JSON.stringify(e));
      // 失败就留在登录页，什么也不做
    }
  }
}
