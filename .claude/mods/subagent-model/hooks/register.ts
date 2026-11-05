import type { Register } from 'claude-code';

const limit = 1000;

export const register: Register = (on) => {
  on('agent.spawn', async ($, e, next) => {
    if (e.parentModel.startsWith('claude-')) return next(e);
    // Resume only subagents started off Claude; others may keep a Claude model.
    if (e.resume) {
      return (await $.store.get(e.resume.agentId))
        ? next(e)
        : { deny: 'it may run on a Claude model; start a new subagent instead' };
    }
    const result = await next({ ...e, model: e.parentModel });
    if (result.deny === undefined && result.agentId) {
      await $.store.set(result.agentId, true);
      for (const key of (await $.store.keys()).slice(0, -limit)) await $.store.delete(key);
    }
    return result;
  }).catch(($, e, next) => (next.called ? next(e) : { deny: 'subagent-model mod failed' }));
};
