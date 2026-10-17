/**
 * 模型服务协议策略扩展点（design.md 2.1.3(4)、tasks.md 3.6）。
 * 抽象「请求构造 / 响应解析 / 用量提取」三类能力，默认实现为 OpenAI 兼容
 * /chat/completions 语义（假设 A3）。
 *
 * R1 替换点：上游 harness 若采用不同推理协议（字段名、流式分帧、用量口径不同），
 * 只需新增 ModelProtocolStrategy 实现并在装配处替换 OpenAiProtocolStrategy，
 * 无需改动应用服务层与基础设施层（design.md 风险登记 R1）。
 */
import {
  ChatChunk, ChatMessage, ChatRequest, ChatResult, ModelServiceConfig, RunParameters, UsageSummary
} from '../../common/types/DomainTypes';

export interface ModelProtocolStrategy {
  /** 构造推理请求（注入鉴权凭证，spec 4.3.4） */
  buildRequest(config: ModelServiceConfig, secret: string, messages: ChatMessage[],
    params: RunParameters, stream: boolean): ChatRequest;
  /** 解析单个流式数据帧，提取增量文本 */
  parseChunk(payload: string): ChatChunk;
  /** 从单帧中提取用量信息；无用量字段时返回 undefined */
  extractUsage(payload: string): UsageSummary | undefined;
  /** 解析非流式完整响应体，聚合为最终结果 */
  parseFinal(payload: string): ChatResult;
}

// ============ OpenAI 兼容协议线格式（私有，不对外暴露） ============

interface OpenAiDelta {
  content?: string;
}

interface OpenAiChoice {
  delta?: OpenAiDelta;
  message?: ChatMessage;
  finish_reason?: string;
}

interface OpenAiUsageRaw {
  prompt_tokens: number;
  completion_tokens: number;
  total_tokens: number;
}

interface OpenAiResponse {
  choices?: OpenAiChoice[];
  usage?: OpenAiUsageRaw;
}

function toUsage(raw: OpenAiUsageRaw | undefined): UsageSummary | undefined {
  if (raw === undefined) {
    return undefined;
  }
  return {
    promptTokens: raw.prompt_tokens,
    completionTokens: raw.completion_tokens,
    totalTokens: raw.total_tokens
  };
}

/** OpenAI 兼容默认实现（A3）。 */
export class OpenAiProtocolStrategy implements ModelProtocolStrategy {
  buildRequest(config: ModelServiceConfig, secret: string, messages: ChatMessage[],
    params: RunParameters, stream: boolean): ChatRequest {
    return {
      endpoint: config.endpoint,
      targetModel: config.targetModel,
      secret: secret,
      messages: messages,
      temperature: params.temperature,
      maxOutputTokens: params.maxOutputTokens,
      stream: stream
    };
  }

  parseChunk(payload: string): ChatChunk {
    const parsed: OpenAiResponse = JSON.parse(payload) as OpenAiResponse;
    const choices: OpenAiChoice[] = parsed.choices ?? [];
    let delta: string = '';
    for (let i = 0; i < choices.length; i++) {
      const d: OpenAiDelta | undefined = choices[i].delta;
      if (d !== undefined && d.content !== undefined) {
        delta += d.content;
      }
    }
    return { delta: delta };
  }

  extractUsage(payload: string): UsageSummary | undefined {
    const parsed: OpenAiResponse = JSON.parse(payload) as OpenAiResponse;
    return toUsage(parsed.usage);
  }

  parseFinal(payload: string): ChatResult {
    const parsed: OpenAiResponse = JSON.parse(payload) as OpenAiResponse;
    const choices: OpenAiChoice[] = parsed.choices ?? [];
    let content: string = '';
    let finishReason: string = '';
    for (let i = 0; i < choices.length; i++) {
      const choice: OpenAiChoice = choices[i];
      if (choice.message !== undefined) {
        content += choice.message.content;
      }
      if (choice.finish_reason !== undefined && choice.finish_reason.length > 0) {
        finishReason = choice.finish_reason;
      }
    }
    const usage: UsageSummary = toUsage(parsed.usage)
      ?? { promptTokens: 0, completionTokens: 0, totalTokens: 0 };
    return { content: content, usage: usage, finishReason: finishReason };
  }
}