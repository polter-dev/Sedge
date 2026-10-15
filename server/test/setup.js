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

// /api/attest only trusts Apple's root, and tests can't get a certificate
// Apple signed. This lets a test set `globalThis.TEST_ROOT` to its own root.
// It changes the code only as the tests load it; the deployed file is untouched.
registerHooks({
  load(url, context, next) {
    const out = next(url, context);
    if (url.endsWith('/src/attest.js')) {
      out.source = String(out.source).replace('root = APPLE_ROOT', 'root = globalThis.TEST_ROOT ?? APPLE_ROOT');
    }
    return out;
  },
});
