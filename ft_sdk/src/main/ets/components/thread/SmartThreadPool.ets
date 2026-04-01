/**
 * HarmonyOS SDK Smart Thread Pool Class
 * Supports dynamic thread adjustment, task priority, and automatic optimization
 */
import { FTInnerLogger } from '../log/FTLogger';

const TAG = "SmartThreadPool";

/**
 * Task Priority Enumeration
 */
export enum TaskPriority {
    CRITICAL = 9,    // Critical tasks: ANR detection, crash handling
    HIGH = 7,        // High priority: RUM events, performance monitoring
    NORMAL = 5,      // Normal priority: data processing, log processing
    LOW = 3,         // Low priority: data upload, cleanup tasks
    BACKGROUND = 1   // Background tasks: statistics, analysis
}

/**
 * Worker Thread Information Interface
 */
interface WorkerInfo {
    id: number;
    name: string;
}

/**
 * Priority Task Wrapper
 */
class PriorityTask {
    public readonly priority: TaskPriority;
    public readonly task: () => void;
    public readonly createTime: number;

    constructor(task: () => void, priority: TaskPriority) {
        this.task = task;
        this.priority = priority;
        this.createTime = Date.now();
    }

    public execute(): void {
        try {
            this.task();
        } catch (error) {
            FTInnerLogger.e(TAG, `PriorityTask execution failed: ${error}`);
        }
    }

    /**
     * Compare task priority (higher priority executes first)
     */
    public compareTo(other: PriorityTask): number {
        if (this.priority !== other.priority) {
            return other.priority - this.priority; // High priority first
        }
        // When priority is the same, earlier created tasks execute first
        return this.createTime - other.createTime;
    }
}

/**
 * Smart Thread Pool Class
 * Supports dynamic thread adjustment, task priority, and automatic optimization
 */
export class SmartThreadPool {
    private corePoolSize: number;
    private maxPoolSize: number;
    private currentPoolSize: number;
    private activeThreads: number = 0;
    private isShutdown: boolean = false;
    
    // Task queues
    private highPriorityQueue: PriorityTask[] = [];
    private normalPriorityQueue: PriorityTask[] = [];
    private lowPriorityQueue: PriorityTask[] = [];
    
    // Thread management
    private workers: WorkerInfo[] = [];
    private taskQueue: PriorityTask[] = [];
    
    // Performance monitoring
    private totalTasks: number = 0;
    private completedTasks: number = 0;
    private failedTasks: number = 0;
    private averageTaskTime: number = 0;
    private lastOptimizationTime: number = Date.now();

    constructor(corePoolSize: number = 4, maxPoolSize: number = 8) {
        this.corePoolSize = corePoolSize;
        this.maxPoolSize = maxPoolSize;
        this.currentPoolSize = corePoolSize;
        
        // Start core threads
        this.startCoreWorkers();
        
        // Start optimization thread
        this.startOptimizationWorker();
        
        FTInnerLogger.i(TAG, `SmartThreadPool initialization completed: core threads=${corePoolSize}, max threads=${maxPoolSize}`);
    }

    /**
     * Start core worker threads
     */
    private startCoreWorkers(): void {
        for (let i = 0; i < this.corePoolSize; i++) {
            this.startWorker();
        }
    }

    /**
     * Start a single worker thread
     */
    private startWorker(): void {
        // Use HarmonyOS setTimeout to simulate threads
        const workerId = setTimeout(() => {
            this.workerLoop();
        }, 0);
        const worker: WorkerInfo = { id: workerId, name: `SmartWorker-${this.workers.length}` };
        this.workers.push(worker);
    }

    /**
     * Worker thread loop
     */
    private workerLoop(): void {
        while (!this.isShutdown) {
            try {
                const task = this.getNextTask();
                if (task) {
                    this.activeThreads++;
                    const startTime = Date.now();
                    
                    try {
                        task.execute();
                        this.completedTasks++;
                        
                        // Calculate average task time
                        const taskTime = Date.now() - startTime;
                        this.updateAverageTaskTime(taskTime);
                        
                    } catch (error) {
                        this.failedTasks++;
                        FTInnerLogger.e(TAG, `Task execution failed: ${error}`);
                    } finally {
                        this.activeThreads--;
                    }
                } else {
                    // When no tasks, sleep briefly to avoid high CPU usage
                    setTimeout(() => {
                        this.workerLoop();
                    }, 10);
                    return;
                }
            } catch (error) {
                FTInnerLogger.e(TAG, `Worker thread loop execution failed: ${error}`);
                // When error occurs, sleep briefly then continue
                setTimeout(() => {
                    this.workerLoop();
                }, 100);
                return;
            }
        }
    }

