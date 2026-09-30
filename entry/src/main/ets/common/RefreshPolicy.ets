/**
 * 全 App 统一的页面刷新规范 —— 这里是策略的**唯一来源**。
 *
 * 四个内容页（仪表盘 / 网络接口 / 无线 / 在线设备）和 OpenClash 页必须完全一致，
 * 规范正文见 `.codegenie/project_rule.md` 第七节第 10 条。要点：
 *
 *   1. 手势只有一种：**下拉刷新**（`Refresh` 组件）。页面里不再放「刷新」按钮，
 *      也绝不用 `Scroll`/`List` 的 `onReachStart`（初次渲染就在顶部，会无限刷新）。
 *   2. 只有**首屏**加载用 `isLoading` 显示整页 `LoadingProgress`；
 *      下拉刷新只切 `isRefreshing`（顶部指示器），**页面内容不重建、不闪白**。
 *   3. 失败反馈按 `LoadKind` 分三档（见下表），不再各页一套。
 *   4. 每页固定两个入口：`loadData(kind)` 取数据、`onPullRefresh()` 挂给 `Refresh`。
 *
 * | LoadKind  | 谁在用                                  | 屏幕上的表现       | 失败时                        |
 * |-----------|-----------------------------------------|--------------------|-------------------------------|
 * | `'first'` | `aboutToAppear` / 错误页的「重试」按钮   | 整页 LoadingProgress | 切错误页（带「重试」按钮）    |
 * | `'pull'`  | `Refresh.onRefreshing`                  | 顶部下拉指示器     | **保留已有数据** + toast 提示 |
 * | `'quiet'` | 定时器 / 写完配置后的重新加载            | 什么都不显示       | 保留已有数据，只写日志        |
 *
 * ⚠️ 别把 `'pull'` / `'quiet'` 的失败也写成 `hasError = true`：整页会被错误页换掉，
 * 用户正看着的数据凭空消失（之前仪表盘的静默自动刷新就是这个毛病）。
 * 另外加载**成功**时统一收尾 `this.hasError = false`，这样即使已经停在错误页，
 * 后台的静默刷新也能把它自动救回来，不必等用户点「重试」。
 */

import { promptAction } from '@kit.ArkUI';

/** 失败提示的显示时长（毫秒），各页一致 */
const FAIL_TOAST_MS: number = 2200;

/**
 * 加载类型 —— 决定「要不要显示 Loading」和「失败时怎么反馈」。
 * 见文件头部表格，所有页面必须用同一套取值。
 */
export type LoadKind = 'first' | 'pull' | 'quiet';

/** 失败时是否该切到错误页（只有首屏失败才切） */
export function shouldShowErrorPage(kind: LoadKind): boolean {
  return kind === 'first';
}

/** 失败时是否该弹提示（只有下拉刷新弹；静默刷新不打扰用户） */
export function shouldToast(kind: LoadKind): boolean {
  return kind === 'pull';
}

/** 统一的失败提示：保留屏幕上已有的数据，只弹一句话 */
export function notifyLoadFailed(msg: string): void {
  promptAction.showToast({ message: msg, duration: FAIL_TOAST_MS });
}