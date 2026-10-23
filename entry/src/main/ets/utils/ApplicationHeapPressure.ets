import { hidebug } from '@kit.PerformanceAnalysisKit';

/** All retained objects belong to the application fixture, never to an SDK queue. */
class ApplicationHeapCell {
  readonly values: number[] = new Array<number>(96);
  readonly attributes: Map<string, number> = new Map();
  readonly read: () => number;

  constructor(id: number) {
    for (let i = 0; i < 96; i++) this.values[i] = id + i;
    this.attributes.set('id', id);
    this.attributes.set('value', id + 1);
    this.read = (): number => this.values[0];
  }
}

interface ApplicationMetadataCell {
  read(): number;
}

function createApplicationMetadataCell(id: number): ApplicationMetadataCell {
  // Deliberate application-owned class churn, separate from ordinary heap filling.
  class ApplicationLocalClass implements ApplicationMetadataCell {
    private value: number = id;
    read(): number { return this.value; }
  }
  return new ApplicationLocalClass();
}

export class ApplicationHeapSnapshot {
  heapUsedKB: number = 0;
  totalHeapKB: number = 0;
  vmHeapLimitKB: number = 0;
  targetMiB: number = 273;
  retainedCells: number = 0;
  retainedLocalClasses: number = 0;
  phase: string = 'IDLE';
}

export function heapPressureDelay(ms: number): Promise<void> {
  return new Promise<void>((resolve): void => { setTimeout(resolve, ms); });
}

/** Main-thread JS heap only: no ArrayBuffer, native allocation, Worker or SDK imports. */
export class ApplicationHeapPressure {
  private cells: ApplicationHeapCell[][] = [];
  private metadata: ApplicationMetadataCell[][] = [];
  private cellCount: number = 0;
  private classCount: number = 0;
  private generation: number = 0;
  private busy: boolean = false;
  private hasAllocated: boolean = false;
  private phase: string = 'IDLE';
  private targetMiB: number = 273;

  isBusy(): boolean { return this.busy; }
  canFill(): boolean { return !this.busy && !this.hasAllocated; }

  snapshot(): ApplicationHeapSnapshot {
    const memory = hidebug.getAppVMMemoryInfo();
    const limit = hidebug.getAppMemoryLimit();
    const result = new ApplicationHeapSnapshot();
    result.heapUsedKB = Number(memory.heapUsed);
    result.totalHeapKB = Number(memory.totalHeap);
    result.vmHeapLimitKB = Number(limit.vmHeapLimit);
    result.targetMiB = this.targetMiB;
    result.retainedCells = this.cellCount;
    result.retainedLocalClasses = this.classCount;
    result.phase = this.phase;
    if (!Number.isFinite(result.heapUsedKB) || result.heapUsedKB <= 0 ||
      !Number.isFinite(result.vmHeapLimitKB) || result.vmHeapLimitKB <= 0) {
      throw new Error('无法取得有效的主线程 VM 堆测量值');
    }
    return result;
  }

