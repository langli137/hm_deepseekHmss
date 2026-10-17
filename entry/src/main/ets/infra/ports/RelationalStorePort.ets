/**
 * 本地关系型存储端口。对齐 design.md 2.2.2(G)。
 * 事务内查询与写入共用同一连接，保证"用例结果 + 进度水位线"的原子提交。
 */
import { ExecSpec, QuerySpec, TxContext } from '../../common/types/InfraTypes';

export interface RelationalStorePort {
  /** 在单个事务中执行工作单元；work 抛错时整体回滚 */
  transaction<T>(work: (tx: TxContext) => Promise<T>): Promise<T>;
  /** 查询并返回结果行数组（结果集在适配器内关闭） */
  query<T>(spec: QuerySpec): Promise<T[]>;
  /** 执行写入语句，返回受影响行数 */
  execute(spec: ExecSpec): Promise<number>;
}