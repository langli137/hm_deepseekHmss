/**
 * FilePort 内存测试桩：以 URI 为键的内存文件系统，可预设选择结果。
 */
import { ExportResult } from '../../common/types/InfraTypes';
import { FilePort, PickFileOptions, PickedFile, SaveFileOptions } from '../ports/FilePort';

export class StubFile implements FilePort {
  private files: Map<string, string> = new Map<string, string>();
  private presetPick: PickedFile | null = null;
  private saveUriPrefix: string = 'file://stub/';

  setPresetPick(file: PickedFile | null): void {
    this.presetPick = file;
  }

  putFile(uri: string, content: string): void {
    this.files.set(uri, content);
  }

  async pickFile(options: PickFileOptions): Promise<PickedFile | null> {
    return this.presetPick;
  }

  async readText(uri: string): Promise<string> {
    const value: string | undefined = this.files.get(uri);
    return value === undefined ? '' : value;
  }

  async saveText(options: SaveFileOptions, content: string): Promise<ExportResult> {
    const uri: string = `${this.saveUriPrefix}${options.suggestedFileName}.${options.fileSuffix}`;
    this.files.set(uri, content);
    return { success: true, uri: uri, reason: '' };
  }

  async exists(uri: string): Promise<boolean> {
    return this.files.has(uri);
  }
}