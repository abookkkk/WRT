/**
 * 全局上下文单例
 * 
 * 用于在非 Ability 类中获取应用 Context，
 * 比如 SessionStore 需要 context 来初始化 Preferences。
 */

import { common } from '@kit.AbilityKit';

export class GlobalContext {
  private static instance: GlobalContext | null = null;
  private _context: common.Context | null = null;

  private constructor() {
    // 单例模式，私有构造
  }

  static getInstance(): GlobalContext {
    if (!GlobalContext.instance) {
      GlobalContext.instance = new GlobalContext();
    }
    return GlobalContext.instance;
  }

  /** 设置应用上下文（在 EntryAbility onCreate 时调用） */
  setContext(context: common.Context): void {
    this._context = context;
  }

  /** 获取应用上下文 */
  getContext(): common.Context | null {
    return this._context;
  }
}
