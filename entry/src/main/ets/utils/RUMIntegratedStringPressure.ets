/** Bounded application allocations only. Never fills the heap or forces GC/native faults. */
export class RUMIntegratedStringPressure {
  private slots: string[][] = [];
  private nextSlot: number = 0;

  step(seed: string): number {
    const batch: string[] = [];
    const prefix = seed.slice(0, 128);
    for (let index = 0; index < 128; index++) {
      batch.push(`${prefix}:${index}:${'session-string-roundtrip-'.repeat(24)}`);
    }
    // Exercise ordinary string/JSON allocation, not SDK state or VM internals.
    this.slots[this.nextSlot] = JSON.parse(JSON.stringify(batch)) as string[];
    this.nextSlot = (this.nextSlot + 1) % 4;
    return batch.length;
  }

  retainedChars(): number {
    let chars = 0;
    for (const slot of this.slots) {
      for (const value of slot) chars += value.length;
    }
    return chars;
  }

  clear(): void { this.slots = []; this.nextSlot = 0; }
}
