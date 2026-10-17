/**
 * 模型服务客户端端口。对齐 design.md 2.2.2(G) 与 tasks.md 2.3。
 * 协议按 OpenAI 兼容 /chat/completions 语义（假设 A3），支持 SSE 流式返回。
 */
import { ChatChunk, ChatRequest, ChatResult, ConnectionTestResult, ModelServiceConfig } from '../../common/types/DomainTypes';
import { CancellationToken } from '../../common/types/InfraTypes';

export interface ModelClientPort {
  /** 轻量探测：验证服务可达性与鉴权有效性，无持久化副作用 */
  probe(config: ModelServiceConfig, secret: string): Promise<ConnectionTestResult>;
  /**
   * 发起流式对话请求。
   * 增量片段通过 onChunk 回调推送（仅追加内存缓冲，禁止耗时主线程操作）；
   * signal.cancel() 触发请求中断；返回聚合后的最终结果。
   */
  streamChat(request: ChatRequest, onChunk: (chunk: ChatChunk) => void,
    signal: CancellationToken): Promise<ChatResult>;
}