// Load for the order validation API, run inside the cluster:
//   scripts/load.sh steady 5m    a normal day: 40 validations a second
//   scripts/load.sh flash 20m    the Saturday 15:00 flash sale: 600 a second
import http from 'k6/http';
import { check } from 'k6';

const API = __ENV.API_URL || 'http://order-validation:8080';
const SCENARIO = __ENV.SCENARIO || 'steady';
const DURATION = __ENV.DURATION || '5m';

const scenarios = {
  steady: { executor: 'constant-arrival-rate', rate: 40, timeUnit: '1s', duration: DURATION,
            preAllocatedVUs: 20, maxVUs: 200 },
  // From 40 to 600 a second in 30 s, held for DURATION, then back down.
  flash: { executor: 'ramping-arrival-rate', startRate: 40, timeUnit: '1s', preAllocatedVUs: 200, maxVUs: 1000,
           stages: [{ target: 600, duration: '30s' }, { target: 600, duration: DURATION }, { target: 40, duration: '30s' }] },
};

export const options = {
  scenarios: { [SCENARIO]: scenarios[SCENARIO] },
  // The SLO, as the caller sees it: at most 1 in 2,000 validations fails or takes over 250 ms.
  thresholds: {
    'checks{kind:order}': ['rate>0.9995'],
    'http_req_duration{kind:order}': ['p(99.95)<250'],
  },
  summaryTrendStats: ['avg', 'p(50)', 'p(99)', 'p(99.95)', 'max'],
};

// A realistic mix from the seed data. Prices come from the fake: the SKU number x 100.
function order() {
  const r = Math.random();
  if (r < 0.80) {                                       // 80% valid: 1-3 everyday items, right price
    const lines = [];
    const used = new Set();
    const n = 1 + Math.floor(Math.random() * 3);
    while (lines.length < n) {
      const i = 1 + Math.floor(Math.random() * 45);
      if (used.has(i)) continue;
      used.add(i);
      lines.push({ sku: `SKU-${String(i).padStart(4, '0')}`, quantity: 1 + Math.floor(Math.random() * 3), unit_price: i * 100 });
    }
    return { items: lines };
  }
  if (r < 0.88) return { items: [{ sku: 'SKU-0046', quantity: 1, unit_price: 4600 }] };   // 8% out of stock
  if (r < 0.95) return { items: [{ sku: 'SKU-0001', quantity: 1, unit_price: 90 }] };     // 7% price changed
  if (r < 0.98) return { items: [{ sku: 'SKU-0048', quantity: 3, unit_price: 4800 }] };   // 3% over the TV's limit
  return { items: [{ sku: 'SKU-0001', quantity: 0, unit_price: 100 }] };                  // 2% malformed (400)
}

export default function () {
  const body = order();
  const malformed = body.items[0].quantity === 0;
  const res = http.post(`${API}/orders/validate`, JSON.stringify(body),
    { headers: { 'Content-Type': 'application/json' }, tags: { kind: 'order' }, timeout: '2s' });
  // A refusal (200, valid: false) and a 400 for a malformed order are correct answers.
  check(res, { 'answered as expected': (r) => r.status === (malformed ? 400 : 200) }, { kind: 'order' });
}
