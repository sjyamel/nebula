// Headless smoke test: does nebula_init return, and do frames render?
// The env stub counts which native Canvas2D calls actually fire, which is
// what distinguishes "routed through the renderer" from "software path".
import { readFileSync } from 'fs';
import { Worker, isMainThread, parentPort } from 'worker_threads';
const WASM = new URL('./nebula.wasm', import.meta.url);

if (!isMainThread) {
  const counts = { js_set_canvas_size: 0, js_fill_rect: 0, js_rounded_rect: 0, js_circle: 0, js_fill_text: 0 };
  const env = {};
  for (const k of Object.keys(counts)) env[k] = () => { counts[k]++; };
  const { instance } = await WebAssembly.instantiate(readFileSync(WASM), { env });
  const ex = instance.exports;
  const hb = ex.__heap_base.value ?? ex.__heap_base;
  ex.nebula_heap_init(hb, BigInt(ex.memory.buffer.byteLength - hb));
  ex.nebula_init(1280n, 800n);
  for (let i = 0; i < 3; i++) ex.nebula_frame(1280n, 800n, 400n, 300n, 0n, 0n, 0n);
  parentPort.postMessage(`${ex.nebula_frames()} frames | ` +
    Object.entries(counts).map(([k, v]) => `${k.replace('js_', '')}=${v}`).join('  '));
} else {
  const res = await new Promise(resolve => {
    const w = new Worker(new URL(import.meta.url));
    const t = setTimeout(() => { w.terminate(); resolve('*** HANG (8s) ***'); }, 8000);
    w.on('message', m => { clearTimeout(t); w.terminate(); resolve('OK -> ' + m); });
    w.on('error', e => { clearTimeout(t); resolve('ERROR: ' + e.message); });
  });
  console.log(res);
}
