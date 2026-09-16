import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { ConfigError } from '../../src/config/index.js';
import { composeSystemPrompt, loadSystemPrompt } from '../../src/prompts/load.js';

test('loads the packaged Chinese system prompt', () => {
  const text = loadSystemPrompt();
  assert.match(text, /LinguaCast 内容研究助手/);
  assert.match(text, /不得伪造搜索结果/);
  assert.match(text, /Apple Podcasts/);
  assert.match(text, /Few-shot：时效性/);
  assert.match(text, /sourceIds.*sr_01YTAAA11111/s);
  assert.match(text, /系统会在本提示开头提供今天的日期/);
  assert.match(text, /调用 `save_research_report` 之后不要再把同一份报告完整复述一遍/);
  assert.match(text, /后续消息是对同一主题的追问/);
  assert.doesNotMatch(text, /Help the user find English-learning/);
});

test('ASSISTANT_SYSTEM_PROMPT_PATH override is used when present', () => {
  const root = mkdtempSync(join(tmpdir(), 'assistant-prompt-'));
  const path = join(root, 'systemprompt.txt');
  writeFileSync(path, '# custom prompt\nDo not search unless asked.\n', 'utf8');
  assert.equal(loadSystemPrompt(path), '# custom prompt\nDo not search unless asked.');
});

test('missing override file names ASSISTANT_SYSTEM_PROMPT_PATH', () => {
  try {
    loadSystemPrompt(join(tmpdir(), 'missing-systemprompt.txt'));
    assert.fail('expected ConfigError');
  } catch (error) {
    assert.ok(error instanceof ConfigError);
    assert.equal(error.variable, 'ASSISTANT_SYSTEM_PROMPT_PATH');
  }
});

test('composeSystemPrompt prepends the current calendar date', () => {
  const composed = composeSystemPrompt('# custom prompt', new Date('2026-08-31T05:32:00Z'));
  assert.match(composed, /今天是 2026-08-31（星期一）/);
  assert.match(composed, /当前公历年份为 2026/);
  assert.match(composed, /# custom prompt/);
  assert.ok(composed.startsWith('# 运行时上下文'));
});
