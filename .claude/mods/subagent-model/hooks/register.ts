import type { Register } from 'claude-code';

export const register: Register = (on) => {
  // Agents started off Claude; resuming any other one off Claude would keep its Claude model.
  const started = new Set<string>();
  on('agent.spawn', async ($, e, next) => {
    if (e.parentModel.startsWith('claude-')) return next(e);
    if (e.resume) {
      return started.has(e.resume.agentId)
        ? next(e)
        : { deny: 'it may run on a Claude model; start a new subagent instead' };
    }
    const result = await next({ ...e, model: e.parentModel });
    if (result.deny === undefined && result.agentId) started.add(result.agentId);
    return result;
  }).catch(($, e, next) => (next.called ? next(e) : { deny: 'subagent-model mod failed' }));
};
