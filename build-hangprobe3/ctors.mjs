// Does the hang happen BEFORE any export body runs?
//
// If a module-level global with an allocating initializer makes wasm-ld
// synthesize __wasm_call_ctors into every export (reactor mode), then even
// nebula_heap_init -- which does nothing but store two integers -- will hang,
// because the ctors run first and allocate from an arena whose bounds are
// still zero.
import { readFileSync } from 'fs';
import { Worker, isMainThread, workerData, parentPort } from 'worker_threads';

const WASM = new URL('./nebula.wasm', import.meta.url);

if (!isMainThread) {
  const { instance } = await WebAssembly.instantiate(readFileSync(WASM), {});
  const ex = instance.exports;
  if (workerData.step === 'instantiate-only') {
    parentPort.postMessage('instantiated, exports=' + Object.keys(ex).length);
  } else if (workerData.step === 'ctors') {
    ex.__wasm_call_ctors();
    parentPort.postMessage('__wasm_call_ctors returned');
  } else {
    const hb = ex.__heap_base.value ?? ex.__heap_base;
    ex.nebula_heap_init(hb, BigInt(ex.memory.buffer.byteLength - hb));
    parentPort.postMessage('nebula_heap_init returned');
  }
} else {
  const bytes = readFileSync(WASM);
  const mod = await WebAssembly.compile(bytes);
  const exps = WebAssembly.Module.exports(mod).map(e => e.name);
  console.log('exports:', exps.join(', '));
  console.log('has __wasm_call_ctors:', exps.includes('__wasm_call_ctors'));
  console.log('');
  for (const step of ['instantiate-only', 'ctors', 'heap_init']) {
    const res = await new Promise(resolve => {
      const w = new Worker(new URL(import.meta.url), { workerData: { step } });
      const t = setTimeout(() => { w.terminate(); resolve('*** HANG ***'); }, 2500);
      w.on('message', m => { clearTimeout(t); w.terminate(); resolve('ok -> ' + m); });
      w.on('error', e => { clearTimeout(t); resolve('ERROR: ' + e.message); });
    });
    console.log(step.padEnd(18), res);
  }
}
