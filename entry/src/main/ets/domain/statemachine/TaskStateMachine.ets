/**
 * 任务生命周期状态机（design.md 2.1.3(1)，tasks.md 5.1）。
 * 主状态五值：PENDING/RUNNING/COMPLETED/FAILED/TERMINATED（spec 6.2.6）。
 * 子态 ExecutionFlag：EXECUTING/PAUSED，仅 RUNNING 主状态下旁路迁移（design.md 2.1.3(1)）。
 * 暂停被设计为 RUNNING 的子态，保证仍占用单例名额（spec 5.3.1-6、4.1.5）。
 */
import { ExecutionFlag, TaskStatus } from '../../common/types/Enums';
import { AppError } from '../../common/error/AppError';
import { ErrorCode } from '../../common/error/ErrorCode';

/** 合法主状态迁移：from → 允许的 to 集合 */
function allowedTransitions(from: TaskStatus): TaskStatus[] {
  switch (from) {
    case TaskStatus.PENDING:
      return [TaskStatus.RUNNING, TaskStatus.TERMINATED];
    case TaskStatus.RUNNING:
      return [TaskStatus.COMPLETED, TaskStatus.FAILED, TaskStatus.TERMINATED];
    default:
      return [];
  }
}

/** 合法子态迁移：仅 RUNNING 主状态下 EXECUTING ↔ PAUSED */
function allowedFlagTransitions(from: ExecutionFlag): ExecutionFlag[] {
  switch (from) {
    case ExecutionFlag.EXECUTING:
      return [ExecutionFlag.PAUSED];
    case ExecutionFlag.PAUSED:
      return [ExecutionFlag.EXECUTING];
    default:
      return [];
  }
}

export class TaskStateMachine {
  /** 判断主状态迁移是否合法 */
  static isLegalTransition(from: TaskStatus, to: TaskStatus): boolean {
    const allowed: TaskStatus[] = allowedTransitions(from);
    return allowed.indexOf(to) >= 0;
  }

  /** 断言主状态迁移合法；非法则抛 AppError */
  static assertTransition(from: TaskStatus, to: TaskStatus): void {
    if (!TaskStateMachine.isLegalTransition(from, to)) {
      throw new AppError(ErrorCode.TASK_ALREADY_RUNNING,
        `非法状态迁移：${from} → ${to}`);
    }
  }

  /** 判断子态迁移是否合法（仅 RUNNING 主状态下 EXECUTING ↔ PAUSED） */
  static isLegalFlagTransition(from: ExecutionFlag, to: ExecutionFlag): boolean {
    const allowed: ExecutionFlag[] = allowedFlagTransitions(from);
    return allowed.indexOf(to) >= 0;
  }

  /** 断言子态迁移合法；非法则抛 AppError */
  static assertFlagTransition(from: ExecutionFlag, to: ExecutionFlag): void {
    if (!TaskStateMachine.isLegalFlagTransition(from, to)) {
      throw new AppError(ErrorCode.TASK_ALREADY_RUNNING,
        `非法子态迁移：${from} → ${to}`);
    }
  }

  /** 判断是否为终态（不可再迁移） */
  static isTerminal(status: TaskStatus): boolean {
    return status === TaskStatus.COMPLETED
      || status === TaskStatus.FAILED
      || status === TaskStatus.TERMINATED;
  }
}