/**
 * 题目集校验器（spec 5.2.1-4/5/7、5.2.3，tasks.md 4.4）。
 * 解析用户选择的题目集文件内容，产出 DatasetValidationReport。
 *
 * 题目集文件格式约定（JSON 文本）：
 *   顶层为 JSON 数组，元素对象包含题面与参考答案：
 *     [{ "content": "题面", "referenceAnswer": "参考答案" }]
 *   兼容键名：题面 `question`、参考答案 `answer`。
 *   - 题面或参考答案为缺失/空串 → 记入 missingReferenceIndexes（调用方据此拒绝导入）；
 *   - 元素数量 > DATASET_CASE_LIMIT → 抛 DS_CASE_LIMIT_EXCEEDED；
 *   - 非 JSON / 顶层非数组 → 抛 DS_PARSE_FAILED，调用方保持原文件不变。
 */
import { DatasetCaseDraft, DatasetValidationReport } from '../../common/types/DomainTypes';
import { DATASET_CASE_LIMIT } from '../../common/types/Constants';
import { AppError } from '../../common/error/AppError';
import { ErrorCode } from '../../common/error/ErrorCode';

/** 原始题目对象（兼容两套键名） */
interface RawDatasetCase {
  content?: string;
  question?: string;
  referenceAnswer?: string;
  answer?: string;
}

function pickText(primary: string | undefined, fallback: string | undefined): string {
  if (typeof primary === 'string' && primary.trim().length > 0) {
    return primary.trim();
  }
  if (typeof fallback === 'string' && fallback.trim().length > 0) {
    return fallback.trim();
  }
  return '';
}

export class DatasetValidator {
  /** 解析并校验题目集内容；不修改任何外部状态 */
  static parse(fileName: string, content: string): DatasetValidationReport {
    let parsed: Object | null = null;
    try {
      parsed = JSON.parse(content) as Object;
    } catch (e) {
      throw new AppError(ErrorCode.DS_PARSE_FAILED, `文件「${fileName}」不是合法 JSON`);
    }
    if (parsed === null) {
      throw new AppError(ErrorCode.DS_PARSE_FAILED, `文件「${fileName}」内容为空`);
    }
    if (!Array.isArray(parsed)) {
      throw new AppError(ErrorCode.DS_PARSE_FAILED, `文件「${fileName}」顶层须为 JSON 数组`);
    }

    const items: Object[] = parsed as Object[];
    if (items.length > DATASET_CASE_LIMIT) {
      throw new AppError(ErrorCode.DS_CASE_LIMIT_EXCEEDED,
        `题目数量 ${items.length} 超出上限：${DATASET_CASE_LIMIT}`);
    }

    const cases: DatasetCaseDraft[] = [];
    const missingReferenceIndexes: number[] = [];
    for (let i = 0; i < items.length; i++) {
      const item: RawDatasetCase = items[i] as RawDatasetCase;
      const question: string = pickText(item.content, item.question);
      const answer: string = pickText(item.referenceAnswer, item.answer);
      if (question.length === 0 || answer.length === 0) {
        missingReferenceIndexes.push(i);
        continue;
      }
      cases.push({ content: question, referenceAnswer: answer });
    }

    return {
      fileName: fileName,
      fileUri: '',
      totalCount: items.length,
      validCount: cases.length,
      missingReferenceIndexes: missingReferenceIndexes,
      cases: cases
    };
  }
}