/**
 * 执行参数区间规则工具。spec 6.2.5 要求各参数处于允许区间，
 * 区间由 common/types/Constants.ets 内置规则确定。
 * 对齐 tasks.md 4.1「在 RunParameters 中实现 isWithinRange()」——ArkTS 接口无方法体，
 * 故以纯函数形式提供等价能力。
 */
import { JudgeMode } from '../types/Enums';
import { RunParameters } from '../types/DomainTypes';
import {
  CONCURRENCY_MAX, CONCURRENCY_MIN, MAX_OUTPUT_TOKENS_MAX, MAX_OUTPUT_TOKENS_MIN,
  TEMPERATURE_MAX, TEMPERATURE_MIN, TIMEOUT_MS_MAX, TIMEOUT_MS_MIN
} from '../types/Constants';

export interface ParamViolation {
  field: string;
  min: number;
  max: number;
  actual: number;
}

/** 逐参数区间判定；返回全部越界项（空数组表示合法） */
export function violations(params: RunParameters): ParamViolation[] {
  const result: ParamViolation[] = [];
  if (params.temperature < TEMPERATURE_MIN || params.temperature > TEMPERATURE_MAX) {
    result.push({ field: 'temperature', min: TEMPERATURE_MIN, max: TEMPERATURE_MAX, actual: params.temperature });
  }
  if (params.maxOutputTokens < MAX_OUTPUT_TOKENS_MIN || params.maxOutputTokens > MAX_OUTPUT_TOKENS_MAX) {
    result.push({
      field: 'maxOutputTokens', min: MAX_OUTPUT_TOKENS_MIN, max: MAX_OUTPUT_TOKENS_MAX, actual: params.maxOutputTokens
    });
  }
  if (params.concurrency < CONCURRENCY_MIN || params.concurrency > CONCURRENCY_MAX) {
    result.push({ field: 'concurrency', min: CONCURRENCY_MIN, max: CONCURRENCY_MAX, actual: params.concurrency });
  }
  if (params.timeoutMs < TIMEOUT_MS_MIN || params.timeoutMs > TIMEOUT_MS_MAX) {
    result.push({ field: 'timeoutMs', min: TIMEOUT_MS_MIN, max: TIMEOUT_MS_MAX, actual: params.timeoutMs });
  }
  return result;
}

/** 是否全部参数处于合法区间 */
export function isWithinRange(params: RunParameters): boolean {
  return violations(params).length === 0;
}

/** 描述首个越界项，用于错误 detail（spec 5.2.1-3「提示合法区间」） */
export function describeViolation(params: RunParameters): string {
  const vs: ParamViolation[] = violations(params);
  if (vs.length === 0) {
    return '';
  }
  const v: ParamViolation = vs[0];
  return `${v.field} 需在 [${v.min}, ${v.max}] 之间，当前为 ${v.actual}`;
}

/** 新建任务、应用设置使用的默认执行参数 */
export function createDefaultParams(): RunParameters {
  return {
    temperature: 0.7,
    maxOutputTokens: 2048,
    concurrency: 1,
    timeoutMs: 60000,
    judgeMode: JudgeMode.CONTAINS
  };
}

/** 深拷贝执行参数，保证快照不可变（spec 5.2.1-6） */
export function cloneParams(params: RunParameters): RunParameters {
  return {
    temperature: params.temperature,
    maxOutputTokens: params.maxOutputTokens,
    concurrency: params.concurrency,
    timeoutMs: params.timeoutMs,
    judgeMode: params.judgeMode
  };
}