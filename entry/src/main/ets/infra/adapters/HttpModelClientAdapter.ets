/**
 * 模型服务 HTTP 客户端适配器。基于 @ohos.net.http（tasks.md 2.3）。
 * - probe：轻量探测，分类「不可达 / 鉴权失败 / 限流」；
 * - streamChat：requestInStream + SseParser 增量解析，dataEnd 聚合结果；
 * - 响应错误映射：401/403→CFG_SECRET_INVALID，429→限流（detail=RATE_LIMITED），
 *   网络不可达→NET_UNAVAILABLE，其余 4xx/5xx→CFG_CONNECT_FAILED。
 * 所有回调仅做内存追加与 JSON 解析，不执行耗时主线程操作。
 */
import http from '@ohos.net.http';
import util from '@ohos.util';
import { ChatChunk, ChatRequest, ChatResult, ConnectionTestResult, ModelServiceConfig, UsageSummary } from '../../common/types/DomainTypes';
import { CancellationToken } from '../../common/types/InfraTypes';
import { AppError } from '../../common/error/AppError';
import { ErrorCode } from '../../common/error/ErrorCode';
import { ModelClientPort } from '../ports/ModelClientPort';
import { SseParser } from './SseParser';

const CONNECT_TIMEOUT_MS: number = 10000;
const READ_TIMEOUT_MS: number = 60000;
const RATE_LIMITED_DETAIL: string = 'RATE_LIMITED';

interface AuthHeaders {
  'Content-Type': string;
  'Authorization': string;
  'Accept': string;
}

interface OpenAiDelta {
  content?: string;
}

interface OpenAiChoice {
  delta?: OpenAiDelta;
  finish_reason?: string;
}

interface OpenAiUsage {
  prompt_tokens: number;
  completion_tokens: number;
  total_tokens: number;
}

interface OpenAiChunkResponse {
  choices?: OpenAiChoice[];
  usage?: OpenAiUsage;
}

interface OpenAiMessage {
  role: string;
  content: string;
}

interface OpenAiBody {
  model: string;
  messages: OpenAiMessage[];
  temperature: number;
  max_tokens: number;
  stream: boolean;
}

function decode(buffer: ArrayBuffer): string {
  const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  return decoder.decodeToString(new Uint8Array(buffer));
}

function emptyUsage(): UsageSummary {
  return { promptTokens: 0, completionTokens: 0, totalTokens: 0 };
}

function mapUsage(usage: OpenAiUsage | undefined): UsageSummary {
  if (usage === undefined) {
    return emptyUsage();
  }
  return { promptTokens: usage.prompt_tokens, completionTokens: usage.completion_tokens, totalTokens: usage.total_tokens };
}

function buildHeaders(secret: string): AuthHeaders {
  return {
    'Content-Type': 'application/json',
    'Authorization': `Bearer ${secret}`,
    'Accept': 'text/event-stream'
  };
}

function buildBody(request: ChatRequest): string {
  const body: OpenAiBody = {
    model: request.targetModel,
    messages: request.messages,
    temperature: request.temperature,
    max_tokens: request.maxOutputTokens,
    stream: request.stream
  };
  return JSON.stringify(body);
}

/** 从错误对象提取网络不可达判定 */
function isNetworkError(e: Object): boolean {
  const err = e as Error;
  const msg: string = err !== undefined && err.message !== undefined ? err.message : '';
  return msg.length === 0 || msg.includes('2300') || msg.includes('unreachable');
}

