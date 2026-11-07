#!/usr/bin/env node
'use strict';

// Compatibility entry point for existing LaunchAgents. Monitor alone collects
// quota; this process only consumes its account-validated loopback snapshot.
const agent = require('./agent.cjs');
const { installSharedQuotaAdapter } = require('./shared-quota.cjs');

async function main() {
  installSharedQuotaAdapter(agent.AppServerClient);
  return agent.main();
}

module.exports = { installSharedQuotaAdapter, main };

if (require.main === module) {
  main().catch(() => {
    process.stderr.write('Shared quota appearance agent stopped. Check Monitor and run the health check.\n');
    process.exitCode = 1;
  });
}
