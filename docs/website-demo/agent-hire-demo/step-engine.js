/* =====================================================================
 * scenario-playback-toolkit · step-engine.js
 *
 * Reusable scenario player engine. Provides scenario switching, step-by-step
 * playback, auto-play, reset, prev-step (via reset+fast-replay), keyboard
 * shortcuts, and micro-step drain.
 *
 * Public API (everything attached to window.scenarioPlayback):
 *
 *   init(config)               Initialize and mount the player. See REFERENCE.md
 *                              §config schema for the full shape.
 *   play()                     Auto-play from current position to end.
 *   step()                     Advance to next "visible" step (drains micros).
 *   prev()                     Rewind one visible step (reset + fast replay).
 *   reset()                    Reset to the start of the current scenario.
 *   currentState()             Snapshot of {activeScenario, currentStep,
 *                              totalSteps, isPlaying, isStepping, stepHistory}
 *   setScenario(scenarioId)    Switch active scenario (calls reset).
 *
 * Step type contract:
 *
 *   Each scenario must have a .steps array. Each step is { t: 'type', ...params }.
 *
 *   Built-in step types (handled by executeStepCore):
 *     - { t: 'wait', ms: <number> }                          micro step (no DOM mutation)
 *     - { t: 'view_switch', view: '<view-name>' }            sets .active on .spt-view[data-view="<name>"]
 *                                                            and clears it on others
 *     - { t: 'noop' }                                        does nothing (placeholder)
 *
 *   Custom step types are delegated to config.executeStepCustom(step).
 *
 * Micro steps:
 *   Step types listed in config.microStepTypes don't create a "landing point"
 *   in stepHistory. Pressing ⏮ skips them. Default: ['wait'].
 *
 * Keyboard shortcuts (auto-bound unless config.keyboardShortcuts === false):
 *   Space / →    → step()
 *   ←            → prev()
 *   Enter        → play()
 *   Esc / R      → reset()
 *
 *   Shortcuts are ignored when focus is inside an <input> or <textarea>.
 *
 * Decoupling principles:
 *   - This engine knows ONLY about steps. It does not know about scenarios'
 *     business content (rationale, recommendations, test_cases, etc.).
 *   - The engine touches only its own DOM elements (#spt-* IDs and
 *     .spt-* classes). It does NOT manipulate the consumer's page DOM
 *     except via executeStepCore handlers (view_switch).
 *   - All business step types must be implemented by the consumer via
 *     config.executeStepCustom.
 * ===================================================================== */