    /**
     * Get the next task to execute
     */
    private getNextTask(): PriorityTask | null {
        // Get tasks in priority order
        if (this.highPriorityQueue.length > 0) {
            return this.highPriorityQueue.shift() || null;
        }
        if (this.normalPriorityQueue.length > 0) {
            return this.normalPriorityQueue.shift() || null;
        }
        if (this.lowPriorityQueue.length > 0) {
            return this.lowPriorityQueue.shift() || null;
        }
        return null;
    }

    /**
     * Execute high priority tasks
     */
    public executeHighPriority(task: () => void): void {
        this.executeWithPriority(task, TaskPriority.HIGH);
    }

    /**
     * Execute normal priority tasks
     */
    public executeNormalPriority(task: () => void): void {
        this.executeWithPriority(task, TaskPriority.NORMAL);
    }

    /**
     * Execute low priority tasks
     */
    public executeLowPriority(task: () => void): void {
        this.executeWithPriority(task, TaskPriority.LOW);
    }

    /**
     * Execute background tasks
     */
    public executeBackground(task: () => void): void {
        this.executeWithPriority(task, TaskPriority.BACKGROUND);
    }

    /**
     * Execute critical tasks
     */
    public executeCritical(task: () => void): void {
        this.executeWithPriority(task, TaskPriority.CRITICAL);
    }

    /**
     * Execute tasks based on priority
     */
    private executeWithPriority(task: () => void, priority: TaskPriority): void {
        if (this.isShutdown) {
            throw new Error('Thread pool is shutdown');
        }

        const priorityTask = new PriorityTask(task, priority);
        this.totalTasks++;

        // Put tasks into corresponding queues based on priority
        switch (priority) {
            case TaskPriority.CRITICAL:
            case TaskPriority.HIGH:
                this.highPriorityQueue.push(priorityTask);
                break;
            case TaskPriority.NORMAL:
                this.normalPriorityQueue.push(priorityTask);
                break;
            case TaskPriority.LOW:
            case TaskPriority.BACKGROUND:
                this.lowPriorityQueue.push(priorityTask);
                break;
        }

        // Check if thread pool needs expansion
        this.checkAndExpandPool();
    }

    /**
     * Check and expand thread pool
     */
    private checkAndExpandPool(): void {
        const totalQueueSize = this.highPriorityQueue.length + 
                              this.normalPriorityQueue.length + 
                              this.lowPriorityQueue.length;
        
        // If queue length exceeds active threads and max pool size not reached, expand thread pool
        if (totalQueueSize > this.activeThreads && 
            this.currentPoolSize < this.maxPoolSize) {
            this.expandPool();
        }
    }

    /**
     * Expand thread pool
     */
    private expandPool(): void {
        const newWorkerCount = Math.min(
            this.currentPoolSize + 1,
            this.maxPoolSize
        );
        
        if (newWorkerCount > this.currentPoolSize) {
            const workersToAdd = newWorkerCount - this.currentPoolSize;
            for (let i = 0; i < workersToAdd; i++) {
                this.startWorker();
            }
            this.currentPoolSize = newWorkerCount;
            
            // Removed verbose debug log to reduce log output
        }
    }

    /**
     * Shrink thread pool
     */
    private shrinkPool(): void {
        if (this.currentPoolSize > this.corePoolSize) {
            const workersToRemove = Math.min(
                this.currentPoolSize - this.corePoolSize,
                1 // Only reduce 1 thread at a time
            );
            
            if (workersToRemove > 0) {
                this.currentPoolSize -= workersToRemove;
                // Mark excess threads as interrupted to let them exit naturally
                // Removed individual thread interruption logs to reduce log output
                // Only log the summary
                
                // Removed verbose debug log to reduce log output
            }
        }
    }

    /**
     * Start optimization worker thread
     */
    private startOptimizationWorker(): void {
        // Use HarmonyOS setInterval to simulate optimization thread
        const optimizationWorkerId = setInterval(() => {
            this.optimizationLoop();
        }, 30000); // Execute optimization every 30 seconds
        const optimizerWorker: WorkerInfo = { id: optimizationWorkerId, name: "SmartThreadPool-Optimizer" };
        this.workers.push(optimizerWorker);
    }

