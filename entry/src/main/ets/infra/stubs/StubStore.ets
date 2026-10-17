/**
 * RelationalStorePort 内存测试桩。仅测试环境使用，缓解 R2（无真机）。
 * 记录执行过的 SQL 供断言；查询默认返回空集，领域层测试可按需继承覆盖。
 */
import { ExecSpec, QuerySpec, TxContext } from '../../common/types/InfraTypes';
import { RelationalStorePort } from '../ports/RelationalStorePort';

class StubTxContext implements TxContext {
  private owner: StubStore;

  constructor(owner: StubStore) {
    this.owner = owner;
  }

  async query<T>(spec: QuerySpec): Promise<T[]> {
    return this.owner.query<T>(spec);
  }

  async execute(spec: ExecSpec): Promise<number> {
    return this.owner.execute(spec);
  }
}

export class StubStore implements RelationalStorePort {
  private executed: string[] = [];
  private queried: string[] = [];

  async transaction<T>(work: (tx: TxContext) => Promise<T>): Promise<T> {
    return work(new StubTxContext(this));
  }

  async query<T>(spec: QuerySpec): Promise<T[]> {
    this.queried.push(spec.sql);
    return [];
  }

  async execute(spec: ExecSpec): Promise<number> {
    this.executed.push(spec.sql);
    return 1;
  }

  executedSqls(): string[] {
    return this.executed;
  }

  queriedSqls(): string[] {
    return this.queried;
  }
}