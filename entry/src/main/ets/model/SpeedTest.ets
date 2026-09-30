/**
 * 测速引擎（手机侧真打流）
 *
 * 和「花瓣测速」做的事一样：先打几发小请求量**延迟与抖动**，再从公网拉一大段数据量**下载**，
 * 最后往服务器推一段数据量**上传**。全部在**手机侧**完成，路由器只是转发（不依赖 ubus）。
 *
 * 端点默认用 Cloudflare 的公开测速接口（无需密钥、无需注册）：
 *   GET  <base>/__down?bytes=N   下载
 *   POST <base>/__up             上传
 * 地址可以在页面上改、存在本机 preferences —— 换成自己内网照这个协议实现的端点也行。
 *
 * 为什么下载 / 上传都是**多段循环 + 10 秒时限**，而不是"一次拉 8 MB"：
 *   · Cloudflare 的 `__down` 超过 10 MB 会直接回 **403**（`bytes=12000000` 就被拒了），
 *     单段点不了太大；可 8 MB 在 200 Mbps 的线路上只要 0.3 秒 —— 采样窗口太短，数字不可信。
 *   · 所以一段一段地拉（每段 8 MB），拉到 10 秒收手，速率按"第一段第一字节 → 最后一段最后一字节"
 *     的整段时间算。慢链路一段都拉不完、快链路会跑好几段，两头都准。
 *
 * 其他实现要点（都踩过）：
 *   · 下载必须用 `requestInStream` + `on('dataReceive')`：普通 `request()` 会把整段响应读进内存
 *     再一次性返回，既吃内存、也量不到"过程中的速率"（表盘指针就没法实时摆）。
 *   · 计时**从第一个数据块到达时开始**，避开 TLS 握手与首包等待 —— 否则高延迟线路会被低估。
 *   · **非 2xx 或传输失败绝不能当成速率**：Cloudflare 拒绝时回 403，错误页也有 1 KB 多，
 *     一开始正是拿这 1 KB 算出了个假的 0.01 Mbps。
 *   · `destroy()` 之后仍然会回调 dataEnd / error，所有出口都要用 settled 标记兜住，别重复 resolve。
 *   · 上传走普通 `request()`（一次 POST 一段），实时速率靠 `on('dataSendProgress')`；
 *     拿不到进度事件时只是指针不动，最终平均速率照样算得出来。
 */

import http from '@ohos.net.http';
import { BusinessError } from '@kit.BasicServicesKit';

/** 默认测速端点：Cloudflare 公开接口，不需要密钥 */
export const DEFAULT_SPEED_BASE: string = 'https://speed.cloudflare.com';

/** 请求头里的 UA：有些 CDN 对没有 UA 的请求会直接给挑战页 / 403 */
const SPEED_TEST_UA: string = 'OpenWrt-Manager/1.0.3 (HarmonyOS)';

/** 测速阶段 */
export type SpeedPhase = 'idle' | 'ping' | 'download' | 'upload' | 'done';

/** 一次测速的参数 */
export class SpeedTestOptions {
  /** 测速服务器根地址（末尾不要带斜杠） */
  baseUrl: string = DEFAULT_SPEED_BASE;
  /** 延迟采样次数 */
  pingCount: number = 8;
  /** 下载：单段请求多少字节（实测 Cloudflare 超过 10 MB 回 403，所以点 8 MB） */
  downloadChunkBytes: number = 8000000;
  /** 下载：这一阶段最多跑多少毫秒（到点收手） */
  downloadMaxMs: number = 10000;
  /** 下载：总字节兜底，防止极端快链路上拉太多流量（10 秒 × 100 Mbps 就到 125 MB 了） */
  downloadTotalMaxBytes: number = 150000000;
  /** 上传：单段发送多少字节 */
  uploadChunkBytes: number = 1000000;
  /** 上传：这一阶段最多跑多少毫秒 */
  uploadMaxMs: number = 10000;
  /** 上传：总字节兜底 */
  uploadMaxBytes: number = 40000000;
}

