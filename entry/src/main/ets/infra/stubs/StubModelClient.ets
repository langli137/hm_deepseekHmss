/**
 * ModelClientPort 内存测试桩（tasks.md 2.9）。
 * 可配置成功 / 鉴权失败 / 网络不可达 / 限流 / 超时五类行为，
 * 成功时按 chunk 顺序回调流式内容。
 */
import { ChatChunk, ChatRequest, ChatResult, ConnectionTestResult, ModelServiceConfig, UsageSummary } from '../../common/types/DomainTypes';
import { CancellationToken } from '../../common/types/InfraTypes';
import { AppError } from '../../common/error/AppError';
import { ErrorCode } from '../../common/error/ErrorCode';
import { ModelClientPort } from '../ports/ModelClientPort';

export enum StubModelBehavior {
  SUCCESS = 'SUCCESS',
  AUTH_FAILURE = 'AUTH_FAILURE',
  NETWORK_UNREACHABLE = 'NETWORK_UNREACHABLE',
  RATE_LIMITED = 'RATE_LIMITED',
  TIMEOUT = 'TIMEOUT'
}

export class StubModelClient implements ModelClientPort {
  behavior: StubModelBehavior;
  private chunks: string[];

  constructor(behavior: StubModelBehavior = StubModelBehavior.SUCCESS,
    chunks: string[] = ['你好', '，', '这是', '流式', '回答']) {
    this.behavior = behavior;
    this.chunks = chunks;
  }

  setChunks(chunks: string[]): void {
    this.chunks = chunks;
  }

  async probe(config: ModelServiceConfig, secret: string): Promise<ConnectionTestResult> {
    switch (this.behavior) {
      case StubModelBehavior.SUCCESS:
        return { success: true, reason: '' };
      case StubModelBehavior.AUTH_FAILURE:
        return { success: false, reason: '身份密钥无效' };
      case StubModelBehavior.NETWORK_UNREACHABLE:
        return { success: false, reason: '网络不可达' };
      case StubModelBehavior.RATE_LIMITED:
        return { success: false, reason: '请求过于频繁，已被限流' };
      case StubModelBehavior.TIMEOUT:
        return { success: false, reason: '连接超时' };
      default:
        return { success: true, reason: '' };
    }
  }

  async streamChat(request: ChatRequest, onChunk: (chunk: ChatChunk) => void,
    signal: CancellationToken): Promise<ChatResult> {
    switch (this.behavior) {
      case StubModelBehavior.AUTH_FAILURE:
        throw new AppError(ErrorCode.CFG_SECRET_INVALID, '身份密钥无效');
      case StubModelBehavior.NETWORK_UNREACHABLE:
        throw new AppError(ErrorCode.NET_UNAVAILABLE, '网络不可达');
      case StubModelBehavior.RATE_LIMITED:
        throw new AppError(ErrorCode.CFG_CONNECT_FAILED, 'RATE_LIMITED');
      case StubModelBehavior.TIMEOUT:
        return new Promise<ChatResult>((resolve, reject) => {
          signal.onCancel(() => {
            reject(new AppError(ErrorCode.NET_UNAVAILABLE, 'TIMEOUT'));
          });
        });
      default:
        break;
    }
    let content: string = '';
    for (let i = 0; i < this.chunks.length; i++) {
      if (signal.cancelled) {
        throw new AppError(ErrorCode.NET_UNAVAILABLE, '请求已取消');
      }
      const delta: string = this.chunks[i];
      content += delta;
      onChunk({ delta: delta });
    }
    const usage: UsageSummary = { promptTokens: 12, completionTokens: this.chunks.length, totalTokens: 12 + this.chunks.length };
    return { content: content, usage: usage, finishReason: 'stop' };
  }
}