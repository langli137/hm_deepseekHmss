/**
 * 指标口径策略扩展点（design.md 2.1.3(4)、tasks.md 6.5）。
 * 抽象「指标计算」能力，默认实现为准确率/通过率/平均耗时/用量汇总。
 *
 * R1 替换点：上游 harness 若采用不同指标口径（如加权准确率、F1 等），
 * 只需新增 MetricStrategy 实现并在装配处替换 DefaultMetricStrategy，
 * 无需改动应用服务层（design.md 风险登记 R1）。
 */
import { CaseResult, Metrics, UsageSummary } from '../../common/types/DomainTypes';
import { MetricCalculator } from '../metric/MetricCalculator';

export interface MetricStrategy {
  /** 以用例明细为唯一数据源计算汇总指标 */
  compute(cases: CaseResult[], usage?: UsageSummary): Metrics;
}

/**
 * 默认指标口径实现（spec 5.4.1-1、4.2.4）。
 * 准确率 = passed / validJudged；通过率 = passed / total；
 * 平均耗时 = sum(elapsedMs) / total；无有效样本时派生指标为 null（spec 5.4.3-1）。
 */
export class DefaultMetricStrategy implements MetricStrategy {
  compute(cases: CaseResult[], usage?: UsageSummary): Metrics {
    return MetricCalculator.compute(cases, usage);
  }
}