/** 一次测速的结果 */
export class SpeedTestResult {
  /** 平均延迟（毫秒） */
  pingMs: number = 0;
  /** 抖动：相邻两次延迟差值的绝对值的平均（毫秒） */
  jitterMs: number = 0;
  /** 没回来的请求数 */
  lost: number = 0;
  /** 下载 Mbps */
  downMbps: number = 0;
  /** 上传 Mbps */
  upMbps: number = 0;
  downloadBytes: number = 0;
  downloadMs: number = 0;
  uploadBytes: number = 0;
  uploadMs: number = 0;
  /** 测成功的阶段数：0=只有延迟 1=+下载 2=+上传（中途停止时用来说明结果不完整） */
  stages: number = 0;
  /** 失败 / 部分失败说明，空串表示一切正常 */
  error: string = '';
}

/** 页面回调：驱动表盘与阶段文字 */
export interface SpeedTestHooks {
  /** 阶段变化 */
  onPhase: (p: SpeedPhase) => void;
  /** 实时速率（Mbps），下载 / 上传阶段用 */
  onSpeed: (mbps: number) => void;
  /** 每量到一发延迟（毫秒） */
  onPing: (ms: number) => void;
  /** 某个阶段结束时的平均速率（Mbps）：后面的阶段要继续把它显示出来，别空着 */
  onPhaseDone: (p: SpeedPhase, mbps: number) => void;
}

/** 一次传输（一段）的结果 */
class ByteTiming {
  bytes: number = 0;
  /** 数据开始流动的时间（阶段计时起点） */
  firstDataAt: number = 0;
  error: string = '';
  /** 是否该结束整个阶段（超时 / 中止 / 出错） */
  phaseOver: boolean = false;
}

/** 一个阶段的累计状态（多段循环时跨段累加） */
class PhaseState {
  /** 阶段开始时间（用于超时判断） */
  started: number = 0;
  /** 第一段数据开始的时间 */
  firstAt: number = 0;
  /** 阶段累计字节 */
  bytes: number = 0;
  /** 上次报实时速率的时间与字节数（滑动窗口） */
  winAt: number = 0;
  winBytes: number = 0;
}

export class SpeedTestRunner {
  private aborted: boolean = false;
  /** 正在进行的长请求（下载 / 上传），abort 时要 destroy */
  private liveReq: http.HttpRequest | null = null;

  /** 主动中止（用户点「停止」或页面退出） */
  abort(): void {
    this.aborted = true;
    this.destroyLive();
  }

  private destroyLive(): void {
    const req: http.HttpRequest | null = this.liveReq;
    this.liveReq = null;
    if (req !== null) {
      try {
        req.destroy();
      } catch (e) {
        console.warn('[SpeedTest] destroy 失败: ' + JSON.stringify(e));
      }
    }
  }

