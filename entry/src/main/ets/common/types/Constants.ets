/**
 * 应用内置常量与允许区间规则（spec 6.2.5「取值区间由应用内置规则确定」）。
 * 这些数值为应用内置默认规则，可在评审阶段调整，不影响接口契约。
 */

/** 模型版本号：写入快照与运行记录，支撑旧数据兼容（spec 4.5.3） */
export const MODEL_VERSION: number = 1;

/** 题目集题目数量上限（spec 5.2.3-2） */
export const DATASET_CASE_LIMIT: number = 1000;

/** 运行记录存储上限默认值（spec 5.5.1-4、6.4.7） */
export const DEFAULT_RECORD_LIMIT: number = 1000;

/** 限流重试次数上限（spec 5.3.3-3） */
export const DEFAULT_MAX_RETRY: number = 3;

/** 任务名称长度上限（spec 6.2.2） */
export const TASK_NAME_MAX_LENGTH: number = 50;

/** 配置名称长度上限（spec 6.1.2） */
export const CONFIG_NAME_MAX_LENGTH: number = 50;

/** 目标模型名称长度上限（spec 6.1.5） */
export const TARGET_MODEL_MAX_LENGTH: number = 100;

// ============ 执行参数允许区间（spec 6.2.5） ============

export const TEMPERATURE_MIN: number = 0.0;
export const TEMPERATURE_MAX: number = 2.0;

export const MAX_OUTPUT_TOKENS_MIN: number = 1;
export const MAX_OUTPUT_TOKENS_MAX: number = 8192;

export const CONCURRENCY_MIN: number = 1;
export const CONCURRENCY_MAX: number = 4;

export const TIMEOUT_MS_MIN: number = 1000;
export const TIMEOUT_MS_MAX: number = 300000;