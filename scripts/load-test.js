/**
 * k6 load test for SecureShip API
 *
 * Validates SLOs under realistic and spike traffic patterns.
 * Run with Docker (no k6 install needed):
 *   make load-test
 *
 * Or directly:
 *   docker run --rm -v $(pwd)/scripts:/scripts \
 *     --network observeops_observeops grafana/k6 \
 *     run /scripts/load-test.js --env BASE_URL=http://secureship:8001
 */

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';

const errorRate = new Rate('error_rate');
const rateLimitRate = new Rate('rate_limited');

export const options = {
  stages: [
    { duration: '30s', target: 10  },  // ramp up — normal traffic
    { duration: '1m',  target: 50  },  // steady state
    { duration: '30s', target: 120 },  // spike — should trigger rate limiter (>100/min)
    { duration: '30s', target: 0   },  // ramp down
  ],
  thresholds: {
    // SLO: 95th percentile latency under 500ms
    http_req_duration: ['p(95)<500'],
    // SLO: error rate under 1% (429s excluded — rate limiting is expected behaviour)
    error_rate: ['rate<0.01'],
  },
};

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8001';
const API_KEY  = __ENV.API_KEY  || '';
const headers  = API_KEY
  ? { 'X-API-Key': API_KEY, 'Content-Type': 'application/json' }
  : { 'Content-Type': 'application/json' };

export default function () {
  // List ships
  const listRes = http.get(`${BASE_URL}/api/v1/ships?limit=10`, { headers });
  check(listRes, {
    'list: 200 OK':         (r) => r.status === 200,
    'list: has ships key':  (r) => JSON.parse(r.body).ships !== undefined,
    'list: has pagination': (r) => JSON.parse(r.body).has_more !== undefined,
  });
  errorRate.add(listRes.status >= 500);
  rateLimitRate.add(listRes.status === 429);

  sleep(0.1);

  // Get single ship
  const getRes = http.get(`${BASE_URL}/api/v1/ships/ship-001`, { headers });
  check(getRes, {
    'get: 200 or 404': (r) => r.status === 200 || r.status === 404,
  });
  errorRate.add(getRes.status >= 500);

  sleep(0.1);

  // Health check — should always be fast
  const healthRes = http.get(`${BASE_URL}/health`);
  check(healthRes, {
    'health: 200 OK':         (r) => r.status === 200,
    'health: status healthy': (r) => JSON.parse(r.body).status === 'healthy',
  });

  sleep(0.2);
}
