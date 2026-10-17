/**
 * 领域类型定义。对齐 design.md 2.3.2 领域类图与 2.2.2 接口清单。
 * 说明：领域对象按设计不携带存储技术字段；为落地实现，这里显式携带持久化标识
 * （configId/taskId/recordId/caseId）与 createdAt 等技术字段，属对 design.md 的有意落地性补充。
 */
import { ConfigStatus, ExecutionFlag, InterruptReason, JudgeMode, RunRecordStatus, TaskStatus, Verdict } from './Enums';
import { SecretRef } from './InfraTypes';

// ============ 模型服务与认证管理（spec 5.1） ============

export interface ModelServiceConfig {
  configId: string;
  name: string;
  endpoint: string;
  targetModel: string;
  isDefault: boolean;
  status: ConfigStatus;
  secretRef: SecretRef;
  createdAt: number;
}

export interface ServiceConfigDraft {
  configId?: string;
  name: string;
  endpoint: string;
  targetModel: string;
  secret: string;
  isDefault: boolean;
}

export interface ConnectionTestResult {
  success: boolean;
  reason: string;
}

// ============ 评测任务配置（spec 5.2） ============

export interface RunParameters {
  temperature: number;
  maxOutputTokens: number;
  concurrency: number;
  timeoutMs: number;
  judgeMode: JudgeMode;
}

export interface DatasetCaseDraft {
  content: string;
  referenceAnswer: string;
}

export interface DatasetValidationReport {
  fileName: string;
  fileUri: string;
  totalCount: number;
  validCount: number;
  missingReferenceIndexes: number[];
  cases: DatasetCaseDraft[];
}

export interface Dataset {
  datasetId: string;
  name: string;
  sourceUri: string;
  totalCount: number;
  validCount: number;
  importedAt: number;
}

export interface CaseSnapshot {
  seq: number;
  content: string;
  referenceAnswer: string;
}

export interface DatasetSnapshot {
  modelVersion: number;
  name: string;
  cases: CaseSnapshot[];
}

export interface TaskConfigSnapshot {
  modelVersion: number;
  params: RunParameters;
  targetModel: string;
  configName: string;
}

export interface EvaluationTask {
  taskId: string;
  name: string;
  configId: string;
  datasetUri: string;
  params: RunParameters;
  status: TaskStatus;
  flag: ExecutionFlag;
  snapshot?: TaskConfigSnapshot;
  dataset?: DatasetSnapshot;
  createdAt: number;
}

export interface TaskConfigDraft {
  name: string;
  configId: string;
  datasetUri: string;
  params: RunParameters;
}

// ============ 评测结果与指标（spec 5.4） ============

export interface UsageSummary {
  promptTokens: number;
  completionTokens: number;
  totalTokens: number;
}

export interface CaseResult {
  caseId: string;
  taskId: string;
  seq: number;
  content: string;
  referenceAnswer: string;
  modelAnswer: string;
  verdict: Verdict;
  elapsedMs: number;
}

export interface CaseResultFilter {
  onlyFailed: boolean;
}

export interface Metrics {
  accuracy: number | null;
  passRate: number | null;
  avgElapsedMs: number | null;
  usage: UsageSummary;
  computed: boolean;
}

export interface MetricsComparison {
  recordIds: string[];
  metricNames: string[];
  values: Array<Array<number | null>>;
}

// ============ 运行记录（spec 5.5） ============

export interface RunRecord {
  recordId: string;
  taskId: string;
  taskName: string;
  targetModel: string;
  status: RunRecordStatus;
  startedAt: number;
  endedAt: number;
  modelVersion: number;
  datasetUri: string;
  metrics: Metrics;
  corrupted: boolean;
}

export interface RunRecordQuery {
  nameKeyword?: string;
  targetModel?: string;
  status?: RunRecordStatus;
}

// ============ 应用设置（spec 5.6） ============

export interface AppSettings {
  defaultParams: RunParameters;
  notificationEnabled: boolean;
  recordLimit: number;
}

// ============ 执行进度与订阅（spec 5.3） ============

export interface ExecutionProgress {
  taskId: string;
  status: TaskStatus;
  flag: ExecutionFlag;
  completedCount: number;
  totalCount: number;
  watermarkSeq: number;
  streamingText: string;
}

export interface ExecutionObserver {
  onProgress: (progress: ExecutionProgress) => void;
  onCaseFinished: (result: CaseResult) => void;
  onFinished: (recordId: string) => void;
  onInterrupted: (reason: InterruptReason) => void;
}

// ============ 模型服务协议类型（OpenAI 兼容，A3） ============

export interface ChatMessage {
  role: string;
  content: string;
}

export interface ChatRequest {
  endpoint: string;
  targetModel: string;
  secret: string;
  messages: ChatMessage[];
  temperature: number;
  maxOutputTokens: number;
  stream: boolean;
}

export interface ChatChunk {
  delta: string;
}

export interface ChatResult {
  content: string;
  usage: UsageSummary;
  finishReason: string;
}