import {test} from 'node:test';
import assert from 'node:assert/strict';
await import('../src-tauri/ui/notch-motion.js');
const Motion = globalThis.NotchMotion;

function frameClock() {
  let next = 1;
  const pending = new Map();
  return {
    request(callback) { const id = next++; pending.set(id, callback); return id; },
    cancel(id) { pending.delete(id); },
    step(now) {
      const callbacks = [...pending.values()];
      pending.clear();
      callbacks.forEach(callback => callback(now));
    },
    get pending() { return pending.size; },
  };
}

test('fixed Swift timing constants and capped cell stagger', () => {
  assert.deepEqual(Motion.response, {unfold: .42, contents: .36, glide: .5, reading: .9});
  assert.deepEqual(Motion.damping, {unfold: .78, contents: .82, glide: .86, reading: .9});
  assert.deepEqual(Motion.duration, {crossfade: 160, merge: 200, activityTurn: 1100, activityPulse: 900});
  assert.deepEqual([0, 1, 2, 4, 8].map(Motion.staggerDelay), [0, 45, 90, 180, 180]);
  assert.equal(Motion.easeIn(0), 0);
  assert.equal(Motion.easeIn(1), 1);
  assert.ok(Motion.easeIn(.5) > .31 && Motion.easeIn(.5) < .32);
});

test('reading spring retains velocity across retargets and settles on the latest value', () => {
  const clock = frameClock();
  const samples = [];
  const animator = Motion.createReadingAnimator(clock.request, clock.cancel);
  animator.update('claude', .1, value => samples.push(value), false);
  animator.update('claude', .9, value => samples.push(value), false);
  for (let time = 16; time <= 432; time += 16) clock.step(time);
  const atRetarget = samples.at(-1);
  assert.ok(atRetarget > .1 && atRetarget < 1, `reading did not sweep: ${atRetarget}`);
  animator.update('claude', .2, value => samples.push(value), false);
  clock.step(448);
  assert.ok(samples.at(-1) > atRetarget, 'the spring must preserve its forward velocity on retarget');
  for (let time = 464; time <= 6000 && clock.pending; time += 16) clock.step(time);
  assert.equal(clock.pending, 0);
  assert.equal(samples.at(-1), .2);
});

test('reduce motion applies a reading immediately and cancels pending frames', () => {
  const clock = frameClock();
  const samples = [];
  const animator = Motion.createReadingAnimator(clock.request, clock.cancel);
  animator.update('claude', .1, value => samples.push(value), false);
  animator.update('claude', .9, value => samples.push(value), false);
  assert.equal(clock.pending, 1);
  animator.update('claude', .4, value => samples.push(value), true);
  assert.equal(clock.pending, 0);
  assert.deepEqual(samples, [.1, .4]);
  animator.stop('claude');
});

test('contents spring starts 28 points toward the edge, then follows a changed destination', () => {
  const clock = frameClock();
  const samples = [];
  const animator = Motion.createSpringAnimator('contents', clock.request, clock.cancel);
  animator.update('cell-1', 0, value => samples.push(value), false, 28);
  assert.equal(samples.at(-1), 28);
  for (let time = 16; time <= 224; time += 16) clock.step(time);
  assert.ok(samples.at(-1) < 28 && samples.at(-1) > -4);
  animator.update('cell-1', 28, value => samples.push(value), false);
  for (let time = 240; time <= 4000 && clock.pending; time += 16) clock.step(time);
  assert.equal(clock.pending, 0);
  assert.equal(samples.at(-1), 28);
});

test('a settled reading starts a fresh frame clock after a long quiet interval', () => {
  const clock = frameClock();
  const samples = [];
  const animator = Motion.createReadingAnimator(clock.request, clock.cancel);
  animator.update('codex', .2, value => samples.push(value), false);
  animator.update('codex', .7, value => samples.push(value), false);
  for (let time = 16; time <= 4000 && clock.pending; time += 16) clock.step(time);
  assert.equal(samples.at(-1), .7);
  animator.update('codex', .9, value => samples.push(value), false);
  clock.step(100_000);
  assert.equal(samples.at(-1), .7, 'the first frame must establish time without jumping');
  clock.step(100_016);
  assert.ok(samples.at(-1) > .7);
});