  async fill(targetMiB: number, progress: () => void): Promise<void> {
    if (this.busy) throw new Error('应用堆填充正在运行');
    if (this.hasAllocated) throw new Error('本轮已分配过对象，请冷启动新一轮，避免把待 GC 内存算作新基线');
    if (!Number.isFinite(targetMiB) || targetMiB < 32 || targetMiB > 300) {
      throw new Error('目标必须为 32–300 MiB');
    }
    const initial = this.snapshot();
    if ((targetMiB + 32) * 1024 > initial.vmHeapLimitKB) {
      throw new Error('目标距离当前 VM 堆上限不足 32 MiB，请降低目标');
    }
    if (initial.heapUsedKB > (targetMiB + 1) * 1024) {
      throw new Error('当前堆已高于目标，请释放应用对象或冷启动后重试');
    }
    this.busy = true;
    const generation = ++this.generation;
    this.targetMiB = targetMiB;
    this.phase = 'FILLING';
    let stableSamples = 0;
    let batches = 0;
    const deadline = Date.now() + 120000;
    try {
      while (this.generation === generation) {
        const current = this.snapshot();
        if (current.heapUsedKB > (targetMiB + 2) * 1024) {
          this.phase = 'OVERSHOT';
          throw new Error('实测堆超过目标 2 MiB；停止填充，本轮不标记为达标');
        }
        if (current.heapUsedKB >= (targetMiB - 1) * 1024) {
          this.phase = 'SETTLING';
          progress();
          if (++stableSamples >= 5) {
            this.phase = 'HOLDING';
            break;
          }
          await heapPressureDelay(400);
          continue;
        }
        stableSamples = 0;
        this.phase = 'FILLING';
        if (Date.now() > deadline || this.cellCount >= 500000) {
          throw new Error('未在时间/对象数量边界内达到目标，停止填充');
        }
        const batch: ApplicationHeapCell[] = [];
        this.hasAllocated = true;
        // Small batches bound overshoot and yield often enough to keep the UI responsive.
        const size = current.heapUsedKB > (targetMiB - 4) * 1024 ? 16 : 512;
        for (let i = 0; i < size; i++) batch.push(new ApplicationHeapCell(this.cellCount++));
        this.cells.push(batch);
        if (++batches % 32 === 0) progress();
        await heapPressureDelay(4);
      }
    } catch (error) {
      if (this.phase !== 'OVERSHOT') this.phase = 'ERROR';
      throw new Error(String(error));
    } finally {
      this.busy = false;
      progress();
    }
  }

  async addLocalClasses(progress: () => void): Promise<void> {
    if (this.busy) throw new Error('应用分配正在运行');
    if (this.cellCount === 0) throw new Error('请先完成应用堆预填充');
    this.busy = true;
    const generation = ++this.generation;
    this.phase = 'APPLICATION_CLASS_PRESSURE';
    try {
      for (let batchIndex = 0; batchIndex < 10 && this.generation === generation; batchIndex++) {
        const batch: ApplicationMetadataCell[] = [];
        for (let i = 0; i < 100; i++) batch.push(createApplicationMetadataCell(this.classCount++));
        this.metadata.push(batch);
        progress();
        await heapPressureDelay(20);
      }
      if (this.generation === generation) this.phase = 'HOLDING';
    } finally {
      this.busy = false;
      progress();
    }
  }

  /** Deliberately exhaust the real VM using application-owned references, never a synthetic exception. */
  async runUntilOOM(mode: string, progress: () => void, durationMs: number = 180000): Promise<void> {
    if (mode !== 'heap' && mode !== 'classes') throw new Error('未知的持续压力模式');
    if (!Number.isFinite(durationMs) || durationMs < 4 || durationMs > 180000) {
      throw new Error('持续压力时长必须为 4–180000 ms');
    }
    if (this.busy) throw new Error('应用分配正在运行');
    if (this.cellCount === 0 || this.phase !== 'HOLDING') throw new Error('请先完成预填充');
    this.busy = true;
    const generation = ++this.generation;
    const deadline = Date.now() + durationMs;
    this.phase = mode === 'heap' ? 'CONTINUOUS_HEAP_PRESSURE' : 'CONTINUOUS_CLASS_PRESSURE';
    let batches = 0;
    try {
      progress();
      while (this.generation === generation && Date.now() < deadline) {
        if (mode === 'heap') {
          const batch: ApplicationHeapCell[] = [];
          this.cells.push(batch);
          for (let i = 0; i < 512; i++) {
            batch.push(new ApplicationHeapCell(this.cellCount));
            this.cellCount++;
          }
        } else {
          const batch: ApplicationMetadataCell[] = [];
          this.metadata.push(batch);
          for (let i = 0; i < 128; i++) {
            batch.push(createApplicationMetadataCell(this.classCount));
            this.classCount++;
          }
        }
        if (++batches % 16 === 0) progress();
        await heapPressureDelay(4);
      }
      if (this.generation === generation) this.phase = 'NO_OOM_WITHIN_TIME_LIMIT';
    } finally {
      this.busy = false;
      progress();
    }
  }

  cancel(): void {
    this.generation++;
    this.phase = 'STOPPED';
  }

  release(): void {
    this.cancel();
    this.cells = [];
    this.metadata = [];
    this.cellCount = 0;
    this.classCount = 0;
    this.phase = 'RELEASED';
    // References are released here; actual reclamation is controlled by the VM's GC.
  }
}
