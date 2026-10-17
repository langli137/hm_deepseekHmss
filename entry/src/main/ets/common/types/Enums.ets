/**
 * 全局枚举定义。对齐 design.md 2.3.2 与 tasks.md 1.5。
 */

/** 评测任务主状态（五值，spec 6.2.6） */
export enum TaskStatus {
  PENDING = 'PENDING',
  RUNNING = 'RUNNING',
  COMPLETED = 'COMPLETED',
  FAILED = 'FAILED',
  TERMINATED = 'TERMINATED'
}

/** 运行中子态：暂停被设计为"运行中"的子态，避免与五值主状态冲突 */
export enum ExecutionFlag {
  EXECUTING = 'EXECUTING',
  PAUSED = 'PAUSED'
}

/** 用例判定结果（spec 6.3.5） */
export enum Verdict {
  PASSED = 'PASSED',
  FAILED = 'FAILED',
  TIMEOUT = 'TIMEOUT',
  ERROR = 'ERROR'
}

/** 运行记录状态（spec 6.4.6） */
export enum RunRecordStatus {
  COMPLETED = 'COMPLETED',
  FAILED = 'FAILED',
  TERMINATED = 'TERMINATED'
}

/** 判定方式（design 2.1.3 扩展点） */
export enum JudgeMode {
  EXACT_MATCH = 'EXACT_MATCH',
  CONTAINS = 'CONTAINS',
  REFEREE_MODEL = 'REFEREE_MODEL'
}

/** 服务配置有效性状态（spec 5.1.3-2 密钥失效） */
export enum ConfigStatus {
  VALID = 'VALID',
  INVALID = 'INVALID'
}

/** 日志级别（spec 4.4.1） */
export enum LogLevel {
  DEBUG = 'DEBUG',
  INFO = 'INFO',
  WARN = 'WARN',
  ERROR = 'ERROR'
}

/** 结构化日志事件类型（spec 4.4.1） */
export enum LogEvent {
  CONFIG_SAVE = 'CONFIG_SAVE',
  CONFIG_TEST = 'CONFIG_TEST',
  TASK_START = 'TASK_START',
  CASE_FINISHED = 'CASE_FINISHED',
  PAUSE = 'PAUSE',
  RESUME = 'RESUME',
  TERMINATE = 'TERMINATE',
  ARCHIVE = 'ARCHIVE',
  CRASH = 'CRASH',
  ERROR = 'ERROR'
}

/** 任务中断原因（spec 5.3.3） */
export enum InterruptReason {
  NETWORK_LOST = 'NETWORK_LOST',
  USER_PAUSED = 'USER_PAUSED',
  RATE_LIMITED = 'RATE_LIMITED',
  APP_RECOVERED = 'APP_RECOVERED'
}