  /** 跑一次完整测速：延迟 → 下载 → 上传 */
  async run(opt: SpeedTestOptions, hooks: SpeedTestHooks): Promise<SpeedTestResult> {
    const res: SpeedTestResult = new SpeedTestResult();
    const base: string = this.normalizeBase(opt.baseUrl);

    // ---- 1) 延迟 / 抖动 ----
    hooks.onPhase('ping');
    const pings: number[] = [];
    let lost: number = 0;
    for (let i = 0; i < opt.pingCount; i++) {
      if (this.aborted) {
        return res;
      }
      const ms: number = await this.pingOnce(base);
      if (ms > 0) {
        pings.push(ms);
        hooks.onPing(ms);
      } else {
        lost = lost + 1;
      }
    }
    let sum: number = 0;
    for (let i = 0; i < pings.length; i++) {
      sum = sum + pings[i];
    }
    res.pingMs = pings.length > 0 ? sum / pings.length : 0;
    if (pings.length > 1) {
      let acc: number = 0;
      for (let i = 1; i < pings.length; i++) {
        acc = acc + Math.abs(pings[i] - pings[i - 1]);
      }
      res.jitterMs = acc / (pings.length - 1);
    }
    res.lost = lost;
    console.info('[SpeedTest] 延迟 ' + res.pingMs.toFixed(0) + ' ms / 抖动 ' + res.jitterMs.toFixed(0) +
      ' ms（成功 ' + String(pings.length) + ' 发，丢 ' + String(lost) + ' 发）');
    if (pings.length === 0) {
      res.error = '连不上测速服务器（' + base + '）';
      hooks.onPhase('done');
      return res;
    }
    if (this.aborted) {
      hooks.onPhase('done');
      return res;
    }

    // ---- 2) 下载 ----
    hooks.onPhase('download');
    const dl: ByteTiming = await this.download(base, opt, hooks);
    if (dl.error.length > 0 && dl.bytes < 1000000) {
      // 拿到的字节太少（典型：403 错误页只有 1 KB 多）→ 这一阶段算失败，不报速率
      res.downloadBytes = 0;
      res.downMbps = 0;
      res.error = '下载失败: ' + dl.error;
      console.warn('[SpeedTest] 下载失败: ' + dl.error + '（只收到 ' + String(dl.bytes) + ' 字节）');
    } else {
      res.downloadBytes = dl.bytes;
      res.downloadMs = Math.max(1, dl.firstDataAt > 0 ? Date.now() - dl.firstDataAt : 0);
      res.downMbps = this.toMbps(dl.bytes, res.downloadMs);
      res.stages = res.stages + 1;
      if (dl.error.length > 0) {
        res.error = '下载部分请求失败: ' + dl.error;
      }
      console.info('[SpeedTest] 下载 ' + res.downMbps.toFixed(2) + ' Mbps（' + String(dl.bytes) +
        ' 字节 / ' + String(res.downloadMs) + ' ms）');
    }
    hooks.onPhaseDone('download', res.downMbps);
    if (this.aborted) {
      hooks.onPhase('done');
      return res;
    }

    // ---- 3) 上传 ----
    hooks.onPhase('upload');
    const ul: ByteTiming = await this.upload(base, opt, hooks);
    if (ul.error.length > 0 && ul.bytes < 1000000) {
      res.uploadBytes = 0;
      res.upMbps = 0;
      res.error = (res.error.length > 0 ? res.error + '；' : '') + '上传失败: ' + ul.error;
      console.warn('[SpeedTest] 上传失败: ' + ul.error + '（只发出 ' + String(ul.bytes) + ' 字节）');
    } else {
      res.uploadBytes = ul.bytes;
      res.uploadMs = Math.max(1, ul.firstDataAt > 0 ? Date.now() - ul.firstDataAt : 0);
      res.upMbps = this.toMbps(ul.bytes, res.uploadMs);
      res.stages = res.stages + 1;
      if (ul.error.length > 0) {
        res.error = (res.error.length > 0 ? res.error + '；' : '') + '上传部分请求失败: ' + ul.error;
      }
      console.info('[SpeedTest] 上传 ' + res.upMbps.toFixed(2) + ' Mbps（' + String(ul.bytes) +
        ' 字节 / ' + String(res.uploadMs) + ' ms）');
    }
    hooks.onPhaseDone('upload', res.upMbps);

    hooks.onPhase('done');
    return res;
  }

  // ==================== 延迟 ====================

