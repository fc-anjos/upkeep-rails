// Shared configuration and options builder for benchmark scenarios.

export const BASE_URL = __ENV.BASE_URL || "http://localhost:3000";
// Clients connect directly to dispatch's `WSServer`, which verifies
// the signed `data-context-token` embedded in the page render. The
// dispatch runtime owns per-connection state.
export const WS_URL = __ENV.WS_URL || "ws://localhost:9393";
export const RELAY_WS_URL = WS_URL;
export const NUM_USERS = parseInt(__ENV.NUM_USERS || "200");
export const ITERATIONS = parseInt(__ENV.ITERATIONS || "20");
export const BOARD_ID = __ENV.BOARD_ID || "1";
export const ROOM_ID = __ENV.ROOM_ID || "1";
export const PUMA_WORKERS = parseInt(__ENV.PUMA_WORKERS || "2", 10);
export const PUMA_THREADS = parseInt(__ENV.PUMA_THREADS || "5", 10);
export const LISTEN_BACKLOG = parseInt(__ENV.LISTEN_BACKLOG || "128", 10);

// Workload presets. BENCH_TIER selects which to use.
// `gate` is the default for fast regression feedback.
//
// Smoke is not in this map — it uses `per-vu-iterations` below instead
// of `ramping-vus`. See `buildSmokeOptions` for rationale.
const STAGE_PRESETS = {
  gate: [
    { duration: "10s", target: 20 },
    { duration: "10s", target: 20 },
    { duration: "10s", target: 200 },
    { duration: "10s", target: 200 },
    { duration: "10s", target: 500 },
    { duration: "10s", target: 500 },
    { duration: "5s", target: 0 },
  ],
  report: [
    { duration: "30s", target: 50 },
    { duration: "60s", target: 50 },
    { duration: "30s", target: 200 },
    { duration: "60s", target: 200 },
    { duration: "60s", target: 1000 },
    { duration: "120s", target: 1000 },
    { duration: "30s", target: 0 },
  ],
};

const COLD_VU_PRESETS = {
  gate: 500,
  report: 1000,
};

const COLD_STAGE_INTERVAL_MS_PRESETS = {
  gate: 2000,
  report: 3000,
};

const COLD_STEADY_MS_PRESETS = {
  gate: 20000,
  report: 60000,
};

const WARM_VU_PRESETS = {
  gate: 500,
  report: 1000,
};

const WARM_MAX_DURATION_PRESETS = {
  gate: "180s",
  report: "420s",
};

const WARM_STAGE_INTERVAL_MS_PRESETS = {
  gate: 2000,
  report: 4000,
};

const WARM_SETTLE_MS_PRESETS = {
  gate: 5000,
  report: 10000,
};

let cachedWarmSetupProfile = null;

export function buildOptions(overrides = {}) {
  if (__ENV.SKIP_OPTIONS) return {};

  const tier = __ENV.BENCH_TIER || "gate";

  if (tier === "smoke") return buildSmokeOptions(overrides);

  const stages = STAGE_PRESETS[tier] || STAGE_PRESETS.gate;

  return {
    // Include p(50) and p(99) — k6's default stats omit these.
    summaryTrendStats: ["avg", "min", "med", "max", "p(50)", "p(90)", "p(95)", "p(99)"],
    scenarios: {
      default: {
        executor: "ramping-vus",
        startVUs: 0,
        stages,
        gracefulStop: "30s",
        gracefulRampDown: "30s",
        ...overrides,
      },
    },
  };
}

// Admission capacity sized to the running Puma config. Cold-connect
// (ramping-vus) and warm steady-state (per-vu-iterations) both admit
// VUs in waves computed from these three numbers.
function admissionCapacity() {
  const workerCapacity = Math.max(1, PUMA_WORKERS * PUMA_THREADS);
  const backlog = Math.max(workerCapacity, LISTEN_BACKLOG);
  const admissionCeiling = Math.max(workerCapacity, Math.min(backlog, workerCapacity * 8));
  return { workerCapacity, backlog, admissionCeiling };
}

// Wave schedule that admits `target` VUs in chunks of `workerCapacity`,
// doubling each wave up to `admissionCeiling`. Returns one size per
// wave; callers map sizes to stage durations or delay offsets.
function computeAdmissionWaves(target, { workerCapacity, admissionCeiling }) {
  const waves = [];
  let admitted = 0;
  let waveSize = workerCapacity;
  while (admitted < target) {
    const remaining = target - admitted;
    const size = Math.min(remaining, Math.max(workerCapacity, Math.min(admissionCeiling, waveSize)));
    waves.push(size);
    admitted += size;
    waveSize = Math.min(admissionCeiling, waveSize * 2);
  }
  return waves;
}

