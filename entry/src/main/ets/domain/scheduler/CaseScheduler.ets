/**
 * 用例串行调度器（design.md 2.1.3(2)，tasks.md 5.3/5.4）。
 * 按 seq 升序串行调度，跳过 seq <= watermark 的已完成用例；
 * 单用例超时标记 TIMEOUT 并继续后续；限流按 BackoffPolicy 退避重试。
 */
import {
  CaseResult, CaseSnapshot, ChatRequest, ChatChunk, ChatResult, UsageSummary
} from '../../common/types/DomainTypes';
import { JudgeMode, Verdict } from '../../common/types/Enums';
import { CancellationToken } from '../../common/types/InfraTypes';
import { ModelClientPort } from '../../infra/ports/ModelClientPort';
import { StreamAssembler } from './StreamAssembler';
import { JudgeStrategy } from '../strategy/JudgeStrategy';
import { BackoffPolicy } from '../strategy/BackoffPolicy';
import { DEFAULT_MAX_RETRY } from '../../common/types/Constants';
import { AppError } from '../../common/error/AppError';
import { ErrorCode } from '../../common/error/ErrorCode';
import { newId } from '../../common/utils/IdGen';

/** 单用例执行结果 */
export interface CaseExecutionResult {
  caseResult: CaseResult;
  usage: UsageSummary;
}

/** 限流检测：AppError.detail 含 RATE_LIMITED 时判定为限流 */
function isRateLimited(e: Object): boolean {
  if (e instanceof AppError) {
    return e.detail.includes('RATE_LIMITED');
  }
  return false;
}

export class CaseScheduler {
  private streamAssembler: StreamAssembler;
  private judgeStrategy: JudgeStrategy;

  constructor(streamAssembler: StreamAssembler, judgeStrategy: JudgeStrategy) {
    this.streamAssembler = streamAssembler;
    this.judgeStrategy = judgeStrategy;
  }

  /**
   * 执行单个用例：流式调用 → 超时/限流处理 → 判定 → 返回结果。
   * 超时由调用方通过 token.cancel() 触发；此处检测 token.cancelled 判定超时。
   *
   * @param caseSnapshot 用例快照
   * @param request 已构造好的 ChatRequest
   * @param modelClient 模型客户端端口
   * @param token 取消令牌（超时/暂停/网络中断时由调用方 cancel）
   * @param onChunk 流式片段回调
   * @param judgeMode 判定方式
   * @param taskId 任务标识（用于 CaseResult.taskId）
   */
  async executeCase(
    caseSnapshot: CaseSnapshot,
    request: ChatRequest,
    modelClient: ModelClientPort,
    token: CancellationToken,
    onChunk: (chunk: ChatChunk) => void,
    judgeMode: JudgeMode,
    taskId: string
  ): Promise<CaseExecutionResult> {
    this.streamAssembler.reset();
    const startedAt: number = Date.now();

    let chatResult: ChatResult | null = null;
    let attempt: number = 0;

    while (attempt <= DEFAULT_MAX_RETRY) {
      try {
        chatResult = await modelClient.streamChat(request, onChunk, token);
        break;
      } catch (e) {
        if (token.cancelled) {
          break;
        }
        if (isRateLimited(e) && attempt < DEFAULT_MAX_RETRY) {
          const delay: number = BackoffPolicy.nextDelayMs(attempt);
          await this.sleep(delay);
          attempt += 1;
          continue;
        }
        if (isRateLimited(e) && attempt >= DEFAULT_MAX_RETRY) {
          throw new AppError(ErrorCode.TASK_ALREADY_RUNNING, 'RATE_LIMITED_MAX_RETRY');
        }
        throw new AppError(ErrorCode.UNKNOWN_ERROR, `用例执行失败: ${e}`);
      }
    }

    const elapsedMs: number = Date.now() - startedAt;
    const modelAnswer: string = this.streamAssembler.current();

    let verdict: Verdict;
    if (token.cancelled) {
      verdict = Verdict.TIMEOUT;
    } else if (chatResult === null) {
      verdict = Verdict.ERROR;
    } else {
      verdict = this.judgeStrategy.judge(caseSnapshot.referenceAnswer, modelAnswer, judgeMode);
    }

    const usage: UsageSummary = chatResult !== null
      ? chatResult.usage
      : { promptTokens: 0, completionTokens: 0, totalTokens: 0 };

    const caseResult: CaseResult = {
      caseId: newId('case'),
      taskId: taskId,
      seq: caseSnapshot.seq,
      content: caseSnapshot.content,
      referenceAnswer: caseSnapshot.referenceAnswer,
      modelAnswer: modelAnswer,
      verdict: verdict,
      elapsedMs: elapsedMs
    };

    return { caseResult: caseResult, usage: usage };
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, ms);
    });
  }
}