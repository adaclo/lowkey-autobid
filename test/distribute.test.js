const test = require('node:test');
const assert = require('node:assert/strict');
const { distribute, mulberry32, hashSeed, parseDate, isWeekend, pickBestRating } = require('../sbid-autofill.js');

const acts = ['a', 'b', 'c', 'd', 'e'].map((id) => ({ id, weight: 1 }));
const sum = (o) => Object.values(o).reduce((t, x) => t + x, 0);

test('siempre suma exactamente el total y en múltiplos de 15 min', () => {
  const rng = mulberry32(hashSeed('x'));
  for (let i = 0; i < 500; i++) {
    const total = [2, 3.5, 4, 6, 7.25][i % 5];
    const plan = distribute(rng, acts, { total, minBlock: 0.5, kMin: 2, kMax: 4, maxPerAct: total });
    assert.equal(sum(plan), total);
    Object.values(plan).forEach((h) => assert.equal(h % 0.25, 0));
  }
});

test('respeta bloque mínimo y número de actividades', () => {
  const rng = mulberry32(1);
  for (let i = 0; i < 300; i++) {
    const plan = distribute(rng, acts, { total: 4, minBlock: 0.5, kMin: 2, kMax: 3, maxPerAct: 4 });
    const n = Object.keys(plan).length;
    assert.ok(n >= 2 && n <= 3);
    Object.values(plan).forEach((h) => assert.ok(h >= 0.5));
  }
});

test('es reproducible con la misma semilla', () => {
  const run = () => {
    const rng = mulberry32(hashSeed('semilla'));
    return JSON.stringify(Array.from({ length: 20 }, () => distribute(rng, acts, { total: 4, minBlock: 0.5, kMin: 2, kMax: 3, maxPerAct: 4 })));
  };
  assert.equal(run(), run());
});

test('los pesos inclinan el reparto', () => {
  const rng = mulberry32(7);
  const w = [{ id: 'heavy', weight: 20 }, { id: 'light', weight: 1 }, { id: 'light2', weight: 1 }];
  const tot = { heavy: 0, light: 0, light2: 0 };
  for (let i = 0; i < 300; i++) {
    const p = distribute(rng, w, { total: 4, minBlock: 0.5, kMin: 2, kMax: 2, maxPerAct: 4 });
    for (const k in p) tot[k] += p[k];
  }
  assert.ok(tot.heavy > tot.light * 3);
});

test('maxPerAct limita las horas por actividad', () => {
  const rng = mulberry32(3);
  for (let i = 0; i < 200; i++) {
    const p = distribute(rng, acts, { total: 4, minBlock: 0.5, kMin: 2, kMax: 4, maxPerAct: 2 });
    Object.values(p).forEach((h) => assert.ok(h <= 2));
  }
});

test('casos límite', () => {
  const rng = mulberry32(1);
  assert.deepEqual(distribute(rng, [], { total: 4 }), {});
  assert.deepEqual(distribute(rng, [{ id: 'a', weight: 0 }], { total: 4 }), {});
  assert.equal(sum(distribute(rng, [{ id: 'a', weight: 1 }], { total: 4, minBlock: 0.5, kMin: 3, kMax: 3, maxPerAct: 4 })), 4);
  assert.equal(sum(distribute(rng, acts, { total: 0.25, minBlock: 0.5, kMin: 2, kMax: 3 })), 0.25);
});

test('fechas y valoración', () => {
  assert.equal(parseDate('27/05/2026: Activitat').getMonth(), 4);
  assert.equal(isWeekend(new Date(2026, 4, 30)), true); // sábado
  assert.equal(isWeekend(new Date(2026, 4, 27)), false);
  assert.equal(parseDate('sin fecha'), null);
  const opts = [{ value: '', text: '- Seleccionar -' }, { value: '33', text: 'SENSE VALORACIÓ' }, { value: '30', text: 'ADEQUADA' }, { value: '29', text: 'MOLT ADEQUADA' }];
  assert.equal(pickBestRating(opts), '29');
  assert.equal(pickBestRating([{ value: '1', text: 'a' }, { value: '2', text: 'b' }]), '2');
});
