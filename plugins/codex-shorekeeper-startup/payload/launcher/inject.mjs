// Original implementation. References: yanami-sec/codex-startup-animation-windows
// (runtime CDP approach) and Rice-dog/code-codex (early startup overlay approach).
// No account files or conversation data are read. No application files are changed.
import { readFile, access, writeFile, mkdir } from 'node:fs/promises';
import { writeFileSync, readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { dirname, resolve, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';

const base = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const value = name => { const i = args.indexOf(name); return i < 0 ? undefined : args[i + 1]; };
const port = Number(value('--port') || 19341);
const expectedExe = value('--expected-exe');
const expectedPid = Number(value('--expected-pid') || 0);
const readyFile = value('--ready-file') ? resolve(value('--ready-file')) : null;
const diagnose = args.includes('--dry-run') || args.includes('--diagnose');
const prefix = readyFile || (value('--run-prefix') ? resolve(value('--run-prefix')) : resolve(base, 'launcher/runtime', randomUUID().replaceAll('-', '')));
const resultFile = prefix + '.result.json';
let boundPid = expectedPid, successful = false;
const exists = path => access(path).then(() => true, () => false);
const log = (event, fields = {}) => console.log(JSON.stringify({ time: new Date().toISOString(), event, ...fields }));
process.on('uncaughtException', error => {
    if (readyFile) { try { writeFileSync(readyFile + '.abort', 'injector-failed'); } catch {} }
    log('injection-stopped', { reason: error.message, applicationPreserved: true });
    if (!successful) saveResult(false, error.code || 'unhandled-error', error.message);
    process.exit(successful ? 0 : 1);
});

if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('Invalid local port');
if (!Number.isInteger(expectedPid) || expectedPid < 0) throw new Error('Invalid expected process');
if (!prefix.toLowerCase().startsWith(resolve(base, 'launcher/runtime').toLowerCase() + '\\') || !/^[a-f0-9]{32}$/i.test(basename(prefix))) throw new Error('Invalid native gate signal path');
if (diagnose) {
    log('diagnose', { node: process.version, builtInWebSocket: typeof WebSocket === 'function', overlay: await exists(resolve(base, 'overlay.js')), video: await exists(resolve(base, 'assets/startup.mp4')), port, noApplicationStarted: true });
    process.exit(0);
}
if (process.platform !== 'win32' || !expectedExe || basename(expectedExe).toLowerCase() !== 'chatgpt.exe') throw new Error('A verified Windows Codex executable is required');
if (typeof WebSocket !== 'function') throw new Error('Node.js 22 or newer is required');
await mkdir(resolve(base, 'launcher/runtime'), { recursive: true });
function saveResult(ok, code, message, extra = {}) {
    successful = ok;
    writeFileSync(resultFile, JSON.stringify({ ok, code, message, pid: boundPid, time: new Date().toISOString(), ...extra }));
}
function native(mode, values, suffix, last) {
    const file = prefix + suffix;
    let exit = 0;
    try { execFileSync(resolve(base, 'launcher/StartupGate.exe'), [mode, ...values, file, ...(last === undefined ? [] : [last])], { windowsHide: true, timeout: 10000, stdio: 'ignore' }); }
    catch (error) { exit = error.status || 1; }
    let result;
    try { result = JSON.parse(readFileSync(file, 'utf8')); } catch { const error=new Error('Native helper returned no diagnostic result');error.code='native-result-missing';throw error; }
    if (!result.ok || exit !== 0) { const error=new Error(result.code);error.code=result.code;throw error; }
    return result;
}
function activateNative() {
    const status=native('--activate',[String(boundPid),expectedExe],'.foreground.json');
    if(!status.visible||status.iconic||!status.foreground||status.alpha===0){const error=new Error('Native window is not physically foreground-visible');error.code='window-not-visible';throw error;}
    log('foreground-confirmed',status);
    return status;
}


function verifyOwner() {
    const status = native('--verify-port', [String(port), expectedExe], '.owner.json', String(expectedPid || boundPid));
    boundPid = status.pid;
    return status;
}

const media = await readFile(resolve(base, 'assets/startup.mp4'));
let poster = '';
for (const [name, mime] of [['poster.jpg', 'image/jpeg'], ['poster.png', 'image/png'], ['poster.webp', 'image/webp']]) {
    const path = resolve(base, 'assets', name);
    if (await exists(path)) { poster = `data:${mime};base64,${(await readFile(path)).toString('base64')}`; break; }
}
let source = await readFile(resolve(base, 'overlay.js'), 'utf8');
if (!source.includes('__MEDIA_DATA_URL__')) throw new Error('overlay.js is missing its media placeholder');
source = source.replaceAll('__MEDIA_DATA_URL__', JSON.stringify(`data:video/mp4;base64,${media.toString('base64')}`)).replaceAll('__POSTER_DATA_URL__', JSON.stringify(poster));

function mainPage(target) {
    try {
        const u = new URL(target.url), route = u.searchParams.get('initialRoute') || '/';
        return target.type === 'page' && u.protocol === 'app:' && u.hostname === '-' && u.pathname === '/index.html' && !/avatar|quick.chat|detached|mini|popover|notification/i.test(route);
    } catch { return false; }
}
function localSocket(address) {
    const u = new URL(address);
    if (u.protocol !== 'ws:' || u.hostname !== '127.0.0.1' || Number(u.port) !== port || !u.pathname.startsWith('/devtools/page/') || u.username || u.password) throw new Error('Nonlocal page endpoint refused');
    return u.href;
}
async function connect(address) {
    const socket = new WebSocket(address), pending = new Map();
    let serial = 0;
    await new Promise((accept, reject) => {
        const timer = setTimeout(() => { socket.close(); reject(new Error('CDP connection timed out')); }, 5000);
        socket.addEventListener('open', () => { clearTimeout(timer); accept(); }, { once: true });
        socket.addEventListener('error', () => { clearTimeout(timer); reject(new Error('CDP connection failed')); }, { once: true });
    });
    socket.addEventListener('message', event => {
        let reply; try { reply = JSON.parse(event.data); } catch { return; }
        const request = pending.get(reply.id); if (!request) return;
        pending.delete(reply.id); clearTimeout(request.timer);
        if (reply.error) request.reject(new Error(reply.error.message)); else request.accept(reply.result);
    });
    socket.addEventListener('close', () => { for (const request of pending.values()) { clearTimeout(request.timer); request.reject(new Error('CDP closed during navigation')); } pending.clear(); });
    return {
        call(method, params = {}) { return new Promise((accept, reject) => {
            const id = ++serial, timer = setTimeout(() => { pending.delete(id); reject(new Error(`${method} timed out`)); }, 25000);
            pending.set(id, { accept, reject, timer });
            try { socket.send(JSON.stringify({ id, method, params })); } catch (error) { clearTimeout(timer); pending.delete(id); reject(error); }
        }); },
        close() { socket.close(); }
    };
}

function prepareHandoff() {
    const key = '__shorekeeperNativeHandoff';
    window[key]?.cleanup?.();
    const hadFlag = Object.prototype.hasOwnProperty.call(window, '__SHOREKEEPER_DEFER_REVEAL__');
    const oldFlag = window.__SHOREKEEPER_DEFER_REVEAL__;
    const priorFocus = document.activeElement;
    delete window.__shorekeeperNativeFailure;
    const state = { ready: false, ended: false, released: false };
    const failed = event => { state.failureCode = event.detail?.code || 'media-prepare-failed'; window.__shorekeeperNativeFailure = state.failureCode; };
    const releaseFlag = () => {
        if (state.released) return;
        state.released = true;
        if (hadFlag) window.__SHOREKEEPER_DEFER_REVEAL__ = oldFlag;
        else delete window.__SHOREKEEPER_DEFER_REVEAL__;
    };
    const ready = () => { state.ready = true; };
    const started = event => { state.started = true; state.startDetail = event.detail || {}; };
    const ended = () => { state.ended = true; cleanup(); };
    const cleanup = () => {
        clearTimeout(timeout);
        releaseFlag();
        document.removeEventListener('shorekeeper-startup-ready', ready);
        document.removeEventListener('shorekeeper-startup-ended', ended);
        document.removeEventListener('shorekeeper-startup-started', started);
        document.removeEventListener('shorekeeper-startup-failed', failed);
        if (window[key] === state) delete window[key];
        if(priorFocus?.isConnected)priorFocus.focus?.({preventScroll:true});
    };
    const timeout = setTimeout(cleanup, 90000);
    state.releaseFlag = releaseFlag;
    state.cleanup = cleanup;
    window[key] = state;
    window.__SHOREKEEPER_DEFER_REVEAL__ = true;
    document.addEventListener('shorekeeper-startup-ready', ready, { once: true });
    document.addEventListener('shorekeeper-startup-ended', ended, { once: true });
    document.addEventListener('shorekeeper-startup-started', started, { once: true });
    document.addEventListener('shorekeeper-startup-failed', failed, { once: true });
    return true;
}

const readinessExpression = `(() => { const h=document.getElementById('shorekeeper-codex-startup');return {ready:window.__shorekeeperNativeHandoff?.ready===true||h?.getAttribute('data-ready')==='true',host:!!h,failure:window.__shorekeeperNativeFailure}; })()`;
const cancelExpression = `document.dispatchEvent(new CustomEvent('shorekeeper-startup-cancel'));window.__shorekeeperNativeHandoff?.cleanup?.();delete window.__shorekeeperNativeFailure;`;
const revealExpression = proof => `(() => {document.dispatchEvent(new CustomEvent('shorekeeper-startup-visible',{detail:${JSON.stringify(proof)}}));window.__shorekeeperNativeHandoff?.releaseFlag?.();return true;})()`;
async function restoreBrowserWindow(client) {
    try {
        const window=await client.call('Browser.getWindowForTarget');
        log('browser-window-state',window);
        if(window.bounds?.windowState==='minimized')await client.call('Browser.setWindowBounds',{windowId:window.windowId,bounds:{windowState:'normal'}});
    }catch(error){log('browser-window-api',{available:false,reason:error.message});}
    try{await client.call('Page.bringToFront');}catch(error){log('page-bring-to-front-unavailable',{reason:error.message});}
}
async function revealWhenReady(client) {
    // Existing windows can be minimized or hidden in the tray. Restore the
    // prepared overlay first, then wait for its paused first frame to decode.
    if(!readyFile) { await restoreBrowserWindow(client); activateNative(); }
    const end=Date.now()+11000;
    let ready=false;
    while(Date.now()<end) {
        const observed=await client.call('Runtime.evaluate',{expression:readinessExpression,returnByValue:true});
        if(observed.result?.value?.failure)throw Object.assign(new Error(observed.result.value.failure),{code:observed.result.value.failure});
        if(observed.result?.value?.ready){ready=true;break;}
        if(!observed.result?.value?.host)throw Object.assign(new Error('The prepared startup layer was removed'),{code:'startup-cancelled'});
        await delay(20);
    }
    if(!ready)throw Object.assign(new Error('No paused first frame or poster became ready'),{code:'first-frame-timeout'});
    log('paused-first-frame-ready');
    if(readyFile) {
        await writeFile(readyFile+'.ready','paused-first-frame');
        const end=Date.now()+4500;
        while(!(await exists(readyFile+'.shown'))&&Date.now()<end){
            if(await exists(readyFile+'.abort'))throw Object.assign(new Error('Native gate failed open'),{code:'gate-failed-open'});
            await delay(15);
        }
        const shown=await readFile(readyFile+'.shown','utf8').catch(()=> '');
        if(shown.trim()!=='foreground-confirmed')throw Object.assign(new Error('Native window reveal was not confirmed: '+shown.trim()),{code:'native-reveal-not-confirmed'});
    }
    await restoreBrowserWindow(client);
    const foreground=activateNative();
    await client.call('Runtime.evaluate',{expression:'window.focus();{const h=document.getElementById("shorekeeper-codex-startup");if(h){h.tabIndex=-1;h.style.outline="none";h.focus({preventScroll:true});}}',returnByValue:true,userGesture:true});
    let visible=false,lastVisibility;
    const visibleEnd=Date.now()+1500;
    while(Date.now()<visibleEnd) {
        const result=await client.call('Runtime.evaluate',{expression:`({visible:document.visibilityState==='visible',focus:document.hasFocus()})`,returnByValue:true});
        lastVisibility=result.result?.value;
        if(lastVisibility?.visible){visible=true;break;}
        await delay(25);
    }
    if(!visible)throw Object.assign(new Error('The main page is not visible: '+JSON.stringify(lastVisibility)),{code:'page-not-visible'});
    const verified = native('--status',[String(boundPid),expectedExe],'.foreground-check.json');
    if(!verified.foreground||!verified.visible||verified.iconic||verified.alpha===0||verified.hwnd!==foreground.hwnd)throw Object.assign(new Error('Foreground changed before the first frame'),{code:'foreground-changed-before-start'});
    log('visible-start-proof',{...verified,page:lastVisibility});
    await client.call('Runtime.evaluate',{expression:revealExpression({foregroundConfirmed:true,hwnd:verified.hwnd,pid:boundPid,confirmedAt:Date.now()}),returnByValue:true,userGesture:true});
    const ackEnd=Date.now()+1200;
    let ack;
    while(Date.now()<ackEnd){
        const r=await client.call('Runtime.evaluate',{expression:`({started:window.__shorekeeperNativeHandoff?.started===true,detail:window.__shorekeeperNativeHandoff?.startDetail,stage:document.getElementById('shorekeeper-codex-startup')?.getAttribute('data-stage'),failure:window.__shorekeeperNativeFailure})`,returnByValue:true});
        ack=r.result?.value;if(ack?.failure)throw Object.assign(new Error(ack.failure),{code:ack.failure});if(ack?.started)break;await delay(20);
    }
    if(!ack?.started)throw Object.assign(new Error('The visible overlay did not acknowledge a fresh start'),{code:'start-not-acknowledged'});
    log('visible-timeline-started',{gated:!!readyFile,...ack});
    return {foreground,start:ack};
}

verifyOwner();log('verified-local-client',{port,pid:boundPid});
let lastFailure='Main application page not available',lastCode='main-page-timeout',installed=false,attached=false;
const deadline=Date.now()+45000;
while(Date.now()<deadline&&!installed) {
    try {
        if(readyFile&&await exists(readyFile+'.abort')){lastCode='gate-failed-open';break;}
        const response=await fetch(`http://127.0.0.1:${port}/json/list`,{signal:AbortSignal.timeout(1200),redirect:'error'});
        if(!response.ok)throw new Error('Target discovery HTTP '+response.status);
        const targets=await response.json();
        for(const target of targets.filter(mainPage)) {
            let client;
            try {
                verifyOwner();client=await connect(localSocket(target.webSocketDebuggerUrl));
                await client.call('Runtime.enable');
                const mounted=await client.call('Runtime.evaluate',{expression:`document.readyState==='complete'&&!!document.getElementById('root')`,returnByValue:true});
                if(mounted.result?.value!==true)continue;
                const active=await client.call('Runtime.evaluate',{expression:`document.getElementById('shorekeeper-codex-startup')?.getAttribute('data-stage')`,returnByValue:true});
                if(['playing','handoff'].includes(active.result?.value)){activateNative();saveResult(true,'already-playing','Existing startup timeline preserved');installed=true;break;}
                await client.call('Runtime.evaluate',{expression:`(${prepareHandoff.toString()})()`,returnByValue:true});
                const result=await client.call('Runtime.evaluate',{expression:source,returnByValue:true,awaitPromise:true,userGesture:true});
                if(result.exceptionDetails)throw Object.assign(new Error(result.exceptionDetails.exception?.description||'Overlay evaluation failed'),{code:'overlay-script-error'});
                if(!(result.result?.value?.installed||result.result?.value?.alreadyActive))continue;
                attached=true;
                const handshake=await revealWhenReady(client);
                saveResult(true,'started-from-frame-zero','Foreground and visible start acknowledged',{handshake});
                installed=true;log('overlay-installed');break;
            }catch(error){
                lastFailure=error.message;lastCode=error.code||'startup-handshake-failed';
                log('attempt-failed',{code:lastCode,reason:lastFailure});
                try{await client?.call('Runtime.evaluate',{expression:cancelExpression,returnByValue:true});}catch{}
                if(attached)break;
            }finally{client?.close();}
        }
        if(attached&&!installed)break;
    }catch(error){lastFailure=error.message;lastCode=error.code||'target-discovery-failed';}
    if(!installed)await delay(80);
}
if(!installed){
    if(readyFile)await writeFile(readyFile+'.abort',lastCode).catch(()=>{});
    try{activateNative();}catch{}
    saveResult(false,lastCode,lastFailure);
    log('overlay-not-installed',{code:lastCode,reason:lastFailure,applicationPreserved:true});
    process.exitCode=lastCode==='startup-cancelled'?0:1;
}
