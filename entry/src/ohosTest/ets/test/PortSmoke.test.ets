/**
 * 端口测试桩冒烟测试。验证 9 个端口桩均可实例化并完成基础调用，
 * 作为后续领域层单元测试的前置依赖（tasks.md 2.9）。
 */
import { describe, expect, it } from '@ohos/hypium';
import { StubStore } from '../../../main/ets/infra/stubs/StubStore';
import { StubPreferences } from '../../../main/ets/infra/stubs/StubPreferences';
import { StubCrypto } from '../../../main/ets/infra/stubs/StubCrypto';
import { StubModelClient, StubModelBehavior } from '../../../main/ets/infra/stubs/StubModelClient';
import { StubNotification } from '../../../main/ets/infra/stubs/StubNotification';
import { StubBackgroundTask } from '../../../main/ets/infra/stubs/StubBackgroundTask';
import { StubFile } from '../../../main/ets/infra/stubs/StubFile';
import { StubNetwork } from '../../../main/ets/infra/stubs/StubNetwork';
import { StubLogger } from '../../../main/ets/infra/stubs/StubLogger';
import { SseParser } from '../../../main/ets/infra/adapters/SseParser';
import { ChatChunk, ChatRequest, ChatResult } from '../../../main/ets/common/types/DomainTypes';
import { CancellationToken, ExecSpec, SecretRef } from '../../../main/ets/common/types/InfraTypes';

class NoopToken implements CancellationToken {
  cancelled: boolean = false;
  private callbacks: Array<() => void> = [];

  onCancel(callback: () => void): void {
    this.callbacks.push(callback);
  }

  cancel(): void {
    this.cancelled = true;
    for (let i = 0; i < this.callbacks.length; i++) {
      this.callbacks[i]();
    }
  }
}

export default function portSmokeTest() {
  describe('portSmokeTest', () => {
    it('stubs_can_be_instantiated', 0, () => {
      expect(new StubStore() !== null).assertTrue();
      expect(new StubPreferences() !== null).assertTrue();
      expect(new StubCrypto() !== null).assertTrue();
      expect(new StubModelClient() !== null).assertTrue();
      expect(new StubNotification() !== null).assertTrue();
      expect(new StubBackgroundTask() !== null).assertTrue();
      expect(new StubFile() !== null).assertTrue();
      expect(new StubNetwork() !== null).assertTrue();
      expect(new StubLogger() !== null).assertTrue();
    });

    it('stub_store_executes_spec', 0, async () => {
      const store: StubStore = new StubStore();
      const spec: ExecSpec = { sql: 'INSERT INTO evaluation_task(task_id) VALUES (?)', args: ['t1'] };
      const affected: number = await store.execute(spec);
      expect(affected).assertEqual(1);
      expect(store.executedSqls().length).assertEqual(1);
    });

    it('stub_crypto_round_trip', 0, async () => {
      const crypto: StubCrypto = new StubCrypto();
      const ref: SecretRef = await crypto.encryptSecret('sk-test-secret');
      const plain: string = await crypto.decryptSecret(ref);
      expect(plain).assertEqual('sk-test-secret');
      await crypto.removeSecret(ref);
      expect(crypto.contains(ref)).assertFalse();
    });

    it('stub_model_client_streams_chunks', 0, async () => {
      const client: StubModelClient = new StubModelClient(StubModelBehavior.SUCCESS, ['A', 'B', 'C']);
      const request: ChatRequest = {
        endpoint: 'https://example.com/v1/chat/completions',
        targetModel: 'deepseek-chat',
        secret: 'sk-test',
        messages: [{ role: 'user', content: 'hi' }],
        temperature: 0.7,
        maxOutputTokens: 16,
        stream: true
      };
      let streamed: string = '';
      const result: ChatResult = await client.streamChat(request, (chunk: ChatChunk) => {
        streamed += chunk.delta;
      }, new NoopToken());
      expect(streamed).assertEqual('ABC');
      expect(result.content).assertEqual('ABC');
    });

    it('sse_parser_handles_done_mark', 0, () => {
      const parser: SseParser = new SseParser();
      const out: string[] = parser.feed('data: {"a":1}\n\ndata: [DONE]\n\n');
      expect(out.length).assertEqual(1);
      expect(parser.isDone()).assertTrue();
    });
  });
}