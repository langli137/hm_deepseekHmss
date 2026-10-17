/**
 * 指标计算器（spec 5.4.1-1、4.2.4，tasks.md 6.1）。
 * 以用例明细为唯一数据源，确定性计算准确率、通过率、平均耗时与用量汇总。
 * 无有效判定样本时（全部失败或超时）派生指标返回 null（spec 5.4.3-1）。
 */
import { CaseResult, Metrics, UsageSummary } from '../../common/types/DomainTypes';
import { Verdict } from '../../common/types/Enums';

export class MetricCalculator {
  /**
   * 确定性指标聚合。
   * - total = cases.length
   * - validJudged = count(verdict == PASSED || verdict == FAILED)
   * - passed = count(verdict == PASSED)
   * - accuracy = validJudged > 0 ? passed / validJudged : null
   * - passRate = total > 0 ? passed / total : null
   * - avgElapsedMs = total > 0 ? sum(elapsedMs) / total : null
   * - usage = usage ?? { promptTokens: 0, completionTokens: 0, totalTokens: 0 }
   * - computed = true（终态计算完成）
   */
  static compute(cases: CaseResult[], usage?: UsageSummary): Metrics {
    const total: number = cases.length;
    let validJudged: number = 0;
    let passed: number = 0;
    let sumElapsedMs: number = 0;

    for (let i = 0; i < cases.length; i++) {
      const c: CaseResult = cases[i];
      sumElapsedMs += c.elapsedMs;
      if (c.verdict === Verdict.PASSED || c.verdict === Verdict.FAILED) {
        validJudged += 1;
      }
      if (c.verdict === Verdict.PASSED) {
        passed += 1;
      }
    }

    const accuracy: number | null = validJudged > 0 ? passed / validJudged : null;
    const passRate: number | null = total > 0 ? passed / total : null;
    const avgElapsedMs: number | null = total > 0 ? sumElapsedMs / total : null;

    const finalUsage: UsageSummary = usage !== undefined
      ? usage
      : { promptTokens: 0, completionTokens: 0, totalTokens: 0 };

    return {
      accuracy: accuracy,
      passRate: passRate,
      avgElapsedMs: avgElapsedMs,
      usage: finalUsage,
      computed: true
    };
  }
}