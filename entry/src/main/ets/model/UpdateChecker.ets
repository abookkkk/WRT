/**
 * 检查更新 / 下载新版本 —— 走 GitHub Releases API
 *
 * 仓库是公开的，不需要 token：`GET /repos/{owner}/{repo}/releases/latest`。
 * ⚠️ 两个实测要点：
 *   1. **GitHub 要求请求必须带 User-Agent**，不带直接 403（连 API 文档都这么写）。
 *   2. release 附件的下载地址会 **302 跳到 CDN**（objects.githubusercontent.com），
 *      http 客户端默认会跟跳转，但这里显式设 `maxRedirects: 5`，免得被当成失败。
 *
 * 下载的是 **未签名 HAP**：模拟器能直接装，真机需要华为开发者签名（所以本模块只负责
 * 把文件下到应用目录，安装交给系统安装器/文件管理 —— 普通应用没有静默安装权限）。
 */

import http from '@ohos.net.http';
import { BusinessError } from '@kit.BasicServicesKit';
import fs from '@ohos.file.fs';

/** 仓库坐标（关于页的联系方式 / 更新都指向这里） */
export const REPO_OWNER: string = 'abookkkk';
export const REPO_NAME: string = 'WRT';
export const REPO_URL: string = 'https://github.com/abookkkk/WRT';
export const REPO_ISSUES_URL: string = 'https://github.com/abookkkk/WRT/issues';
export const REPO_RELEASES_URL: string = 'https://github.com/abookkkk/WRT/releases';

/** GitHub 要求带 UA，不带会 403 */
const API_UA: string = 'OpenWrt-Manager';

/** release 里的一个附件 */
interface GithubAsset {
  name: string;
  browser_download_url: string;
  size: number;
}

/** release JSON（只取用得上的字段） */
interface GithubRelease {
  tag_name: string;
  name: string;
  body: string;
  html_url: string;
  published_at: string;
  assets: GithubAsset[];
}

/** 解析出来给界面用的版本信息 */
export class ReleaseInfo {
  /** 形如 v1.0.4 */
  tag: string = '';
  /** 形如 1.0.4 */
  version: string = '';
  name: string = '';
  /** release 正文（markdown 原文，界面上按纯文本显示） */
  notes: string = '';
  publishedAt: string = '';
  pageUrl: string = '';
  hapName: string = '';
  hapUrl: string = '';
  hapSize: number = 0;
}

export class UpdateChecker {
  /** 上一次检查失败的原因，给页面直接显示（空串 = 没失败过） */
  lastError: string = '';

