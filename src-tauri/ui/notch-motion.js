/* Fixed Swift Sources/Notch/NotchMotion.swift motion constants and spring response.
 * The browser loads it as a classic script; pure Node tests read the same global. */
(function (root) {
  'use strict';
  const response = Object.freeze({unfold: .42, contents: .36, glide: .5, reading: .9});
  const damping = Object.freeze({unfold: .78, contents: .82, glide: .86, reading: .9});
  const duration = Object.freeze({crossfade: 160, merge: 200, activityTurn: 1100, activityPulse: 900});

  function staggerDelay(index) { return Math.min(Math.max(0, index) * 45, 180); }
  // CSS/SwiftUI easeIn uses cubic-bezier(.42, 0, 1, 1). Solve x(u) so a
  // retargeted merge can continue from its current scale without a WAAPI jump.
  function easeIn(time) {
    const x = Math.max(0, Math.min(1, time));
    if (x === 0 || x === 1) return x;
    let low = 0, high = 1;
    for (let i = 0; i < 20; i++) {
      const u = (low + high) / 2, inverse = 1 - u;
      const current = 3 * inverse * inverse * u * .42 + 3 * inverse * u * u + u * u * u;
      if (current < x) low = u; else high = u;
    }
    const u = (low + high) / 2, inverse = 1 - u;
    return 3 * inverse * u * u + u * u * u;
  }
  function springStep(position, velocity, target, seconds, kind) {
    const omega = 2 * Math.PI / response[kind];
    const zeta = damping[kind];
    const dt = Math.max(0, Math.min(seconds, .064));
    const decay = Math.exp(-zeta * omega * dt);
    const wd = omega * Math.sqrt(1 - zeta * zeta);
    const angle = wd * dt;
    const error = position - target;
    const next = target + decay * (error * Math.cos(angle) + (velocity + zeta * omega * error) / wd * Math.sin(angle));
    const speed = decay * (velocity * Math.cos(angle) - (zeta * omega * velocity + omega * omega * error) / wd * Math.sin(angle));
    return {position: next, velocity: speed};
  }

  function createSpringAnimator(kind, raf, cancel, bounds) {
    const state = new Map();
    const clamp = value => Math.max(bounds?.min ?? -Infinity, Math.min(bounds?.max ?? Infinity, value));
    function stop(key) {
      const item = state.get(key);
      if (item?.frame) cancel(item.frame);
      state.delete(key);
    }
    function update(key, target, apply, reduceMotion, from, onSettled) {
      if (!Number.isFinite(target)) { stop(key); return; }
      target = clamp(target);
      let item = state.get(key);
      if (!item || reduceMotion) {
        if (item?.frame) cancel(item.frame);
        const position = reduceMotion ? target : Number.isFinite(from) ? clamp(from) : target;
        item = {position, velocity: 0, target, frame: 0, time: 0, apply, onSettled};
        state.set(key, item);
        apply(position);
        if (position !== target) item.frame = raf(animate(key));
        else onSettled?.();
        return;
      }
      item.target = target;
      item.apply = apply;
      item.onSettled = onSettled;
      if (item.frame) return;
      if (item.position === target && item.velocity === 0) { onSettled?.(); return; }
      // A settled ring can sit for minutes. Its first frame after a later
      // reading establishes a fresh clock, not a 64 ms jump from stale time.
      item.time = 0;
      item.frame = raf(animate(key));
    }
    function animate(key) {
      return function frame(now) {
        const item = state.get(key);
        if (!item) return;
        item.frame = 0;
        const dt = item.time ? (now - item.time) / 1000 : 0;
        item.time = now;
        const next = springStep(item.position, item.velocity, item.target, dt, kind);
        item.position = next.position;
        item.velocity = next.velocity;
        const settled = Math.abs(item.position - item.target) < .0001 && Math.abs(item.velocity) < .005;
        if (settled) {
          item.position = item.target;
          item.velocity = 0;
        }
        item.apply(clamp(item.position));
        if (state.get(key) !== item) return;
        if (settled) item.onSettled?.();
        else item.frame = raf(animate(key));
      };
    }
    function value(key) { return state.get(key)?.position ?? null; }
    return {update, stop, value};
  }

  function createReadingAnimator(raf, cancel) {
    return createSpringAnimator('reading', raf, cancel, {min: 0, max: 1});
  }

  const api = Object.freeze({response, damping, duration, staggerDelay, easeIn, springStep, createSpringAnimator, createReadingAnimator});
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.NotchMotion = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
