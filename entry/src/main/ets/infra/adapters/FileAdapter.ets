/**
 * 文件访问适配器。基于 @ohos.file.picker + @ohos.file.fs（tasks.md 2.7）。
 * 按 URI 读取与写入；捕获存储空间不足并向上抛出（spec 5.4.3）。
 */
import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import { ExportResult } from '../../common/types/InfraTypes';
import { AppError } from '../../common/error/AppError';
import { ErrorCode } from '../../common/error/ErrorCode';
import { FilePort, PickFileOptions, PickedFile, SaveFileOptions } from '../ports/FilePort';

const ERR_NO_SPACE: number = 13900025;

interface FsError {
  code?: number;
  message?: string;
}

function isNoSpace(e: Object): boolean {
  const err = e as FsError;
  if (err === undefined) {
    return false;
  }
  if (err.code === ERR_NO_SPACE) {
    return true;
  }
  const msg: string = err.message !== undefined ? err.message : '';
  return msg.includes('No space') || msg.includes('space');
}

function fileNameOf(uri: string): string {
  const slash: number = uri.lastIndexOf('/');
  const raw: string = slash >= 0 ? uri.substring(slash + 1) : uri;
  try {
    return decodeURIComponent(raw);
  } catch (e) {
    return raw;
  }
}

export class FileAdapter implements FilePort {
  private context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
  }

  async pickFile(options: PickFileOptions): Promise<PickedFile | null> {
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(this.context);
    const selectOptions: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    selectOptions.maxSelectNumber = options.maxCount;
    if (options.fileSuffixFilters.length > 0) {
      const filters: string[] = [];
      for (let i = 0; i < options.fileSuffixFilters.length; i++) {
        const suffix: string = options.fileSuffixFilters[i];
        filters.push(suffix.startsWith('.') ? suffix : `.${suffix}`);
      }
      selectOptions.fileSuffixFilters = filters;
    }
    const uris: string[] = await documentPicker.select(selectOptions);
    if (uris === undefined || uris.length === 0) {
      return null;
    }
    return { uri: uris[0], name: fileNameOf(uris[0]) };
  }

  async readText(uri: string): Promise<string> {
    return fs.readTextSync(uri);
  }

  async saveText(options: SaveFileOptions, content: string): Promise<ExportResult> {
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(this.context);
    const saveOptions: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    saveOptions.newFileNames = [`${options.suggestedFileName}.${options.fileSuffix}`];
    const uris: string[] = await documentPicker.save(saveOptions);
    if (uris === undefined || uris.length === 0) {
      return { success: false, uri: '', reason: '用户取消保存' };
    }
    const uri: string = uris[0];
    try {
      const file: fs.File = fs.openSync(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, content);
      } finally {
        fs.closeSync(file);
      }
      return { success: true, uri: uri, reason: '' };
    } catch (e) {
      if (isNoSpace(e as Object)) {
        throw new AppError(ErrorCode.REPORT_EXPORT_FAILED, '存储空间不足');
      }
      throw new AppError(ErrorCode.REPORT_EXPORT_FAILED, '写入文件失败');
    }
  }

  async exists(uri: string): Promise<boolean> {
    try {
      return fs.accessSync(uri);
    } catch (e) {
      return false;
    }
  }
}