  /** 拉最新 release。失败（无网络 / 限流 / 仓库没发过 release）返回 null，原因写日志 */
  async fetchLatest(): Promise<ReleaseInfo | null> {
    return new Promise<ReleaseInfo | null>((resolve) => {
      const client: http.HttpRequest = http.createHttp();
      const headers: Record<string, string> = {
        'Accept': 'application/vnd.github+json',
        'User-Agent': API_UA
      };
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 10000,
        readTimeout: 20000,
        maxRedirects: 5,
        usingCache: false
      };
      const url: string = `https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest`;
      client.request(url, options, (err: BusinessError | null, data: http.HttpResponse) => {
        client.destroy();
        if (err) {
          console.error('[UpdateChecker] 请求失败: ' + err.message);
          resolve(null);
          return;
        }
        const code: number = data.responseCode;
        if (code < 200 || code >= 300) {
          const body: string = String(data.result || '');
          console.error('[UpdateChecker] HTTP ' + code + ' body=' + body.substring(0, 200));
          this.lastError = UpdateChecker.describeError(code, body, data.header);
          resolve(null);
          return;
        }
        try {
          const rel: GithubRelease = JSON.parse(String(data.result)) as GithubRelease;
          const out: ReleaseInfo = new ReleaseInfo();
          out.tag = rel.tag_name || '';
          out.version = UpdateChecker.stripV(out.tag);
          out.name = rel.name || '';
          out.notes = rel.body || '';
          out.publishedAt = rel.published_at || '';
          out.pageUrl = rel.html_url || REPO_RELEASES_URL;
          const assets: GithubAsset[] = rel.assets || [];
          for (let i = 0; i < assets.length; i++) {
            const a: GithubAsset = assets[i];
            if (a.name !== undefined && a.name.length > 0 && a.name.endsWith('.hap')) {
              out.hapName = a.name;
              out.hapUrl = a.browser_download_url || '';
              out.hapSize = a.size || 0;
              break;
            }
          }
          console.info('[UpdateChecker] 最新版本 ' + out.tag + '，附件 ' + out.hapName);
          resolve(out.tag.length > 0 ? out : null);
        } catch (e) {
          console.error('[UpdateChecker] 解析 release 失败: ' + JSON.stringify(e));
          resolve(null);
        }
      });
    });
  }

  /**
   * 把 HAP 下到 dir 里（已存在同名文件就先删掉）。
   * @returns 成功返回本地完整路径，失败返回空串
   */
  async downloadHap(ri: ReleaseInfo, dir: string, onProgress: (received: number, total: number) => void): Promise<string> {
    if (ri.hapUrl.length === 0 || ri.hapName.length === 0) {
      console.error('[UpdateChecker] 这个 release 没有 .hap 附件');
      return '';
    }
    const path: string = dir + '/' + ri.hapName;
    let file: fs.File | null = null;
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
      file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    } catch (e) {
      console.error('[UpdateChecker] 准备文件失败: ' + JSON.stringify(e));
      return '';
    }

    const fd: number = file.fd;
    const total: number = ri.hapSize;

    return new Promise<string>((resolve) => {
      const client: http.HttpRequest = http.createHttp();
      let received: number = 0;
      let settled: boolean = false;
      /** requestInStream 的状态码回调往往在 dataEnd 之后才来，所以先记下来、缓一下再定成败 */
      let status: number = 0;

      const finish = (ok: boolean, errMsg: string): void => {
        if (settled) {
          return;
        }
        settled = true;
        client.off('dataReceive');
        client.off('dataEnd');
        client.destroy();
        try {
          fs.closeSync(fd);
        } catch (e) {
          console.warn('[UpdateChecker] 关闭文件失败: ' + JSON.stringify(e));
        }
        if (ok) {
          console.info('[UpdateChecker] 下载完成: ' + path + '（' + String(received) + ' 字节）');
          resolve(path);
          return;
        }
        console.error('[UpdateChecker] 下载失败: ' + errMsg);
        // 删掉半个文件，下次重下
        try {
          if (fs.accessSync(path)) {
            fs.unlinkSync(path);
          }
        } catch (e) {
          console.warn('[UpdateChecker] 清理残文件失败: ' + JSON.stringify(e));
        }
        resolve('');
      };

      client.on('dataReceive', (chunk: ArrayBuffer) => {
        try {
          fs.writeSync(fd, chunk);
        } catch (e) {
          finish(false, '写文件失败: ' + JSON.stringify(e));
          return;
        }
        received = received + chunk.byteLength;
        onProgress(received, total);
      });

      client.on('dataEnd', () => {
        // 等 400ms 让状态码回调先到，再一起判断：
        //   ① 非 2xx 一律算失败（实测私有仓库的附件会回 404，正文只有 9 字节 "Not Found"）
        //   ② 有预期大小时，字节数对不上也算失败（防止把错误页当成了安装包）
        setTimeout(() => {
          if (status !== 0 && (status < 200 || status >= 300)) {
            finish(false, 'HTTP ' + status);
            return;
          }
          if (total > 0 && received < total) {
            finish(false, '只下到 ' + String(received) + '/' + String(total) + ' 字节');
            return;
          }
          finish(true, '');
        }, 400);
      });

      const headers: Record<string, string> = {
        'User-Agent': API_UA,
        'Accept': 'application/octet-stream'
      };
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 10000,
        readTimeout: 120000,
        maxRedirects: 5,
        usingCache: false
      };
      client.requestInStream(ri.hapUrl, options, (err: BusinessError | null, code: number) => {
        if (err) {
          finish(false, err.message);
          return;
        }
        status = code;
        if (code < 200 || code >= 300) {
          finish(false, 'HTTP ' + code);
        }
      });
    });
  }

  /**
   * 把 HTTP 错误翻译成用户能看懂的话。
   * 实测：未登录调 GitHub API 每小时只有 60 次，用光了就是 403 + "API rate limit exceeded"，
   * 响应头里带 `x-ratelimit-reset`（Unix 秒），可以算出还要等多久。
   */
  private static describeError(code: number, body: string, header: Object): string {
    if (code === 403 && body.indexOf('rate limit') >= 0) {
      return 'GitHub API 限流了（未登录每小时 60 次）' + UpdateChecker.resetHint(header);
    }
    if (code === 404) {
      return '这个仓库还没发布过 Release（或者它是私有的、匿名看不到）';
    }
    if (code === 403) {
      return 'GitHub 返回 403：仓库可能是私有的（匿名看不到），或者 API 限流了';
    }
    return 'GitHub 返回 HTTP ' + code;
  }

  private static resetHint(header: Object): string {
    try {
      const h: Record<string, string> = header as Record<string, string>;
      const raw: string | undefined = h['x-ratelimit-reset'];
      if (raw === undefined || raw.length === 0) {
        return '，过一会儿再试';
      }
      const sec: number = parseInt(raw);
      if (isNaN(sec)) {
        return '，过一会儿再试';
      }
      const mins: number = Math.max(1, Math.ceil((sec * 1000 - Date.now()) / 60000));
      return '，约 ' + String(mins) + ' 分钟后恢复';
    } catch (e) {
      return '，过一会儿再试';
    }
  }

  /** 版本比较：remote 比 current 新返回 1，一样返回 0，更旧返回 -1 */
  static compareVersion(remote: string, current: string): number {
    const a: number[] = UpdateChecker.parseVersion(remote);
    const b: number[] = UpdateChecker.parseVersion(current);
    for (let i = 0; i < 4; i++) {
      const x: number = i < a.length ? a[i] : 0;
      const y: number = i < b.length ? b[i] : 0;
      if (x > y) {
        return 1;
      }
      if (x < y) {
        return -1;
      }
    }
    return 0;
  }

  /** 去掉开头的 v，再用 `.` 切开取整数段 */
  private static parseVersion(v: string): number[] {
    let s: string = v.trim();
    while (s.length > 0 && (s.charAt(0) === 'v' || s.charAt(0) === 'V')) {
      s = s.substring(1);
    }
    const parts: string[] = s.split('.');
    const out: number[] = [];
    for (let i = 0; i < parts.length; i++) {
      const n: number = parseInt(parts[i]);
      out.push(isNaN(n) ? 0 : n);
    }
    return out;
  }

  private static stripV(tag: string): string {
    let s: string = tag.trim();
    while (s.length > 0 && (s.charAt(0) === 'v' || s.charAt(0) === 'V')) {
      s = s.substring(1);
    }
    return s;
  }
}