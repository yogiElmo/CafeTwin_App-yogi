// squid_controller builds a command string that the gateway's shell runs
// under sudo, so its argument checks are the difference between "throttle
// a station" and "run anything as root". No database or network needed:
// child_process.spawn is mocked, so nothing is ever actually executed.

const { EventEmitter } = require('events');

function loadController(env) {
  const saved = {};
  for (const [key, value] of Object.entries(env)) {
    saved[key] = process.env[key];
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  const spawn = jest.fn(() => {
    const child = new EventEmitter();
    child.stderr = new EventEmitter();
    process.nextTick(() => child.emit('close', 0));
    return child;
  });
  let controller;
  jest.isolateModules(() => {
    jest.doMock('child_process', () => ({ spawn }));
    controller = require('../squid_controller');
  });
  for (const [key, value] of Object.entries(saved)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  return { controller, spawn };
}

function sshOption(args, name) {
  const option = args.find((a) => a.startsWith(`${name}=`));
  return option && option.slice(name.length + 1);
}

beforeEach(() => {
  jest.spyOn(console, 'log').mockImplementation(() => {});
  jest.spyOn(console, 'error').mockImplementation(() => {});
});

afterEach(() => {
  jest.restoreAllMocks();
});

describe('squid_controller argument safety', () => {
  const gateway = { SQUID_HOST: 'gateway.example', SQUID_SSH_STRICT_HOST_CHECK: undefined };

  it.each([
    'ST-01; rm -rf /',
    'ST-01 && reboot',
    '$(id)',
    '`id`',
    'ST 01',
    'ST-01\nid',
    '',
  ])('refuses station id %j without running ssh', async (stationId) => {
    const { controller, spawn } = loadController(gateway);
    const result = await controller.throttle(stationId);
    expect(result.ok).toBe(false);
    expect(spawn).not.toHaveBeenCalled();
  });

  it('refuses an action other than on/off', async () => {
    const { controller, spawn } = loadController(gateway);
    const result = await controller.setThrottle('ST-01', 'on; id');
    expect(result.ok).toBe(false);
    expect(spawn).not.toHaveBeenCalled();
  });

  it('runs ssh for a well-formed station id', async () => {
    const { controller, spawn } = loadController(gateway);
    const result = await controller.throttle('ST-1a2b3c4d-07');
    expect(result.ok).toBe(true);
    const args = spawn.mock.calls[0][1];
    expect(args[args.length - 1]).toBe('sudo /opt/cafetwin/toggle_throttle.sh ST-1a2b3c4d-07 on');
  });

  it('also refuses unsafe ids in dry-run mode (no SQUID_HOST)', async () => {
    const { controller } = loadController({ SQUID_HOST: undefined });
    const result = await controller.throttle('ST-01; id');
    expect(result.ok).toBe(false);
  });
});

describe('squid_controller host-key checking', () => {
  async function hostKeyMode(setting) {
    const { controller, spawn } = loadController({
      SQUID_HOST: 'gateway.example',
      SQUID_SSH_STRICT_HOST_CHECK: setting,
    });
    await controller.throttle('ST-01');
    return sshOption(spawn.mock.calls[0][1], 'StrictHostKeyChecking');
  }

  it('defaults to trust-on-first-use, refusing a changed key', async () => {
    expect(await hostKeyMode(undefined)).toBe('accept-new');
    expect(await hostKeyMode('')).toBe('accept-new');
  });

  it('honours an explicit "true" or "false"', async () => {
    expect(await hostKeyMode('true')).toBe('yes');
    expect(await hostKeyMode('false')).toBe('no');
  });
});
