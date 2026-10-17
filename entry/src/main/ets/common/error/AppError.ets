/**
 * 统一错误对象。对齐 design.md 2.2.1：所有接口失败时抛出 AppError，
 * 由页面层统一映射为可读提示。
 */
import { ErrorCode, ErrorMessages } from './ErrorCode';

export class AppError extends Error {
  code: ErrorCode;
  detail: string;

  constructor(code: ErrorCode, detail: string = '') {
    super(ErrorMessages.of(code, detail));
    this.name = 'AppError';
    this.code = code;
    this.detail = detail;
  }

  /** 面向用户的提示文案 */
  userMessage(): string {
    return ErrorMessages.of(this.code, this.detail);
  }
}

/** 判断任意异常是否为 AppError */
export function asAppError(e: Object, fallback: ErrorCode): AppError {
  if (e instanceof AppError) {
    return e;
  }
  const msg: string = e instanceof Error ? e.message : String(e);
  return new AppError(fallback, msg);
}