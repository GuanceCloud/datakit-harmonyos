import { AppState } from '../rum/enum/RUMEnums';

export const CRASH_FREE_COMMITS_KEY = 'crashFreeCommits';
export const MAX_CRASH_FREE_COMMITS = 64;

export interface FTCrashFreeSnapshot {
  foregroundNs: number;
  backgroundNs: number;
  state: AppState;
  stateStartUptimeNs: number;
  observedUptimeNs: number;
  observedWallClockMs: number;
  bootMarkerMs: number;
  runId: string;
}

/** Local-only receipt, committed in the same transaction as its Error row. */
export interface FTCrashFreeCommit {
  reportToken: string;
  sourceRunId: string;
  nativeCrashId: string;
  recoveredSnapshotRunId: string;
  foregroundNs: number;
  backgroundNs: number;
  next: FTCrashFreeSnapshot | null;
}

export function decodeCrashFreeCommits(value: string): FTCrashFreeCommit[] {
  const commits = JSON.parse(value) as FTCrashFreeCommit[];
  if (!Array.isArray(commits) || commits.length > MAX_CRASH_FREE_COMMITS) {
    throw new Error('Invalid crash-free commit journal');
  }
  for (const commit of commits) {
    if (!commit || typeof commit.reportToken !== 'string' || commit.reportToken.length === 0 ||
      typeof commit.sourceRunId !== 'string' || typeof commit.nativeCrashId !== 'string' ||
      typeof commit.recoveredSnapshotRunId !== 'string' ||
      !Number.isFinite(commit.foregroundNs) || commit.foregroundNs < 0 ||
      !Number.isFinite(commit.backgroundNs) || commit.backgroundNs < 0 ||
      (commit.next !== null && (!commit.next || typeof commit.next.runId !== 'string' ||
        !Number.isFinite(commit.next.stateStartUptimeNs) || commit.next.stateStartUptimeNs < 0))) {
      throw new Error('Invalid crash-free commit receipt');
    }
  }
  return commits;
}

export function appendCrashFreeCommit(commits: FTCrashFreeCommit[], commit: FTCrashFreeCommit): FTCrashFreeCommit[] {
  if (commits.some((item: FTCrashFreeCommit): boolean => item.reportToken === commit.reportToken)) {
    return commits;
  }
  return commits.concat([commit]).slice(-MAX_CRASH_FREE_COMMITS);
}

/** Replays a durable reset against a possibly stale Preferences snapshot. */
export function applyCrashFreeCommit(
  snapshot: FTCrashFreeSnapshot,
  commit: FTCrashFreeCommit
): FTCrashFreeSnapshot | null {
  if (snapshot.runId !== commit.sourceRunId) {
    return snapshot;
  }
  const next = commit.next;
  if (next === null) {
    return null;
  }
  if (snapshot.observedUptimeNs < next.stateStartUptimeNs) {
    return next;
  }
  // Preserve lifecycle intervals settled after the crash boundary while
  // subtracting the already-reported prefix exactly once.
  return {
    foregroundNs: Math.max(0, snapshot.foregroundNs - commit.foregroundNs),
    backgroundNs: Math.max(0, snapshot.backgroundNs - commit.backgroundNs),
    state: snapshot.state,
    stateStartUptimeNs: Math.max(snapshot.stateStartUptimeNs, next.stateStartUptimeNs),
    observedUptimeNs: snapshot.observedUptimeNs,
    observedWallClockMs: snapshot.observedWallClockMs,
    bootMarkerMs: snapshot.bootMarkerMs,
    runId: next.runId
  };
}
