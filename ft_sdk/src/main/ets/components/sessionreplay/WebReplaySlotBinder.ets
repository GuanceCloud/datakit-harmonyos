export interface WebReplaySlotBinding {
  slotId: string;
  componentId: string;
  applicationId: string;
  sessionId: string;
  viewId: string;
  active: boolean;
  inactiveAt: number;
}

/** Scalar identities only: no ArkUI nodes or Web controllers are retained. */
export class WebReplaySlotBinder {
  private readonly slots: Map<string, WebReplaySlotBinding> = new Map();
  private latestSlotId: string = '';

  public register(slotId: string, componentId: string): boolean {
    if (slotId.length === 0 || componentId.trim().length === 0) return false;
    if (this.slots.has(slotId)) return this.slots.get(slotId)?.componentId === componentId;
    if (this.slots.size >= 20 || this.getSlotId(componentId).length > 0) return false;
    this.slots.set(slotId, {
      slotId, componentId, applicationId: '', sessionId: '', viewId: '', active: false, inactiveAt: 0
    });
    return true;
  }

  public getSlotId(componentId: string): string {
    for (const binding of this.slots.values()) {
      if (binding.componentId === componentId) return binding.slotId;
    }
    return '';
  }

  public get(slotId: string): WebReplaySlotBinding | null {
    const binding = this.slots.get(slotId);
    return binding === undefined ? null : {
      slotId: binding.slotId, componentId: binding.componentId, applicationId: binding.applicationId,
      sessionId: binding.sessionId, viewId: binding.viewId, active: binding.active, inactiveAt: binding.inactiveAt
    };
  }

  /** Native collection, rather than proxy registration, establishes visibility. */
  public observe(applicationId: string, sessionId: string, viewId: string,
    visibleSlots: Array<string>, timestamp: number): void {
    const visible = new Set<string>(visibleSlots);
    const previousLatest = this.latestSlotId;
    this.latestSlotId = '';
    for (const binding of this.slots.values()) {
      if (!visible.has(binding.slotId)) {
        if (binding.active && binding.inactiveAt === 0) binding.inactiveAt = timestamp;
        binding.active = false;
        continue;
      }
      binding.applicationId = applicationId;
      binding.sessionId = sessionId;
      binding.viewId = viewId;
      binding.active = true;
    }
    // Android uses one latest active slot; snapshot order defines paint order here.
    for (const slotId of visibleSlots) if (this.slots.get(slotId)?.active) this.latestSlotId = slotId;
    for (const binding of this.slots.values()) {
      if (binding.slotId === this.latestSlotId) binding.inactiveAt = 0;
      else if (binding.slotId === previousLatest && binding.inactiveAt === 0) binding.inactiveAt = timestamp;
    }
  }

  public getSlotIds(): Array<string> { return Array.from(this.slots.keys()); }

  public accepts(slotId: string, applicationId: string, sessionId: string, timestamp: number): boolean {
    const binding = this.slots.get(slotId);
    if (binding === undefined || binding.viewId.length === 0 || binding.applicationId !== applicationId ||
      binding.sessionId !== sessionId) return false;
    if (binding.active && this.latestSlotId === slotId) return true;
    return binding.inactiveAt > 0 && timestamp >= binding.inactiveAt && timestamp - binding.inactiveAt < 2000;
  }

  public getLatestSlotId(): string { return this.latestSlotId; }

  public unregister(slotId: string): void {
    this.slots.delete(slotId);
    if (this.latestSlotId === slotId) this.latestSlotId = '';
  }

  /** Keep registration for restart, but discard all old RUM associations. */
  public resetBindings(timestamp: number): void {
    this.latestSlotId = '';
    for (const binding of this.slots.values()) {
      binding.applicationId = '';
      binding.sessionId = '';
      binding.viewId = '';
      binding.active = false;
      binding.inactiveAt = timestamp;
    }
  }
}
