/**
 * 判定策略扩展点（design.md 2.1.3(4)，tasks.md 5.4/9.8）。
 * 支撑 spec 2 中"裁判模型"语义；默认实现为精确匹配与包含匹配。
 *
 * R1 替换点：REFEREE_MODEL 模式当前退化为 CONTAINS，
 * 上游 harness 若提供裁判模型判定逻辑，替换 DefaultJudgeStrategy 即可。
 */
import { JudgeMode, Verdict } from '../../common/types/Enums';

export interface JudgeStrategy {
  judge(reference: string, answer: string, mode: JudgeMode): Verdict;
}

/** 去除首尾空白后比较 */
function trimEquals(a: string, b: string): boolean {
  return a.trim() === b.trim();
}

/** 双向包含：a 包含 b 或 b 包含 a */
function bidirectionalContains(a: string, b: string): boolean {
  const at: string = a.trim();
  const bt: string = b.trim();
  return at.includes(bt) || bt.includes(at);
}

export class DefaultJudgeStrategy implements JudgeStrategy {
  judge(reference: string, answer: string, mode: JudgeMode): Verdict {
    switch (mode) {
      case JudgeMode.EXACT_MATCH:
        return trimEquals(reference, answer) ? Verdict.PASSED : Verdict.FAILED;
      case JudgeMode.CONTAINS:
        return bidirectionalContains(reference, answer) ? Verdict.PASSED : Verdict.FAILED;
      case JudgeMode.REFEREE_MODEL:
        // R1 替换点：裁判模型判定暂退化为双向包含
        return bidirectionalContains(reference, answer) ? Verdict.PASSED : Verdict.FAILED;
      default:
        return Verdict.FAILED;
    }
  }
}