// Cold-connect ramp. Admits VUs in hardware-sized waves spaced
// `stageIntervalMs` apart, peaks at the tier target, and holds steady
// for `steadyMs` so capacity thresholds evaluate against a stable
// window. Ramping-vus executor = continuous login/WS/subscribe churn
// at each target level.
export function buildColdAdmissionOptions(overrides = {}) {
  if (__ENV.SKIP_OPTIONS) return {};

  const tier = __ENV.BENCH_TIER || "gate";
  if (tier === "smoke") return buildSmokeOptions(overrides);

  const target = parseInt(
    __ENV.BENCH_VUS || `${COLD_VU_PRESETS[tier] || COLD_VU_PRESETS.gate}`,
    10,
  );
  const capacity = admissionCapacity();
  const stageIntervalMs = COLD_STAGE_INTERVAL_MS_PRESETS[tier] || COLD_STAGE_INTERVAL_MS_PRESETS.gate;
  const steadyMs = COLD_STEADY_MS_PRESETS[tier] || COLD_STEADY_MS_PRESETS.gate;
  const waves = computeAdmissionWaves(target, capacity);

  const stages = [];
  let admitted = 0;
  for (const size of waves) {
    admitted += size;
    stages.push({ duration: `${stageIntervalMs}ms`, target: admitted });
  }
  stages.push({ duration: `${steadyMs}ms`, target });
  stages.push({ duration: "5s", target: 0 });

  return {
    summaryTrendStats: ["avg", "min", "med", "max", "p(50)", "p(90)", "p(95)", "p(99)"],
    scenarios: {
      default: {
        executor: "ramping-vus",
        startVUs: 0,
        stages,
        gracefulStop: "30s",
        gracefulRampDown: "30s",
        ...overrides,
      },
    },
  };
}

// Smoke is a regression gate, not a load test. `ramping-vus` is
// wall-time bounded, so a slow first-render or an unresponsive receive
// gets the VU interrupted mid-iteration and produces "0 complete"
// runs that the gate cannot distinguish from a genuinely broken
// pipeline. `per-vu-iterations` instead guarantees each VU either
// completes its iterations or k6 fails loudly at maxDuration —
// exactly the indicator the gate wants.
function buildSmokeOptions(overrides = {}) {
  return {
    summaryTrendStats: ["avg", "min", "med", "max", "p(50)", "p(90)", "p(95)", "p(99)"],
    scenarios: {
      default: {
        executor: "per-vu-iterations",
        vus: 3,
        iterations: parseInt(__ENV.ITERATIONS || "1"),
        maxDuration: "45s",
        ...overrides,
      },
    },
  };
}

export function buildWarmSteadyStateOptions(overrides = {}) {
  const tier = __ENV.BENCH_TIER || "gate";
  const vus = warmSetupProfile().vus;
  const maxDuration = WARM_MAX_DURATION_PRESETS[tier] || WARM_MAX_DURATION_PRESETS.gate;

  return {
    summaryTrendStats: ["avg", "min", "med", "max", "p(50)", "p(90)", "p(95)", "p(99)"],
    scenarios: {
      default: {
        executor: "per-vu-iterations",
        vus,
        iterations: 1,
        maxDuration,
        ...overrides,
      },
    },
  };
}

export function warmSetupProfile() {
  if (cachedWarmSetupProfile) return cachedWarmSetupProfile;

  const tier = __ENV.BENCH_TIER || "gate";
  const vus = parseInt(__ENV.BENCH_VUS || `${WARM_VU_PRESETS[tier] || WARM_VU_PRESETS.gate}`, 10);
  const capacity = admissionCapacity();
  const stageIntervalMs = WARM_STAGE_INTERVAL_MS_PRESETS[tier] || WARM_STAGE_INTERVAL_MS_PRESETS.gate;
  const settleMs = WARM_SETTLE_MS_PRESETS[tier] || WARM_SETTLE_MS_PRESETS.gate;
  const waves = computeAdmissionWaves(vus, capacity);

  cachedWarmSetupProfile = {
    admissionCeiling: capacity.admissionCeiling,
    backlog: capacity.backlog,
    setupWindowMs: (waves.length * stageIntervalMs) + settleMs,
    settleMs,
    stageIntervalMs,
    vus,
    waves,
    workerCapacity: capacity.workerCapacity,
  };

  return cachedWarmSetupProfile;
}

export function warmSetupWindowMs() {
  return warmSetupProfile().setupWindowMs;
}

export function warmSetupAdmissionForVu(vuNumber) {
  const profile = warmSetupProfile();
  let offset = 0;

  for (let waveIndex = 0; waveIndex < profile.waves.length; waveIndex++) {
    const size = profile.waves[waveIndex];
    if (vuNumber <= offset + size) {
      // Distribute wave members uniformly across the stage interval so
      // `size` VUs don't all land on Puma at the exact same tick. With
      // workerCapacity=10 and admissionCeiling=80, a bursty wave serializes
      // 80 logins onto 10 slots and trips steady_state_setup_leaks.
      const positionInWave = vuNumber - offset - 1;
      const intraWaveMs = size > 1
        ? (positionInWave / size) * profile.stageIntervalMs
        : 0;
      return {
        delayMs: (waveIndex * profile.stageIntervalMs) + intraWaveMs,
        waveIndex,
        waveSize: size,
        ...profile,
      };
    }
    offset += size;
  }

  return {
    delayMs: 0,
    waveIndex: 0,
    waveSize: profile.workerCapacity,
    ...profile,
  };
}
