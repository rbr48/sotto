import { loadConfig } from './config.js';
import { log } from './log.js';
import { createRelayServer } from './server.js';

const config = loadConfig();
const server = createRelayServer(config);
const port = await server.listen();
log.info(`listening on port ${port}`);

const shutdown = (): void => {
  log.info('shutting down');
  void server.close().then(() => process.exit(0));
};
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