(function (global) {
  'use strict';

  // ----- Engine state (all kept inside the IIFE) -----

  let _config = null;        // user-provided config, set by init()
  let _activeScenario = null;
  let _steps = [];           // resolved step array for the current scenario
  let _currentStep = 0;
  let _isPlaying = false;
  let _isStepping = false;
  let _stepHistory = [];     // currentStep values after each visible-step landing
  let _fastReplay = false;   // when true, sleep() is short-circuited

  const _q = id => document.getElementById(id);

  // ----- Helpers -----

  function _sleep(ms) {
    return new Promise(r => setTimeout(r, _fastReplay ? Math.min(ms, 5) : ms));
  }

  function _isMicro(stepType) {
    return _config.microStepTypes.has(stepType);
  }

  function _updateCounter() {
    const counter = _q('spt-step-counter');
    if (counter) counter.textContent = `${Math.min(_currentStep, _steps.length)} / ${_steps.length}`;
  }

  function _setBtnsDuringPlaying(disabled) {
    const play = _q('spt-play-btn');
    const step = _q('spt-step-btn');
    const prev = _q('spt-prev-btn');
    if (play) play.disabled = disabled;
    if (step) step.disabled = disabled;
    if (prev) prev.disabled = disabled || _stepHistory.length === 0;
    if (disabled) {
      if (play) play.innerHTML = '⏸ 播放中…';
    } else {
      if (play) play.innerHTML = _currentStep >= _steps.length ? '↺ 已完成' : '▶ 自动播放';
    }
  }

  function _setBtnsAfterAction() {
    const step = _q('spt-step-btn');
    const prev = _q('spt-prev-btn');
    const play = _q('spt-play-btn');
    if (step) step.disabled = _currentStep >= _steps.length;
    if (prev) prev.disabled = _stepHistory.length === 0;
    if (play) {
      play.disabled = false;
      play.innerHTML = _currentStep >= _steps.length ? '↺ 已完成' : '▶ 自动播放';
    }
  }

  // ----- Built-in step executor -----

  async function _executeStepCore(step) {
    switch (step.t) {
      case 'wait':
        await _sleep(step.ms || 0);
        return true;  // handled

      case 'view_switch': {
        // Activate .spt-view[data-view="<name>"], deactivate others
        const views = document.querySelectorAll('.spt-view');
        views.forEach(v => {
          if (v.dataset.view === step.view) v.classList.add('active');
          else v.classList.remove('active');
        });
        return true;
      }

      case 'noop':
        return true;

      default:
        return false;  // not handled — delegate to custom
    }
  }

  async function _executeStep(step) {
    const handled = await _executeStepCore(step);
    if (handled) return;
    if (_config.executeStepCustom) {
      await _config.executeStepCustom(step);
    } else {
      console.warn('[scenario-playback-toolkit] Unknown step type:', step.t, '— provide config.executeStepCustom to handle it.');
    }
  }

  // ----- Core public functions -----

  async function play() {
    if (_isPlaying || _isStepping) return;
    if (_currentStep >= _steps.length) return;
    _isPlaying = true;
    _setBtnsDuringPlaying(true);

    for (; _currentStep < _steps.length; _currentStep++) {
      if (!_isPlaying) break;
      const step = _steps[_currentStep];
      await _executeStep(step);
      _updateCounter();
      // Record landing for prev-step (skip micro steps)
      if (!_isMicro(step.t) && !_fastReplay) {
        _stepHistory.push(_currentStep + 1);
      }
      // Inter-step delay
      const delay = _isMicro(step.t) ? 60 : (_config.interStepDelayMs || 380);
      await _sleep(delay);
    }

    _isPlaying = false;
    _setBtnsDuringPlaying(false);
  }

  async function step() {
    if (_isPlaying || _isStepping) return;
    if (_currentStep >= _steps.length) return;
    _isStepping = true;
    _setBtnsDuringPlaying(true);  // disables during action

    // Drain micro steps until a visible step lands
    let executedVisible = false;
    while (_currentStep < _steps.length && !executedVisible) {
      const stepDef = _steps[_currentStep];
      await _executeStep(stepDef);
      _currentStep++;
      _updateCounter();
      if (_isMicro(stepDef.t)) {
        await _sleep(60);
        continue;
      }
      executedVisible = true;
    }

    if (!_fastReplay) _stepHistory.push(_currentStep);

    _isStepping = false;
    _setBtnsAfterAction();
  }

  async function prev() {
    if (_isPlaying || _isStepping) return;
    if (_stepHistory.length === 0) return;
    _isStepping = true;
    _setBtnsDuringPlaying(true);

    // Pop current landing, compute target = previous landing (or 0)
    _stepHistory.pop();
    const target = _stepHistory.length > 0 ? _stepHistory[_stepHistory.length - 1] : 0;

    // Preserve history across reset (reset clears it)
    const savedHistory = [..._stepHistory];
    reset({ keepScenario: true });
    _stepHistory = savedHistory;

    // Fast-replay 0 → target with sleep() short-circuited
    _fastReplay = true;
    for (let i = 0; i < target; i++) {
      await _executeStep(_steps[i]);
      _currentStep = i + 1;
    }
    _fastReplay = false;
    _updateCounter();

    _isStepping = false;
    _setBtnsAfterAction();
  }

  function reset(opts = {}) {
    _isPlaying = false;
    _isStepping = false;
    _currentStep = 0;
    _stepHistory = [];
    if (!opts.keepScenario && _config && _activeScenario) {
      // Re-resolve steps in case scenarios was mutated
      _steps = _resolveSteps(_activeScenario);
    } else if (_activeScenario && _config) {
      _steps = _resolveSteps(_activeScenario);
    }
    _updateCounter();

    // Reset UI state of player controls
    const play = _q('spt-play-btn');
    const step = _q('spt-step-btn');
    const prev = _q('spt-prev-btn');
    if (play) { play.disabled = false; play.innerHTML = '▶ 自动播放'; }
    if (step) step.disabled = false;
    if (prev) prev.disabled = true;

    // Notify consumer (lets them clear their DOM)
    if (_config && _config.onReset) {
      try { _config.onReset(_activeScenario); } catch (e) { console.error('[scenario-playback-toolkit] onReset error:', e); }
    }
  }

  function setScenario(scenarioId) {
    if (!_config.scenarios[scenarioId]) {
      console.warn('[scenario-playback-toolkit] Unknown scenarioId:', scenarioId);
      return;
    }
    _activeScenario = scenarioId;
    _steps = _resolveSteps(scenarioId);
    reset({ keepScenario: true });
    // Update active button visual
    document.querySelectorAll('.spt-scenario-btn').forEach(btn => {
      btn.classList.toggle('active', btn.dataset.scenarioId === scenarioId);
    });
  }

  function _resolveSteps(scenarioId) {
    const scenario = _config.scenarios[scenarioId];
    if (!scenario) return [];
    if (typeof scenario.steps === 'function') return scenario.steps();
    if (Array.isArray(scenario.steps)) return scenario.steps;
    if (typeof _config.buildSteps === 'function') return _config.buildSteps(scenarioId, scenario);
    return [];
  }

  function currentState() {
    return {
      activeScenario: _activeScenario,
      currentStep: _currentStep,
      totalSteps: _steps.length,
      isPlaying: _isPlaying,
      isStepping: _isStepping,
      stepHistoryLength: _stepHistory.length,
    };
  }

  // ----- Initialization -----

  function _renderScenarioButtons() {
    const host = _q('spt-scenario-btns');
    if (!host) return;
    host.innerHTML = '';
    (_config.scenarioButtons || []).forEach(btn => {
      const el = document.createElement('button');
      el.type = 'button';
      el.className = 'spt-scenario-btn';
      el.dataset.scenarioId = btn.id;
      if (btn.id === _activeScenario) el.classList.add('active');
      let html = '';
      if (btn.colorDot) html += `<span class="spt-scenario-color-dot ${btn.colorDot}"></span>`;
      html += btn.label || btn.id;
      el.innerHTML = html;
      el.addEventListener('click', () => setScenario(btn.id));
      host.appendChild(el);
    });
  }

  function _bindKeyboard() {
    if (_config.keyboardShortcuts === false) return;
    document.addEventListener('keydown', (e) => {
      const tag = e.target && e.target.tagName;
      if (tag === 'INPUT' || tag === 'TEXTAREA' || (e.target && e.target.isContentEditable)) return;
      switch (e.key) {
        case ' ':
        case 'ArrowRight':
          e.preventDefault();
          api.step();
          break;
        case 'ArrowLeft':
          e.preventDefault();
          api.prev();
          break;
        case 'Enter':
          e.preventDefault();
          api.play();
          break;
        case 'Escape':
        case 'r':
        case 'R':
          e.preventDefault();
          api.reset();
          break;
      }
    });
  }

  function init(config) {
    if (!config) throw new Error('[scenario-playback-toolkit] init requires a config object');
    _config = Object.assign({
      scenarios: {},
      scenarioButtons: [],
      microStepTypes: ['wait'],
      executeStepCustom: null,
      onReset: null,
      keyboardShortcuts: true,
      interStepDelayMs: 380,
      initialScenarioId: null,
    }, config);
    // Coerce microStepTypes into a Set
    _config.microStepTypes = new Set(_config.microStepTypes);

    // Determine initial scenario
    _activeScenario = _config.initialScenarioId
      || (_config.scenarioButtons[0] && _config.scenarioButtons[0].id)
      || Object.keys(_config.scenarios)[0]
      || null;

    if (_activeScenario) {
      _steps = _resolveSteps(_activeScenario);
    }

    _renderScenarioButtons();
    _bindButtonsAndKeyboard();
    _updateCounter();

    // Trigger initial reset to let consumer set up their DOM
    if (_config.onReset) {
      try { _config.onReset(_activeScenario); } catch (e) { console.error('[scenario-playback-toolkit] onReset error:', e); }
    }
  }

  function _bindButtonsAndKeyboard() {
    const play = _q('spt-play-btn');
    const step = _q('spt-step-btn');
    const prev = _q('spt-prev-btn');
    const reset_ = _q('spt-reset-btn');
    if (play) play.addEventListener('click', () => api.play());
    if (step) step.addEventListener('click', () => api.step());
    if (prev) prev.addEventListener('click', () => api.prev());
    if (reset_) reset_.addEventListener('click', () => api.reset());
    _bindKeyboard();
  }

  // ----- Public API -----

  const api = {
    init,
    play,
    step,
    prev,
    reset,
    setScenario,
    currentState,
  };

  global.scenarioPlayback = api;
})(typeof window !== 'undefined' ? window : globalThis);
