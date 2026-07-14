import { Server } from 'http';

import { LogOrigin, MaybeNumber } from 'ontime-types';

import * as appState from '../../services/app-state-service/AppStateService.js';
import { config } from '../../setup/config.js';
import { envPort, isDocker, isOntimeCloud } from '../../setup/environment.js';
import { shouldCrashDev } from '../../utils/development.js';
import { logger } from '../Logger.js';
import { isAddressInfo, isPortInUseError } from './PortManager.utils.js';

// Bind to the IPv6 wildcard so the server is reachable over IPv6 (e.g. mesh
// networks, or a reverse proxy that can only reach it via IPv6) as well as
// IPv4. On Linux `::` dual-stacks by default, so IPv4 clients (localhost, LAN)
// still connect via IPv4-mapped addresses. Binding to '0.0.0.0' instead would
// listen on IPv4 only.
const bindHost = '::';

class PortManager {
  private static port: number;
  private static pendingRestart = false;
  private static newPort: MaybeNumber = null;

  public getPort() {
    return {
      port: PortManager.port,
      pendingRestart: PortManager.pendingRestart,
      newPort: PortManager.newPort,
    };
  }

  /**
   * marks that a port change is requested and will be applied on next restart
   * @throws if trying to change port inside docker
   * @param newPort
   * @returns {void}
   */
  public changePort(newPort: number): void {
    if (isDocker) throw new Error('Can not change port when running inside docker');
    if (PortManager.port === newPort) return;
    PortManager.newPort = newPort;
    PortManager.pendingRestart = true;
  }

  public migratePortFromProjectFile(port: number) {
    shouldCrashDev(
      PortManager.port !== undefined,
      'this function should not be called after `PortManager.port` has been initialized',
    );
    appState.setServerPort(port);
  }

  public async shutdown() {
    if (PortManager.pendingRestart && PortManager.newPort != null) {
      logger.info(
        LogOrigin.Server,
        `A port change to ${PortManager.newPort} is pending and will take effect on next start`,
      );
      await appState.setServerPort(PortManager.newPort);
    }
  }

  /**
   * @description tries to open the server with the desired port, and if getting a `EADDRINUSE` will change to a random port assigned by the OS
   * @param {http.Server} server http server object
   * @returns {Promise<number>} the resulting port number
   * @throws any other server errors will result in a throw
   */
  public async attachServer(server: Server): Promise<number> {
    if (isOntimeCloud) {
      PortManager.port = await this.forceCloudPort(server);
    } else {
      PortManager.port = this.parsePort(envPort) || (await appState.getServerPort()) || config.defaultServerPort;
      PortManager.port = await this.tryServerPort(server);
    }
    await appState.setServerPort(PortManager.port);
    return PortManager.port;
  }

  private parsePort(port: string | undefined) {
    if (typeof port !== 'string') return null;
    if (port === '') return null;
    const maybePort = Number(port);
    if (isNaN(maybePort)) return null;
    return maybePort;
  }

  private async tryServerPort(server: Server): Promise<number> {
    return new Promise((resolve, reject) => {
      server.once('error', (error) => {
        // we should only move ports if we are in a desktop environment
        if (isDocker) {
          reject(error);
          return;
        }

        if (!isPortInUseError(error)) {
          reject(error);
          return;
        }

        // if we get an address in use error, we will try to open the server in an ephemeral port
        // port 0 will assign an ephemeral port
        server.listen(0, bindHost, () => {
          const address = server.address();
          if (!isAddressInfo(address)) {
            reject(new Error('Unknown port type, unable to proceed'));
            return;
          }
          logger.error(
            LogOrigin.Server,
            `Failed to open the desired port: ${PortManager.port} \nMoved to an Ephemeral port: ${address.port}`,
            true,
          );

          resolve(address.port);
        });
      });

      server.listen(PortManager.port, bindHost, () => {
        const address = server.address();
        if (!isAddressInfo(address)) {
          reject(new Error('Unknown port type, unable to proceed'));
          return;
        }
        resolve(address.port);
      });
    });
  }

  private forceCloudPort(server: Server): Promise<number> {
    return new Promise((resolve, reject) => {
      server.once('error', (error) => {
        reject(error);
      });
      server.listen(config.defaultServerPort, bindHost, () => {
        const address = server.address();
        if (!isAddressInfo(address)) {
          reject(new Error('Unknown port type, unable to proceed'));
          return;
        }
        resolve(address.port);
      });
    });
  }
}

export const portManager = new PortManager();
