export interface WebReplaySlotBinding {
  slotId: string;
  componentId: string;
  applicationId: string;
  sessionId: string;
  viewId: string;
  active: boolean;
  inactiveAt: number;
}

/** The slot is the serialized native wireframe ID, never a generated alias. */
export interface WebReplaySlotObservation {
  componentId: string;
  slotId: string;
}

/** Scalar identities only: no ArkUI nodes or Web controllers are retained. */
export class WebReplaySlotBinder {
  private readonly slots: Map<string, WebReplaySlotBinding> = new Map();
  private latestSlotId: string = '';
  private conflicts: Set<string> = new Set();

  public register(componentId: string): boolean {
    if (componentId.trim().length === 0 || this.slots.has(componentId) || this.slots.size >= 20) return false;
    this.slots.set(componentId, {
      slotId: '', componentId, applicationId: '', sessionId: '', viewId: '', active: false, inactiveAt: 0
    });
    return true;
  }

  public getSlotId(componentId: string): string {
    return this.slots.get(componentId)?.slotId ?? '';
  }

  public get(slotId: string): WebReplaySlotBinding | null {
    if (slotId.length === 0) return null;
    for (const binding of this.slots.values()) {
      if (binding.slotId === slotId) return this.getComponent(binding.componentId);
    }
    return null;
  }

  public getComponent(componentId: string): WebReplaySlotBinding | null {
    const binding = this.slots.get(componentId);
    return binding === undefined ? null : {
      slotId: binding.slotId, componentId: binding.componentId, applicationId: binding.applicationId,
      sessionId: binding.sessionId, viewId: binding.viewId,
      active: binding.active, inactiveAt: binding.inactiveAt
    };
  }

  /** Native collection, rather than proxy registration, establishes visibility. */
  public observe(applicationId: string, sessionId: string, viewId: string,
    visibleSlots: Array<WebReplaySlotObservation>, timestamp: number): void {
    const visible: Map<string, string> = new Map();
    const owners: Map<string, string> = new Map();
    this.conflicts.clear();
    for (const observation of visibleSlots) {
      const id = Number(observation.slotId);
      if (this.slots.has(observation.componentId) && Number.isSafeInteger(id) && id > 0 && String(id) === observation.slotId) {
        const previous = visible.get(observation.componentId);
        const owner = owners.get(observation.slotId);
        if (previous !== undefined && previous !== observation.slotId) this.conflicts.add(observation.componentId);
        if (owner !== undefined && owner !== observation.componentId) {
          this.conflicts.add(owner);
          this.conflicts.add(observation.componentId);
        }
        visible.set(observation.componentId, observation.slotId);
        owners.set(observation.slotId, observation.componentId);
      }
    }
    const previousLatest = this.latestSlotId;
    this.latestSlotId = '';
    for (const binding of this.slots.values()) {
      if (this.conflicts.has(binding.componentId)) {
        // Ambiguous matches must not retain an old slot, including its drain grace period.
        binding.slotId = '';
        binding.applicationId = '';
        binding.sessionId = '';
        binding.viewId = '';
        binding.active = false;
        binding.inactiveAt = 0;
        continue;
      }
      const slotId = visible.get(binding.componentId);
      if (slotId === undefined) {
        if (binding.active && binding.inactiveAt === 0) binding.inactiveAt = timestamp;
        binding.active = false;
        continue;
      }
      binding.applicationId = applicationId;
      binding.sessionId = sessionId;
      binding.viewId = viewId;
      binding.slotId = slotId;
      binding.active = true;
    }
    // Preserve the single-active-slot policy; snapshot order defines paint order here.
    for (const observation of visibleSlots) {
      const binding = this.slots.get(observation.componentId);
      if (binding?.active && binding.slotId === observation.slotId) this.latestSlotId = binding.slotId;
    }
    for (const binding of this.slots.values()) {
      if (binding.slotId === this.latestSlotId) binding.inactiveAt = 0;
      else if (binding.slotId === previousLatest && binding.inactiveAt === 0) binding.inactiveAt = timestamp;
    }
  }

  public getComponentIds(): Array<string> { return Array.from(this.slots.keys()); }
  public getConflictedComponentIds(): Array<string> { return Array.from(this.conflicts).sort(); }

  public accepts(slotId: string, applicationId: string, sessionId: string, timestamp: number): boolean {
    return this.getRejectionReason(slotId, applicationId, sessionId, timestamp).length === 0;
  }

  /** Empty means accepted, including the existing two-second inactive-slot drain grace. */
  public getRejectionReason(slotId: string, applicationId: string, sessionId: string, timestamp: number): string {
    const binding = this.get(slotId);
    if (binding === null) return 'slot_unbound';
    if (binding.viewId.length === 0) return 'native_view_missing';
    if (binding.applicationId !== applicationId) return 'application_mismatch';
    if (binding.sessionId !== sessionId) return 'session_mismatch';
    if (binding.active && this.latestSlotId === slotId) return '';
    if (binding.inactiveAt > 0 && timestamp >= binding.inactiveAt && timestamp - binding.inactiveAt < 2000) return '';
    return binding.inactiveAt > 0 && timestamp - binding.inactiveAt >= 2000
      ? 'slot_drain_grace_expired' : 'slot_inactive';
  }

  public getLatestSlotId(): string { return this.latestSlotId; }

  public unregister(componentId: string): void {
    const slotId = this.getSlotId(componentId);
    this.slots.delete(componentId);
    if (this.latestSlotId === slotId) this.latestSlotId = '';
  }

  /** Keep registration for restart, but discard all old RUM associations. */
  public resetBindings(timestamp: number): void {
    this.latestSlotId = '';
    this.conflicts.clear();
    for (const binding of this.slots.values()) {
      binding.applicationId = '';
      binding.sessionId = '';
      binding.viewId = '';
      binding.slotId = '';
      binding.active = false;
      binding.inactiveAt = timestamp;
    }
  }
}