export class HttpModelClientAdapter implements ModelClientPort {
  async probe(config: ModelServiceConfig, secret: string): Promise<ConnectionTestResult> {
    const client: http.HttpRequest = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: buildHeaders(secret),
        extraData: JSON.stringify({
          model: config.targetModel,
          messages: [{ role: 'user', content: 'ping' } as OpenAiMessage] as OpenAiMessage[],
          max_tokens: 1,
          stream: false
        }),
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      };
      const response: http.HttpResponse = await client.request(config.endpoint, options);
      return this.judgeResponse(response.responseCode);
    } catch (e) {
      if (isNetworkError(e as Object)) {
        return { success: false, reason: '网络不可达' };
      }
      return { success: false, reason: '连接失败' };
    } finally {
      client.destroy();
    }
  }

  private judgeResponse(code: number): ConnectionTestResult {
    if (code >= 200 && code < 300) {
      return { success: true, reason: '' };
    }
    if (code === 401 || code === 403) {
      return { success: false, reason: '身份密钥无效' };
    }
    if (code === 429) {
      return { success: false, reason: '请求过于频繁，已被限流' };
    }
    return { success: false, reason: `服务返回异常状态码 ${code}` };
  }

  async streamChat(request: ChatRequest, onChunk: (chunk: ChatChunk) => void,
    signal: CancellationToken): Promise<ChatResult> {
    const client: http.HttpRequest = http.createHttp();
    const parser: SseParser = new SseParser();
    let content: string = '';
    let finishReason: string = '';
    let usage: UsageSummary = emptyUsage();

    return new Promise<ChatResult>((resolve, reject) => {
      let settled: boolean = false;

      const cleanup = (): void => {
        client.off('dataReceive');
        client.off('dataEnd');
        client.off('headersReceive');
        client.destroy();
      };

      const settleReject = (error: AppError): void => {
        if (settled) {
          return;
        }
        settled = true;
        cleanup();
        reject(error);
      };

      const settleResolve = (): void => {
        if (settled) {
          return;
        }
        settled = true;
        cleanup();
        resolve({ content: content, usage: usage, finishReason: finishReason });
      };

      const consumePayload = (payload: string): void => {
        const parsed: OpenAiChunkResponse = JSON.parse(payload) as OpenAiChunkResponse;
        if (parsed.usage !== undefined) {
          usage = mapUsage(parsed.usage);
        }
        const choices: OpenAiChoice[] = parsed.choices ?? [];
        for (let i = 0; i < choices.length; i++) {
          const choice: OpenAiChoice = choices[i];
          if (choice.finish_reason !== undefined && choice.finish_reason.length > 0) {
            finishReason = choice.finish_reason;
          }
          const delta: string = choice.delta !== undefined && choice.delta.content !== undefined ? choice.delta.content : '';
          if (delta.length > 0) {
            content += delta;
            onChunk({ delta: delta });
          }
        }
      };

      signal.onCancel(() => {
        settleReject(new AppError(ErrorCode.NET_UNAVAILABLE, '请求已取消'));
      });

      client.on('headersReceive', () => {
      });

      client.on('dataReceive', (data: ArrayBuffer) => {
        if (settled) {
          return;
        }
        const tryConsume = (): void => {
          const payloads: string[] = parser.feed(decode(data));
          for (let i = 0; i < payloads.length; i++) {
            consumePayload(payloads[i]);
          }
        };
        try {
          tryConsume();
        } catch (e) {
          settleReject(new AppError(ErrorCode.CFG_CONNECT_FAILED, '流式响应解析失败'));
        }
        if (parser.isDone()) {
          settleResolve();
        }
      });

      client.on('dataEnd', () => {
        if (settled) {
          return;
        }
        try {
          const rest: string[] = parser.flush();
          for (let i = 0; i < rest.length; i++) {
            consumePayload(rest[i]);
          }
        } catch (e) {
          settleReject(new AppError(ErrorCode.CFG_CONNECT_FAILED, '流式响应解析失败'));
          return;
        }
        settleResolve();
      });

      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: buildHeaders(request.secret),
        extraData: buildBody(request),
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      };

      client.requestInStream(request.endpoint, options).then((code: number) => {
        if (settled) {
          return;
        }
        if (code === 401 || code === 403) {
          settleReject(new AppError(ErrorCode.CFG_SECRET_INVALID, '身份密钥无效'));
          return;
        }
        if (code === 429) {
          settleReject(new AppError(ErrorCode.CFG_CONNECT_FAILED, RATE_LIMITED_DETAIL));
          return;
        }
        if (code >= 400) {
          settleReject(new AppError(ErrorCode.CFG_CONNECT_FAILED, `服务返回状态码 ${code}`));
        }
      }).catch((e: Object) => {
        if (isNetworkError(e)) {
          settleReject(new AppError(ErrorCode.NET_UNAVAILABLE, '网络不可达'));
        } else {
          settleReject(new AppError(ErrorCode.CFG_CONNECT_FAILED, '请求失败'));
        }
      });
    });
  }
}