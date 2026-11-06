import type { Register } from 'claude-code';

const maxStoredAgents = 1000;

export const register: Register = (on) => {
  on('agent.spawn', async (claudeCode, spawn, next) => {
    if (spawn.parentModel.startsWith('claude-')) return next(spawn);

    if (spawn.resume) {
      const startedOffClaude = await claudeCode.store.get(spawn.resume.agentId);
      return startedOffClaude
        ? next(spawn)
        : { deny: 'it may run on a Claude model; start a new subagent instead' };
    }

    const spawned = await next({ ...spawn, model: spawn.parentModel });

    if (spawned.deny === undefined && spawned.agentId && !spawned.model.startsWith('claude-')) {
      await claudeCode.store.set(spawned.agentId, true);
      const oldAgentIds = (await claudeCode.store.keys()).slice(0, -maxStoredAgents);
      for (const agentId of oldAgentIds) await claudeCode.store.delete(agentId);
    }

    return spawned;
  }).catch((_claudeCode, spawn, next) =>
    next.called ? next(spawn) : { deny: 'subagent-model mod failed' },
  );
};
