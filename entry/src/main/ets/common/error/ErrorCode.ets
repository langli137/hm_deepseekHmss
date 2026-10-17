/**
 * 统一错误码枚举。对齐 design.md 2.2.1 ErrorCode（18 个）。
 */
export enum ErrorCode {
  // 模型服务与认证（A）
  CFG_MISSING_FIELD = 'CFG_MISSING_FIELD',
  CFG_DUPLICATE_NAME = 'CFG_DUPLICATE_NAME',
  CFG_INVALID_ENDPOINT = 'CFG_INVALID_ENDPOINT',
  CFG_CONNECT_FAILED = 'CFG_CONNECT_FAILED',
  CFG_SECRET_INVALID = 'CFG_SECRET_INVALID',
  // 网络
  NET_UNAVAILABLE = 'NET_UNAVAILABLE',
  // 题目集（B）
  DS_PARSE_FAILED = 'DS_PARSE_FAILED',
  DS_CASE_LIMIT_EXCEEDED = 'DS_CASE_LIMIT_EXCEEDED',
  DS_MISSING_REFERENCE = 'DS_MISSING_REFERENCE',
  // 任务（B/C）
  TASK_DUPLICATE_NAME = 'TASK_DUPLICATE_NAME',
  TASK_INCOMPLETE_CONFIG = 'TASK_INCOMPLETE_CONFIG',
  TASK_PARAM_OUT_OF_RANGE = 'TASK_PARAM_OUT_OF_RANGE',
  TASK_ALREADY_RUNNING = 'TASK_ALREADY_RUNNING',
  TASK_NO_VALID_CASE = 'TASK_NO_VALID_CASE',
  // 运行记录（E）
  RECORD_LIMIT_REACHED = 'RECORD_LIMIT_REACHED',
  RECORD_BUSY_CANNOT_DELETE = 'RECORD_BUSY_CANNOT_DELETE',
  // 报告（D）
  REPORT_EXPORT_FAILED = 'REPORT_EXPORT_FAILED',
  // 设置（F）
  SETTINGS_BUSY_TASK_RUNNING = 'SETTINGS_BUSY_TASK_RUNNING',
  // 未知错误
  UNKNOWN_ERROR = 'UNKNOWN_ERROR'
}

/** 错误码 → 用户可读中文提示（页面层统一映射，spec 各章"用户感知"） */
export class ErrorMessages {
  static of(code: ErrorCode, detail: string = ''): string {
    let base: string;
    switch (code) {
      case ErrorCode.CFG_MISSING_FIELD:
        base = '存在必填项未填写';
        break;
      case ErrorCode.CFG_DUPLICATE_NAME:
        base = '配置名称已存在';
        break;
      case ErrorCode.CFG_INVALID_ENDPOINT:
        base = '服务地址不合法';
        break;
      case ErrorCode.CFG_CONNECT_FAILED:
        base = '连接失败';
        break;
      case ErrorCode.CFG_SECRET_INVALID:
        base = '密钥无效，请重新配置';
        break;
      case ErrorCode.NET_UNAVAILABLE:
        base = '网络不可用，请检查网络设置';
        break;
      case ErrorCode.DS_PARSE_FAILED:
        base = '题目集解析失败，请检查文件格式';
        break;
      case ErrorCode.DS_CASE_LIMIT_EXCEEDED:
        base = '题目数量超出上限';
        break;
      case ErrorCode.DS_MISSING_REFERENCE:
        base = '题目集缺少参考答案';
        break;
      case ErrorCode.TASK_DUPLICATE_NAME:
        base = '任务名称已存在';
        break;
      case ErrorCode.TASK_INCOMPLETE_CONFIG:
        base = '任务配置不完整';
        break;
      case ErrorCode.TASK_PARAM_OUT_OF_RANGE:
        base = '执行参数超出允许范围';
        break;
      case ErrorCode.TASK_ALREADY_RUNNING:
        base = '已有任务正在运行';
        break;
      case ErrorCode.TASK_NO_VALID_CASE:
        base = '无可用题目';
        break;
      case ErrorCode.RECORD_LIMIT_REACHED:
        base = '运行记录已达上限，请清理后重试';
        break;
      case ErrorCode.RECORD_BUSY_CANNOT_DELETE:
        base = '记录正在使用中，无法删除';
        break;
      case ErrorCode.REPORT_EXPORT_FAILED:
        base = '导出失败';
        break;
      case ErrorCode.SETTINGS_BUSY_TASK_RUNNING:
        base = '请先终止运行中的任务';
        break;
      default:
        base = '操作失败';
        break;
    }
    return detail.length > 0 ? `${base}：${detail}` : base;
  }
}