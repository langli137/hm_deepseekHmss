/**
 * 文件访问端口。对齐 tasks.md 2.7：选择文件、读取、保存、存在性判断。
 * 导入题目集经文件选择器读取；导出报告经保存选择器写入；空间不足向上抛 REPORT_EXPORT_FAILED。
 */
import { ExportResult } from '../../common/types/InfraTypes';

/** 文件选择参数 */
export interface PickFileOptions {
  /** 允许的后缀，如 ['txt', 'json']；空数组表示不过滤 */
  fileSuffixFilters: string[];
  /** 最多可选择数量 */
  maxCount: number;
}

/** 用户选中的文件 */
export interface PickedFile {
  uri: string;
  name: string;
}

/** 文件保存参数 */
export interface SaveFileOptions {
  suggestedFileName: string;
  fileSuffix: string;
}

export interface FilePort {
  /** 拉起文件选择器；用户取消时返回 null */
  pickFile(options: PickFileOptions): Promise<PickedFile | null>;
  /** 按 URI 读取文本内容 */
  readText(uri: string): Promise<string>;
  /** 经保存选择器确定目标 URI 后写入文本，返回导出结果 */
  saveText(options: SaveFileOptions, content: string): Promise<ExportResult>;
  /** 判断 URI 指向的文件是否存在 */
  exists(uri: string): Promise<boolean>;
}