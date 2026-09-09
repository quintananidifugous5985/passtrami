// SPDX-License-Identifier: GPL-3.0-or-later
// Session handling adapted from APW 1.1.1. System operations run in Swift.
(() => {
  const { RequestError, normalizeDomain, accountsMessage, passwordMessage,
    usernamesFrom, credentialsFrom, onePassword } = AsterCredentials;
  const operations = new Map(), timers = new Map(), candidates = new Map(), clients = new Map();
  const waiters = new Set();
  let sequence = 0, phase = 'starting', phaseMessage, nativeState = '', token = null;
  let bridge = null, browser = false, launching = null, stopping = null, generation = 0;
  let shuttingDown = false, appUnlockRequested = false, challengeSent = false, pinSubmitted = false;
  let pending = null, queue = Promise.resolve();

  function post(message) { __nativePost(JSON.stringify(message)); }
  function native(op, values = {}) {
    return new Promise((resolve, reject) => {
      const id = String(++sequence);
      operations.set(id, { resolve, reject });
      post({ op, id, ...values });
    });
  }
  function later(callback, milliseconds) {
    const id = String(++sequence);
    timers.set(id, callback);
    post({ op: 'timer', id, milliseconds });
    return id;
  }
  function cancelTimer(id) {
    if (timers.delete(id)) post({ op: 'cancelTimer', id });
  }
  function emit(event) { post({ op: 'emit', event }); }
  function setPhase(state, message) {
    if (phase === state && phaseMessage === message) return;
    phase = state; phaseMessage = message;
    emit({ type: 'state', state, ...(message ? { message } : {}) });
  }
  function resolveWaiters(error) {
    for (const item of waiters) {
      cancelTimer(item.timer); item.removeCancel();
      error ? item.reject(error) : item.resolve();
    }
    waiters.clear();
  }
  function rejectPending(error) {
    if (!pending) return;
    const request = pending; pending = null;
    cancelTimer(request.timer); request.removeCancel(); request.reject(error);
  }
  function send(message) {
    if (!bridge) throw new RequestError('locked', 'The password session is not connected.');
    post({ op: 'send', connection: bridge, text: JSON.stringify(message) });
  }
  function disconnectBridges() {
    const oldBridge = bridge; bridge = null; nativeState = '';
    if (oldBridge) post({ op: 'disconnect', connection: oldBridge });
    for (const [id, candidate] of candidates) {
      cancelTimer(candidate.timer); post({ op: 'disconnect', connection: id });
    }
    candidates.clear();
  }
  function beginChallenge() {
    if (!(appUnlockRequested || waiters.size) || challengeSent || nativeState !== 'NotInSession' || !bridge) return;
    challengeSent = true; setPhase('pairing'); send({ op: 'unlock' });
  }
  function stateChanged(state) {
    const previous = nativeState;
    if (previous === state) return;
    nativeState = state;
    if (previous === 'SessionKeySet') rejectPending(new RequestError('locked', 'Apple locked the password session.'));
    if (state === 'SessionKeySet') {
      pinSubmitted = false; appUnlockRequested = false; challengeSent = false;
      setPhase('unlocked'); resolveWaiters();
    } else if (state === 'MSG1Set') {
      setPhase('pairing'); emit({ type: 'pinRequired' });
    } else if (state === 'ChallengeSent') {
      setPhase('pairing');
    } else if (state === 'NotInSession') {
      const invalidPIN = pinSubmitted, interrupted = challengeSent && !invalidPIN;
      pinSubmitted = false; challengeSent = false; setPhase('locked');
      if (interrupted) {
        void lock(new RequestError('cancelled', 'Apple cancelled the unlock request. Try Unlock again.'));
      } else {
        if (invalidPIN) emit({ type: 'pinError', message: 'The code was not accepted. Enter the new code shown by macOS.' });
        beginChallenge();
      }
    } else if (state === 'NativeSupportNotInstalled' || state === 'IncompatibleOS') {
      const error = new RequestError('native_helper', "Apple's password helper did not connect to Chromium.");
      setPhase('error', error.message);
      void lock(error, 'error');
    } else if (state === 'Connecting') setPhase('starting');
    else if (state === 'CheckEngine') setPhase('locked');
  }
  async function launch() {
    if (stopping) await stopping;
    if (browser || launching || shuttingDown) return launching;
    const current = ++generation;
    token = __uuid(); setPhase('starting');
    launching = native('startBrowser', { token }).then(() => {
      if (current === generation && !shuttingDown) browser = true;
    }).catch(error => {
      if (current !== generation) return;
      appUnlockRequested = false; generation++; token = null;
      disconnectBridges();
      setPhase('error', error.message); resolveWaiters(error);
    }).finally(() => { launching = null; });
    return launching;
  }
  async function requestUnlock(fromApp = false) {
    if (phase === 'unlocked') return;
    if (fromApp) appUnlockRequested = true;
    await launch(); beginChallenge();
  }
  function ensureUnlocked(client) {
    if (client.cancelled) return Promise.reject(new RequestError('cancelled', 'Request cancelled.'));
    if (phase === 'unlocked') return Promise.resolve();
    return new Promise((resolve, reject) => {
      const item = { resolve, reject };
      const remove = error => {
        waiters.delete(item); cancelTimer(item.timer); item.removeCancel(); reject(error);
        if (!appUnlockRequested && !waiters.size && phase !== 'unlocked') void lock(error);
      };
      item.removeCancel = client.onCancel(() => remove(new RequestError('cancelled', 'Request cancelled.')));
      item.timer = later(() => remove(new RequestError('timeout', 'Unlock timed out.')), 900000);
      waiters.add(item);
      requestUnlock().catch(remove);
    });
  }
  function lock(error = new RequestError('cancelled', 'The password session was locked or cancelled.'), finalPhase = 'locked') {
    if (stopping) return stopping;
    appUnlockRequested = false; challengeSent = false; pinSubmitted = false; generation++; token = null;
    resolveWaiters(error); rejectPending(error); browser = false;
    disconnectBridges();
    const oldLaunch = launching;
    stopping = (async () => {
      await native('stopBrowser');
      if (oldLaunch) await oldLaunch;
      setPhase(finalPhase, finalPhase === 'error' ? error.message : undefined);
    })().finally(() => { stopping = null; });
    return stopping;
  }
  function nativeRequest(message, client) {
    if (client.cancelled) return Promise.reject(new RequestError('cancelled', 'Request cancelled.'));
    return new Promise((resolve, reject) => {
      const id = __uuid();
      const removeCancel = client.onCancel(() => {
        if (pending?.id === id) rejectPending(new RequestError('cancelled', 'Request cancelled.'));
      });
      const timer = later(() => {
        if (pending?.id === id) rejectPending(new RequestError('timeout', "Apple's authentication request timed out."));
      }, 120000);
      pending = { id, resolve, reject, timer, removeCancel };
      try { send({ ...message, id }); } catch (error) { rejectPending(error); }
    });
  }
  async function handleRequest(request, client) {
    const domain = normalizeDomain(request.domain), list = request.op === 'list';
    const username = typeof request.username === 'string' ? request.username : '';
    if (!list && (!username || username.includes('\n'))) throw new RequestError('invalid_request', 'Username is required.');
    const message = list ? accountsMessage(domain) : passwordMessage(domain, username);
    for (let attempt = 0; attempt < 2; attempt++) {
      await ensureUnlocked(client);
      let data;
      try { data = await nativeRequest(message, client); }
      catch (error) {
        // End the old native session before another request can receive a late reply.
        await lock(error);
        if (error.code !== 'locked' || attempt) throw error;
        continue;
      }
      try {
        if (list) return { ok: true, usernames: usernamesFrom(data, domain) };
        return { ok: true, password: onePassword(credentialsFrom(data, domain, username)) };
      } catch (error) {
        if (error.code !== 'locked') throw error;
        await lock(error);
        if (attempt) throw error;
      }
    }
    throw new RequestError('locked', 'The password session is locked.');
  }
  function reply(id, result) { post({ op: 'reply', connection: id, text: JSON.stringify(result) }); }
  function failure(error) {
    return { ok: false, code: error instanceof RequestError ? error.code : 'internal',
      message: error instanceof RequestError ? error.message : 'The request failed.' };
  }
  function receiveRequest(id, text) {
    let request;
    try {
      request = JSON.parse(text);
      if (request?.op === 'status') {
        reply(id, { ok: true, state: phase, ...(phaseMessage ? { message: phaseMessage } : {}) }); return;
      }
      if (!['get', 'list'].includes(request?.op)) throw new RequestError('invalid_request', 'Unknown command.');
    } catch (error) { reply(id, failure(error)); return; }
    const handlers = new Set();
    const client = { cancelled: false,
      onCancel(handler) { handlers.add(handler); return () => handlers.delete(handler); },
      cancel() {
        if (this.cancelled) return;
        this.cancelled = true;
        for (const handler of [...handlers]) handler();
        handlers.clear();
      }
    };
    clients.set(id, client);
    const deadline = later(() => {
      client.cancel(); post({ op: 'closeClient', connection: id });
    }, 1020000);
    const work = queue.then(() => {
      if (client.cancelled) throw new RequestError('cancelled', 'Request cancelled.');
      return handleRequest(request, client);
    });
    queue = work.catch(() => {});
    work.then(result => { if (!client.cancelled) reply(id, result); })
      .catch(error => { if (!client.cancelled) reply(id, failure(error)); })
      .finally(() => { cancelTimer(deadline); clients.delete(id); });
  }
  function receiveBridge(id, text) {
    let message;
    try {
      message = JSON.parse(text);
      if (!message || typeof message !== 'object' || Array.isArray(message)) throw new Error();
    } catch { post({ op: 'disconnect', connection: id }); return; }
    if (bridge !== id) {
      const candidate = candidates.get(id);
      if (!candidate || !token || candidate.generation !== generation || message.token !== token || bridge) {
        post({ op: 'disconnect', connection: id }); return;
      }
      cancelTimer(candidate.timer); candidates.delete(id); bridge = id; return;
    }
    if (message.type === 'nativeState' && typeof message.state === 'string') stateChanged(message.state);
    else if (pending && message.id === pending.id) {
      const request = pending; pending = null;
      cancelTimer(request.timer); request.removeCancel();
      if (message.data && typeof message.data === 'object') request.resolve(message.data);
      else request.reject(new RequestError(message.status === 9 ? 'locked' : 'native_error', "Apple's helper could not complete the request."));
    }
  }
  async function command(value) {
    if (value.op === 'shutdown') {
      shuttingDown = true;
      await lock(); post({ op: 'shutdown' });
    } else if (value.op === 'lock') await lock();
    else if (value.op === 'unlock') await requestUnlock(true);
    else if (value.op === 'pin' && typeof value.pin === 'string' && /^\d{6}$/.test(value.pin) && nativeState === 'MSG1Set') {
      pinSubmitted = true; send({ op: 'pin', pin: value.pin });
    }
  }
  globalThis.Aster = {
    receive(json) {
      const event = JSON.parse(json);
      switch (event.type) {
      case 'ready': emit({ type: 'state', state: 'starting' }); void launch(); break;
      case 'command':
        void command(event.command).catch(() => emit({ type: 'pinError', message: 'The request could not be completed. Try Unlock again.' })); break;
      case 'request': receiveRequest(event.connection, event.text); break;
      case 'clientClosed': clients.get(event.connection)?.cancel(); break;
      case 'bridgeOpen':
        candidates.set(event.connection, { generation, timer: later(() => post({ op: 'disconnect', connection: event.connection }), 5000) }); break;
      case 'bridgeText': receiveBridge(event.connection, event.text); break;
      case 'bridgeClosed': {
        const candidate = candidates.get(event.connection);
        if (candidate) { cancelTimer(candidate.timer); candidates.delete(event.connection); }
        if (bridge === event.connection) void lock(new RequestError('locked', 'The password session closed.'));
        break;
      }
      case 'browserExited':
        if (event.token === token) void lock(new RequestError('locked', 'The browser stopped.')); break;
      case 'progress':
        if (event.token === token && !shuttingDown) setPhase('starting', event.message); break;
      case 'timer': {
        const callback = timers.get(event.id); timers.delete(event.id); callback?.(); break;
      }
      case 'nativeResult': {
        const operation = operations.get(event.id); operations.delete(event.id);
        if (event.error) operation?.reject(new RequestError(event.error.code, event.error.message));
        else operation?.resolve(event.result);
        break;
      }
      }
    }
  };
})();
