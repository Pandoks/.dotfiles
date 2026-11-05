import type { Register } from 'claude-code';

// Off Claude models (RED-SNOW), run every subagent on the session's model.
export const register: Register = (on) => {
  on('agent.spawn', ($, e, next) =>
    e.parentModel.startsWith('claude-') ? next(e) : next({ ...e, model: e.parentModel }),
  );
};
