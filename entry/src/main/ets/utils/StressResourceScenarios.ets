export type StressResourceClient = 'rcp' | 'http' | 'axios' | 'mixed';
export type StressResourceScenario = 'custom' | 'mixed' | 'short' | 'long' | 'http-error' | 'timeout' | 'network-error';

export interface StressResourceClientOption {
  value: StressResourceClient;
  label: string;
}

export interface StressResourceScenarioOption {
  value: StressResourceScenario;
  label: string;
}

export interface StressResourceRequestPlan {
  client: StressResourceClient;
  scenario: StressResourceScenario;
  url: string;
  timeoutMs: number;
}

export const STRESS_RESOURCE_CLIENT_OPTIONS: StressResourceClientOption[] = [
  { value: 'mixed', label: 'Mixed (RCP / HTTP(S) / Axios)' },
  { value: 'rcp', label: 'RCP' },
  { value: 'http', label: 'HTTP(S)' },
  { value: 'axios', label: 'Axios' }
];

export const STRESS_RESOURCE_SCENARIO_OPTIONS: StressResourceScenarioOption[] = [
  { value: 'custom', label: 'Custom URLs' },
  { value: 'mixed', label: 'Mixed scenarios' },
  { value: 'short', label: 'Short request' },
  { value: 'long', label: 'Long request (5s)' },
  { value: 'http-error', label: 'HTTP errors (404 / 500)' },
  { value: 'timeout', label: 'Timeout (1s)' },
  { value: 'network-error', label: 'Connection failure' }
];

const RESOURCE_CLIENTS: StressResourceClient[] = ['rcp', 'http', 'axios'];
const MIXED_SCENARIOS: StressResourceScenario[] = [
  'short', 'long', 'http-error', 'http-error', 'timeout', 'network-error'
];

export function normalizeStressResourceClient(value: string): StressResourceClient {
  return value === 'rcp' || value === 'http' || value === 'axios' ? value : 'mixed';
}

export function normalizeStressResourceScenario(value: string): StressResourceScenario {
  for (let i = 0; i < STRESS_RESOURCE_SCENARIO_OPTIONS.length; i++) {
    if (STRESS_RESOURCE_SCENARIO_OPTIONS[i].value === value) {
      return STRESS_RESOURCE_SCENARIO_OPTIONS[i].value;
    }
  }
  return 'custom';
}

export function createStressResourceRequestPlan(
  clientMode: StressResourceClient,
  scenarioMode: StressResourceScenario,
  resourceIndex: number,
  customUrls: string[]
): StressResourceRequestPlan {
  const index = Math.max(0, Math.floor(resourceIndex));
  // Advance the scenario only after every client has exercised it.
  const caseIndex = clientMode === 'mixed' ? Math.floor(index / RESOURCE_CLIENTS.length) : index;
  const client = clientMode === 'mixed' ? RESOURCE_CLIENTS[index % RESOURCE_CLIENTS.length] : clientMode;
  const scenario = scenarioMode === 'mixed' ? MIXED_SCENARIOS[caseIndex % MIXED_SCENARIOS.length] : scenarioMode;
  let url = customUrls.length > 0 ? customUrls[caseIndex % customUrls.length] : '';
  let timeoutMs = 5 * 60 * 1000;
  switch (scenario) {
    case 'short':
      url = 'https://httpbin.org/get';
      timeoutMs = 15000;
      break;
    case 'long':
      url = 'https://httpbin.org/delay/5';
      timeoutMs = 60000;
      break;
    case 'http-error':
      url = `https://httpbin.org/status/${caseIndex % 2 === 0 ? 404 : 500}`;
      timeoutMs = 15000;
      break;
    case 'timeout':
      url = 'https://httpbin.org/delay/5';
      timeoutMs = 1000;
      break;
    case 'network-error':
      url = 'https://127.0.0.1:1/stress-resource';
      timeoutMs = 5000;
      break;
  }
  return { client, scenario, url, timeoutMs };
}

export function buildStressResourceUrl(
  plan: StressResourceRequestPlan,
  threadIndex: number,
  resourceIndex: number,
  timestampMs: number
): string {
  const fragmentIndex = plan.url.indexOf('#');
  const baseUrl = fragmentIndex >= 0 ? plan.url.substring(0, fragmentIndex) : plan.url;
  const fragment = fragmentIndex >= 0 ? plan.url.substring(fragmentIndex) : '';
  const separator = baseUrl.indexOf('?') >= 0 ? '&' : '?';
  return `${baseUrl}${separator}tag=stress_test&stress_thread=${threadIndex}&stress_resource=${resourceIndex}` +
    `&stress_client=${plan.client}&stress_scenario=${plan.scenario}&ts=${timestampMs}${fragment}`;
}
