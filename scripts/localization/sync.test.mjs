import assert from 'node:assert/strict';
import {mkdtempSync, writeFileSync, readFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
import test from 'node:test';

test('compiler empty UI labels are omitted while malformed keys are refused', () => {
  const directory = mkdtempSync(join(tmpdir(), 'palmier-localization-test-'));
  try {
    const input = join(directory, 'fixture.stringsdata');
    const output = join(directory, 'Localizable.strings');
    const sync = () => spawnSync(process.execPath, ['scripts/localization/sync.mjs', '--output', output, '--stringsdata', input], {encoding: 'utf8'});
    writeFileSync(input, JSON.stringify({tables: {Localizable: [{key: ''}, {key: 'Motion fixture title'}]}}));
    const result = sync();
    assert.equal(result.status, 0, result.stderr);
    assert.match(readFileSync(output, 'utf8'), /"Motion fixture title" = "Motion fixture title";/);
    assert.doesNotMatch(readFileSync(output, 'utf8'), /^"" =/m);
    writeFileSync(input, JSON.stringify({tables: {Localizable: [{key: null}]}}));
    assert.notEqual(sync().status, 0);
  } finally { rmSync(directory, {recursive: true, force: true}); }
});
