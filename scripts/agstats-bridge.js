#!/usr/bin/env node
'use strict';

// Use agstats' public library API once per refresh, instead of running several
// CLI commands that would each reread every transcript. Output contains only
// aggregates; no transcript text, commands, project paths or credentials.
const fs = require('fs');
const path = require('path');

function packageFromCli(cli) {
  const root = path.dirname(path.dirname(fs.realpathSync(cli)));
  const manifest = require(path.join(root, 'package.json'));
  if (manifest.name !== 'agstats') throw new Error('Not an agstats installation');
  return require(root);
}

function localDay(ms) {
  const date = new Date(ms);
  return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
}

function exportReport(api, now = Date.now()) {
  const start = new Date(now);
  start.setHours(0, 0, 0, 0);
  start.setDate(start.getDate() - 29);
  const from = start.getTime();
  const found = api.readers.readAll({ only: ['claude', 'codex'], sinceMs: from });
  const sessions = found.flatMap((entry) => entry.sessions || []);
  const byAgent = Object.fromEntries(['claude', 'codex'].map((agent) =>
    [agent, sessions.filter((session) => session.agent === agent)]));
  const intervals = Object.fromEntries(['claude', 'codex'].map((agent) =>
    [agent, api.metrics.hours.fromSessions(byAgent[agent])]));
  const daily = new Map();
  const models = { Claude: {}, Codex: {} };
  const sessionIds = { Claude: new Set(), Codex: new Set() };
  const toolNames = { Claude: {}, Codex: {} };

  function point(agent, timestamp) {
    const day = localDay(timestamp);
    if (day < from || timestamp > now) return null;
    const name = agent === 'claude' ? 'Claude' : 'Codex';
    const key = `${name}|${day}`;
    if (!daily.has(key)) daily.set(key, {
      agent: name, date: day / 1000, sessions: 0, turns: 0, tools: 0,
      failures: 0, inputTokens: 0, cachedTokens: 0, outputTokens: 0,
      taskDurationSeconds: 0, subagentSeconds: 0, longestRunSeconds: 0,
      parallelism: null, delegationPercent: null, hourlyEvents: {}
    });
    return daily.get(key);
  }

  for (const session of sessions) {
    const agent = session.agent === 'claude' ? 'Claude' : 'Codex';
    const main = session.parentId == null;
    let counted = false;
    const seenDays = new Set();
    for (const event of session.events) {
      const row = point(session.agent, event.t);
      if (!row) continue;
      if (main && !seenDays.has(row.date)) { row.sessions++; seenDays.add(row.date); counted = true; }
      if (event.tokens) {
        row.inputTokens += (event.tokens.in || 0) + (event.tokens.cacheRead || 0) + (event.tokens.cacheWrite || 0);
        row.cachedTokens += event.tokens.cacheRead || 0;
        row.outputTokens += event.tokens.out || 0;
      }
      if (!main || event.injected) continue;
      if (event.kind === 'user' && event.human) {
        row.turns++;
        const hour = new Date(event.t).getHours();
        row.hourlyEvents[hour] = (row.hourlyEvents[hour] || 0) + 1;
      }
      if (event.kind === 'tool_call') {
        row.tools++;
        const hour = new Date(event.t).getHours();
        row.hourlyEvents[hour] = (row.hourlyEvents[hour] || 0) + 1;
      }
      if (event.kind === 'assistant' && event.model) {
        models[agent][event.model] = (models[agent][event.model] || 0) + 1;
      }
    }
    if (counted) sessionIds[agent].add(session.id || session.file);
  }

  for (let day = new Date(from); day.getTime() <= now; day.setDate(day.getDate() + 1)) {
    const startMs = day.getTime();
    const endMs = new Date(day.getFullYear(), day.getMonth(), day.getDate() + 1).getTime();
    for (const [agent, name] of [['claude', 'Claude'], ['codex', 'Codex']]) {
      const stats = api.metrics.hours.summarize(intervals[agent], startMs, endMs);
      const tools = api.metrics.tools.summarize(byAgent[agent], startMs, endMs, { scope: 'main' });
      if (!stats.agentHours && !tools.total && !tools.totalErr) continue;
      const row = point(agent, startMs);
      row.taskDurationSeconds = stats.agentHours * 3600;
      row.subagentSeconds = stats.subagentHours * 3600;
      row.longestRunSeconds = stats.longestRunHours * 3600;
      row.parallelism = stats.wallHours ? stats.parallelism : null;
      row.delegationPercent = stats.agentHours ? stats.subagentHours / stats.agentHours * 100 : null;
      row.tools = tools.total;
      row.failures = tools.totalErr;
    }
  }

  const allTools = api.metrics.tools.summarize(sessions, from, now, { scope: 'main' });
  for (const row of allTools.rows) {
    const name = row.agent === 'claude' ? 'Claude' : 'Codex';
    toolNames[name][row.tool] = row.calls;
  }
  return {
    installed: Object.fromEntries(found.map((entry) => [entry.agent === 'claude' ? 'Claude' : 'Codex',
      !!entry.installed && !entry.error])),
    daily: [...daily.values()].sort((a, b) => a.date - b.date || a.agent.localeCompare(b.agent)),
    models, toolNames,
    sessions: Object.fromEntries(Object.entries(sessionIds).map(([name, ids]) => [name, ids.size]))
  };
}

if (require.main === module) {
  try {
    const api = packageFromCli(process.argv[2]);
    process.stdout.write(JSON.stringify(exportReport(api)));
  } catch (error) {
    process.stderr.write(`agstats bridge: ${error.message}\n`);
    process.exitCode = 1;
  }
}

module.exports = { exportReport, localDay };
