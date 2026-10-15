// Lets Node run the Worker's code in tests. `cloudflare:workers` only exists
// inside Cloudflare's runtime, so tests swap in a stand-in that keeps the
// storage handle the same way the real base class does.
import { registerHooks } from 'node:module';

const stub = 'export class DurableObject { constructor(ctx, env) { this.ctx = ctx; this.env = env; } }';

registerHooks({
  resolve: (specifier, context, next) => specifier === 'cloudflare:workers'
    ? { url: `data:text/javascript,${encodeURIComponent(stub)}`, shortCircuit: true }
    : next(specifier, context),
});