  /** 一发延迟采样：失败返回 0（也算丢包） */
  private pingOnce(base: string): Promise<number> {
    return new Promise<number>((resolve) => {
      const client: http.HttpRequest = http.createHttp();
      const t0: number = Date.now();
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: this.commonHeaders(),
        connectTimeout: 6000,
        readTimeout: 6000,
        usingCache: false
      };
      client.request(base + '/__down?bytes=0', options, (err: BusinessError | null, data: http.HttpResponse) => {
        const ms: number = Date.now() - t0;
        client.destroy();
        if (err) {
          resolve(0);
          return;
        }
        const code: number = data.responseCode;
        resolve(code >= 200 && code < 300 ? ms : 0);
      });
    });
  }

  // ==================== 下载 ====================

  /** 下载阶段：一段一段拉到时限 / 兜底上限 */
  private async download(base: string, opt: SpeedTestOptions, hooks: SpeedTestHooks): Promise<ByteTiming> {
    const st: PhaseState = new PhaseState();
    st.started = Date.now();
    st.winAt = st.started;
    const out: ByteTiming = new ByteTiming();

    let guard: number = 0;
    while (!this.aborted && Date.now() - st.started < opt.downloadMaxMs &&
           st.bytes < opt.downloadTotalMaxBytes && guard < 60) {
      guard = guard + 1;
      const part: ByteTiming = await this.downloadChunk(base, opt, st, hooks);
      if (st.firstAt === 0 && part.firstDataAt > 0) {
        st.firstAt = part.firstDataAt;
      }
      if (part.error.length > 0) {
        out.error = part.error;
        break;
      }
      if (part.phaseOver || part.bytes === 0) {
        break;
      }
    }

    out.bytes = st.bytes;
    out.firstDataAt = st.firstAt;
    return out;
  }

  /** 拉一段：到段大小、到时限、到兜底上限或被中止就收手 */
  private downloadChunk(
    base: string, opt: SpeedTestOptions, st: PhaseState, hooks: SpeedTestHooks
  ): Promise<ByteTiming> {
    return new Promise<ByteTiming>((resolve) => {
      const client: http.HttpRequest = http.createHttp();
      this.liveReq = client;
      const url: string = base + '/__down?bytes=' + String(opt.downloadChunkBytes);

      let bytes: number = 0;
      let first: number = 0;
      let settled: boolean = false;

      const finish = (errMsg: string, over: boolean): void => {
        if (settled) {
          return;
        }
        settled = true;
        client.off('dataReceive');
        client.off('dataEnd');
        client.destroy();
        if (this.liveReq === client) {
          this.liveReq = null;
        }
        const out: ByteTiming = new ByteTiming();
        out.bytes = bytes;
        out.firstDataAt = first;
        out.error = errMsg;
        out.phaseOver = over;
        resolve(out);
      };

      client.on('dataReceive', (chunk: ArrayBuffer) => {
        const now: number = Date.now();
        if (first === 0) {
          first = now;
          if (st.firstAt === 0) {
            st.firstAt = now;
            st.winAt = now;
            st.winBytes = st.bytes;
          }
        }
        bytes = bytes + chunk.byteLength;
        st.bytes = st.bytes + chunk.byteLength;

        // 实时速率：每 300 ms 报一次（滑动窗口，避免抖动）
        const dt: number = now - st.winAt;
        if (dt >= 300) {
          hooks.onSpeed(this.toMbps(st.bytes - st.winBytes, dt));
          st.winAt = now;
          st.winBytes = st.bytes;
        }

        if (this.aborted || now - st.started >= opt.downloadMaxMs ||
            st.bytes >= opt.downloadTotalMaxBytes) {
          finish('', true);
          return;
        }
        if (bytes >= opt.downloadChunkBytes) {
          // 这一段拉够了：收手去拉下一段（阶段还没结束）
          finish('', false);
        }
      });

      client.on('dataEnd', () => {
        finish('', false);
      });

      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: this.commonHeaders(),
        connectTimeout: 8000,
        readTimeout: 30000,
        usingCache: false
      };
      client.requestInStream(url, options, (err: BusinessError | null, code: number) => {
        if (err) {
          // 主动 destroy() 之后这里也会回调一次，settled 标记会兜住
          finish(err.message, true);
          return;
        }
        if (code < 200 || code >= 300) {
          finish('HTTP ' + code, true);
        }
      });
    });
  }

  // ==================== 上传 ====================

  /** 上传阶段：一段一段推到时限 / 兜底上限 */
  private async upload(base: string, opt: SpeedTestOptions, hooks: SpeedTestHooks): Promise<ByteTiming> {
    const st: PhaseState = new PhaseState();
    st.started = Date.now();
    st.winAt = st.started;
    const out: ByteTiming = new ByteTiming();

    let guard: number = 0;
    while (!this.aborted && Date.now() - st.started < opt.uploadMaxMs &&
           st.bytes < opt.uploadMaxBytes && guard < 40) {
      guard = guard + 1;
      const part: ByteTiming = await this.uploadChunk(base, opt, st, hooks);
      if (st.firstAt === 0 && part.firstDataAt > 0) {
        st.firstAt = part.firstDataAt;
      }
      if (part.error.length > 0) {
        out.error = part.error;
        break;
      }
      if (part.bytes === 0) {
        break;
      }
    }

    out.bytes = st.bytes;
    out.firstDataAt = st.firstAt;
    return out;
  }

  /** 推一段：一次 POST，进度事件用来喂表盘 */
  private uploadChunk(
    base: string, opt: SpeedTestOptions, st: PhaseState, hooks: SpeedTestHooks
  ): Promise<ByteTiming> {
    return new Promise<ByteTiming>((resolve) => {
      const client: http.HttpRequest = http.createHttp();
      this.liveReq = client;
      const size: number = Math.max(1, Math.floor(opt.uploadChunkBytes));
      const payload: ArrayBuffer = new ArrayBuffer(size);

      let sent: number = 0;
      let settled: boolean = false;

      const finish = (bytesDone: number, errMsg: string): void => {
        if (settled) {
          return;
        }
        settled = true;
        client.off('dataSendProgress');
        client.destroy();
        if (this.liveReq === client) {
          this.liveReq = null;
        }
        const out: ByteTiming = new ByteTiming();
        out.bytes = bytesDone;
        out.firstDataAt = st.firstAt;
        out.error = errMsg;
        resolve(out);
      };

      client.on('dataSendProgress', (info: http.DataSendProgressInfo) => {
        const now: number = Date.now();
        sent = info.sendSize;
        if (st.firstAt === 0 && sent > 0) {
          st.firstAt = now;
          st.winAt = now;
          st.winBytes = st.bytes;
        }
        const dt: number = now - st.winAt;
        if (dt >= 250) {
          hooks.onSpeed(this.toMbps(st.bytes + sent - st.winBytes, dt));
          st.winAt = now;
          st.winBytes = st.bytes + sent;
        }
        if (this.aborted) {
          finish(sent, '');
        }
      });

      const headers: Record<string, string> = {
        'Content-Type': 'application/octet-stream',
        'Accept-Encoding': 'identity',
        'User-Agent': SPEED_TEST_UA
      };
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: payload,
        connectTimeout: 8000,
        readTimeout: 60000,
        usingCache: false
      };
      client.request(base + '/__up', options, (err: BusinessError | null, data: http.HttpResponse) => {
        if (err) {
          finish(sent, err.message);
          return;
        }
        const code: number = data.responseCode;
        if (code >= 200 && code < 300) {
          // 这一段成功：整段字节都算进去
          st.bytes = st.bytes + size;
          finish(size, '');
        } else {
          // 非 2xx 就是失败，别拿"字节发出去了"当速率
          finish(0, 'HTTP ' + code);
        }
      });
    });
  }

  // ==================== 工具 ====================

  /** 公共请求头：带个 UA，并声明不压缩（这样字节数就等于实际传输量） */
  private commonHeaders(): Record<string, string> {
    const h: Record<string, string> = {
      'Accept-Encoding': 'identity',
      'User-Agent': SPEED_TEST_UA
    };
    return h;
  }

  /** 字节 / 毫秒 → Mbps */
  private toMbps(bytes: number, ms: number): number {
    if (bytes <= 0 || ms <= 0) {
      return 0;
    }
    return (bytes * 8) / (ms / 1000) / 1000000;
  }

  /** 去掉首尾空格与末尾斜杠，容忍用户填 `.../` 或带空格 */
  private normalizeBase(url: string): string {
    let v: string = url.trim();
    while (v.length > 0 && v.charAt(v.length - 1) === '/') {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }
}