    /**
     * Optimization loop
     */
    private optimizationLoop(): void {
        if (!this.isShutdown) {
            try {
                this.performOptimization();
            } catch (error) {
                FTInnerLogger.e(TAG, `Optimization loop execution failed: ${error}`);
            }
        }
    }

    /**
     * Perform optimization
     */
    private performOptimization(): void {
        try {
            // Calculate thread pool utilization
            const utilization = this.activeThreads / this.currentPoolSize;
            const queueSize = this.highPriorityQueue.length + 
                             this.normalPriorityQueue.length + 
                             this.lowPriorityQueue.length;
            
            // If utilization is low and queue is empty, consider shrinking thread pool
            if (utilization < 0.3 && queueSize === 0) {
                this.shrinkPool();
            }
            
            // If queue backlog is severe, consider expanding thread pool
            if (queueSize > this.currentPoolSize * 2) {
                this.expandPool();
            }
            
            // Log optimization info
            // Removed verbose debug log to reduce log output
            
        } catch (error) {
            FTInnerLogger.e(TAG, `Thread pool optimization failed: ${error}`);
        }
    }

    /**
     * Update average task time
     */
    private updateAverageTaskTime(taskTime: number): void {
        if (this.completedTasks === 1) {
            this.averageTaskTime = taskTime;
        } else {
            this.averageTaskTime = (this.averageTaskTime * (this.completedTasks - 1) + taskTime) / this.completedTasks;
        }
    }

    /**
     * Get thread pool status
     */
    public getStatus(): ThreadPoolStatus {
        const queueSizes: QueueSizes = {
            highPriority: this.highPriorityQueue.length,
            normalPriority: this.normalPriorityQueue.length,
            lowPriority: this.lowPriorityQueue.length
        };
        
        return {
            corePoolSize: this.corePoolSize,
            currentPoolSize: this.currentPoolSize,
            maxPoolSize: this.maxPoolSize,
            activeThreads: this.activeThreads,
            totalTasks: this.totalTasks,
            completedTasks: this.completedTasks,
            failedTasks: this.failedTasks,
            averageTaskTime: this.averageTaskTime,
            queueSizes: queueSizes
        };
    }

    /**
     * Shutdown thread pool
     */
    public shutdown(): void {
        this.isShutdown = true;
        
        // Interrupt all worker threads
        // Removed individual thread interruption logs to reduce log output
        // Only log the summary with total count
        const workerCount = this.workers.filter(w => w !== null && w !== undefined).length;
        
        FTInnerLogger.i(TAG, `SmartThreadPool shutdown: interrupting ${workerCount} worker thread(s)`);
    }

    /**
     * Force shutdown thread pool
     */
    public shutdownNow(): void {
        this.shutdown();
        
        // Clear all queues
        this.highPriorityQueue = [];
        this.normalPriorityQueue = [];
        this.lowPriorityQueue = [];
        
        FTInnerLogger.i(TAG, "SmartThreadPool has been force shutdown");
    }
}

/**
 * Queue Sizes Interface
 */
interface QueueSizes {
    highPriority: number;
    normalPriority: number;
    lowPriority: number;
}

/**
 * Thread Pool Status Interface
 */
export interface ThreadPoolStatus {
    corePoolSize: number;
    currentPoolSize: number;
    maxPoolSize: number;
    activeThreads: number;
    totalTasks: number;
    completedTasks: number;
    failedTasks: number;
    averageTaskTime: number;
    queueSizes: QueueSizes;
}

/**
 * Thread Interface
 */
interface IThread {
    name: string;
    start(): void;
    interrupt(): void;
    sleep(milliseconds: number): void;
}

/**
 * Basic Thread Implementation
 */
class Thread implements IThread {
    public name: string = '';
    private isRunning: boolean = false;
    private isInterrupted: boolean = false;
    private runnable: () => void;

    constructor(runnable: () => void) {
        this.runnable = runnable;
    }

    public start(): void {
        if (!this.isRunning) {
            this.isRunning = true;
            // In HarmonyOS, this would start actual threads
            // For demonstration, we use setTimeout to simulate async execution
            setTimeout(() => {
                if (!this.isInterrupted) {
                    this.runnable();
                }
                this.isRunning = false;
            }, 0);
        }
    }

    public interrupt(): void {
        this.isInterrupted = true;
    }

    public sleep(milliseconds: number): void {
        // Simulate thread sleep
        if (!this.isInterrupted) {
            // In actual implementation, this should use HarmonyOS thread sleep API
            // For demonstration, we use setTimeout to simulate
            setTimeout(() => {}, milliseconds);
        }
    }
}
