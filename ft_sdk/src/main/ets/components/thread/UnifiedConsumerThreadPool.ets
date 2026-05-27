/**
 * HarmonyOS SDK unified consumer thread pool class
 * Combines event consumption and log consumption functionality, supports task priority and load balancing
 */
import { SmartThreadPool, TaskPriority } from './SmartThreadPool';
import { FTInnerLogger } from '../log/FTLogger';

const TAG = "UnifiedConsumerThreadPool";

/**
 * Task type enumeration
 */
export enum TaskType {
    EVENT = 'event',           // RUM event task
    LOG = 'log',               // Log task
    DATABASE = 'database',     // Database task
    NETWORK = 'network',       // Network task
    MONITOR = 'monitor'        // Monitor task
}

/**
 * Task wrapper
 */
class ConsumerTask {
    public readonly type: TaskType;
    public readonly priority: TaskPriority;
    public readonly task: () => void;
    public readonly createTime: number;
    public readonly id: string;

    constructor(type: TaskType, priority: TaskPriority, task: () => void) {
        this.type = type;
        this.priority = priority;
        this.task = task;
        this.createTime = Date.now();
        this.id = this.generateTaskId();
    }

    public execute(): void {
        try {
            // Removed verbose debug log to reduce log output
            this.task();
            // Removed verbose debug log to reduce log output
        } catch (error) {
            FTInnerLogger.e(TAG, `Task execution failed: ${this.id}, error: ${error}`);
        }
    }

    private generateTaskId(): string {
        return `${this.type}_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
    }
}

/**
 * Unified consumer thread pool class
 * Combines event consumption and log consumption functionality, supports task priority and load balancing
 */
export class UnifiedConsumerThreadPool {
    private static instance: UnifiedConsumerThreadPool | null = null;
    
    // Core thread pool
    private smartThreadPool: SmartThreadPool;
    
    // Task statistics
    private taskStats: Map<TaskType, TaskStatistics> = new Map();
    
    // Task queue monitoring
    private queueMonitor: QueueMonitor;
    
    // Load balancer
    private loadBalancer: LoadBalancer;

    private constructor() {
        // Dynamically adjust thread count based on device performance
        const optimalThreadCount = this.getOptimalThreadCount();
        
        // Optimization: use single thread for database operations to ensure sequential execution
        // This prevents concurrent generateViewSum() calls from deleting views before triggerGenerateRumData() executes
        // Single thread also avoids database lock competition and simplifies code logic
        const maxThreads = 1; // Single thread for database operations
        this.smartThreadPool = new SmartThreadPool(
            maxThreads,
            maxThreads + 1  // Maximum thread count = core thread count + 1
        );
        
        this.queueMonitor = new QueueMonitor();
        this.loadBalancer = new LoadBalancer(optimalThreadCount);
        
        // Initialize task statistics
        this.initializeTaskStats();
        
        FTInnerLogger.i(TAG, `UnifiedConsumerThreadPool initialization completed, core thread count: ${optimalThreadCount}`);
    }

    /**
     * Get singleton instance
     */
    public static getInstance(): UnifiedConsumerThreadPool {
        if (!UnifiedConsumerThreadPool.instance) {
            UnifiedConsumerThreadPool.instance = new UnifiedConsumerThreadPool();
        }
        return UnifiedConsumerThreadPool.instance;
    }

    /**
     * Get optimal thread count based on device performance
     * Optimization: Reduce database operation thread count to avoid excessive thread competition for database resources
     */
    private getOptimalThreadCount(): number {
        // In HarmonyOS, use default values
        const cpuCount = 4;
        const memoryGB = 4;
        
        // Optimize thread count configuration: reduce database operation threads to avoid resource competition
        if (cpuCount >= 8 && memoryGB >= 8) {
            return 3; // High-performance device: maximum 3 threads
        } else if (cpuCount >= 4 && memoryGB >= 4) {
            return 2; // Medium-performance device: 2 threads
        } else {
            return 1; // Low-performance device: 1 thread
        }
    }

    /**
     * Initialize task statistics
     */
    private initializeTaskStats(): void {
        const taskTypeValues = [TaskType.EVENT, TaskType.LOG, TaskType.DATABASE, TaskType.NETWORK, TaskType.MONITOR];
        taskTypeValues.forEach(type => {
            this.taskStats.set(type, {
                totalTasks: 0,
                completedTasks: 0,
                failedTasks: 0,
                averageExecutionTime: 0,
                lastExecutionTime: 0
            });
        });
    }

    /**
     * Execute RUM event task
     */
    public executeEventTask(task: () => void): void {
        this.executeTask(TaskType.EVENT, TaskPriority.HIGH, task);
    }

    /**
     * Execute log task
     */
    public executeLogTask(task: () => void): void {
        this.executeTask(TaskType.LOG, TaskPriority.NORMAL, task);
    }

    /**
     * Execute database task
     */
    public executeDatabaseTask(task: () => void): void {
        this.executeTask(TaskType.DATABASE, TaskPriority.HIGH, task);
    }

    /**
     * Execute network task
     */
    public executeNetworkTask(task: () => void): void {
        this.executeTask(TaskType.NETWORK, TaskPriority.LOW, task);
    }

    /**
     * Execute monitor task
     */
    public executeMonitorTask(task: () => void): void {
        this.executeTask(TaskType.MONITOR, TaskPriority.CRITICAL, task);
    }

    /**
     * Core method for executing tasks
     */
    private executeTask(type: TaskType, priority: TaskPriority, task: () => void): void {
        const consumerTask = new ConsumerTask(type, priority, task);
        
        // Update task statistics
        this.updateTaskStats(type, 'submit');
        
        // Select execution strategy based on task type and priority
        switch (priority) {
            case TaskPriority.CRITICAL:
                this.smartThreadPool.executeCritical(() => consumerTask.execute());
                break;
            case TaskPriority.HIGH:
                this.smartThreadPool.executeHighPriority(() => consumerTask.execute());
                break;
            case TaskPriority.NORMAL:
                this.smartThreadPool.executeNormalPriority(() => consumerTask.execute());
                break;
            case TaskPriority.LOW:
                this.smartThreadPool.executeLowPriority(() => consumerTask.execute());
                break;
            case TaskPriority.BACKGROUND:
                this.smartThreadPool.executeBackground(() => consumerTask.execute());
                break;
        }
        
        // Update queue monitoring
        this.queueMonitor.recordTaskSubmission(type, priority);
        
        // Check load balancing
        this.loadBalancer.checkAndAdjust(type);
    }

    /**
     * Convert Map to plain object
     */
    private convertMapToObject<K, V>(map: Map<K, V>): Record<string, V> {
        const result: Record<string, V> = {};
        map.forEach((value, key) => {
            result[String(key)] = value;
        });
        return result;
    }

    /**
     * Update task statistics
     */
    private updateTaskStats(type: TaskType, action: 'submit' | 'complete' | 'fail'): void {
        const stats = this.taskStats.get(type);
        if (stats) {
            switch (action) {
                case 'submit':
                    stats.totalTasks++;
                    break;
                case 'complete':
                    stats.completedTasks++;
                    stats.lastExecutionTime = Date.now();
                    break;
                case 'fail':
                    stats.failedTasks++;
                    break;
            }
        }
    }

    /**
     * Get thread pool status
     */
    public getStatus(): UnifiedThreadPoolStatus {
        const smartPoolStatus = this.smartThreadPool.getStatus();
        
        return {
            smartPoolStatus,
            taskStatistics: this.convertMapToObject(this.taskStats),
            queueMonitor: this.queueMonitor.getStatus(),
            loadBalancer: this.loadBalancer.getStatus()
        };
    }

    /**
     * Shutdown thread pool
     */
    public shutdown(): void {
        this.smartThreadPool.shutdown();
        UnifiedConsumerThreadPool.instance = null;
        FTInnerLogger.i(TAG, "UnifiedConsumerThreadPool has been shut down");
    }

    /**
     * Force shutdown thread pool
     */
    public shutdownNow(): void {
        this.smartThreadPool.shutdownNow();
        UnifiedConsumerThreadPool.instance = null;
        FTInnerLogger.i(TAG, "UnifiedConsumerThreadPool has been force shut down");
    }
}

/**
 * Task statistics interface
 */
interface TaskStatistics {
    totalTasks: number;
    completedTasks: number;
    failedTasks: number;
    averageExecutionTime: number;
    lastExecutionTime: number;
}

/**
 * Queue monitor
 */
class QueueMonitor {
    private queueStats: Map<TaskType, QueueStatistics> = new Map();
    private lastResetTime: number = Date.now();

    constructor() {
        Object.values(TaskType).forEach(type => {
            this.queueStats.set(type, {
                submittedTasks: 0,
                processedTasks: 0,
                queueLength: 0,
                averageWaitTime: 0
            });
        });
    }

    public recordTaskSubmission(type: TaskType, priority: TaskPriority): void {
        const stats = this.queueStats.get(type);
        if (stats) {
            stats.submittedTasks++;
            stats.queueLength++;
        }
    }

    public recordTaskProcessed(type: TaskType): void {
        const stats = this.queueStats.get(type);
        if (stats) {
            stats.processedTasks++;
            stats.queueLength = Math.max(0, stats.queueLength - 1);
        }
    }

    public getStatus(): QueueMonitorStatus {
        return {
            queueStats: this.convertMapToObject(this.queueStats),
            lastResetTime: this.lastResetTime
        };
    }

    /**
     * Convert Map to plain object
     */
    private convertMapToObject<K, V>(map: Map<K, V>): Record<string, V> {
        const result: Record<string, V> = {};
        map.forEach((value, key) => {
            result[String(key)] = value;
        });
        return result;
    }

    public reset(): void {
        this.queueStats.forEach(stats => {
            stats.submittedTasks = 0;
            stats.processedTasks = 0;
            stats.queueLength = 0;
            stats.averageWaitTime = 0;
        });
        this.lastResetTime = Date.now();
    }
}

/**
 * Queue statistics interface
 */
interface QueueStatistics {
    submittedTasks: number;
    processedTasks: number;
    queueLength: number;
    averageWaitTime: number;
}

/**
 * Queue monitor status interface
 */
interface QueueMonitorStatus {
    queueStats: Record<TaskType, QueueStatistics>;
    lastResetTime: number;
}

/**
 * Load balancer
 */
class LoadBalancer {
    private taskDistribution: Map<TaskType, number> = new Map();
    private threadUtilization: number = 0;
    private lastAdjustmentTime: number = Date.now();
    private optimalThreadCount: number;

    constructor(optimalThreadCount: number) {
        this.optimalThreadCount = optimalThreadCount;
        Object.values(TaskType).forEach(type => {
            this.taskDistribution.set(type, 0);
        });
    }

    public checkAndAdjust(type: TaskType): void {
        // Update task distribution
        const currentCount = this.taskDistribution.get(type) || 0;
        this.taskDistribution.set(type, currentCount + 1);

        // Check load balancing every 100 tasks
        const totalTasks = Array.from(this.taskDistribution.values()).reduce((sum, count) => sum + count, 0);
        if (totalTasks % 100 === 0) {
            this.performLoadBalancing();
        }
    }

    private performLoadBalancing(): void {
        const now = Date.now();
        if (now - this.lastAdjustmentTime < 5000) {
            return; // No repeated adjustments within 5 seconds
        }

        // Calculate whether task distribution is balanced
        const avgTasksPerType = Array.from(this.taskDistribution.values()).reduce((sum, count) => sum + count, 0) / this.taskDistribution.size;
        const maxTasksPerType = Math.max(...Array.from(this.taskDistribution.values()));
        const minTasksPerType = Math.min(...Array.from(this.taskDistribution.values()));

        // Log if distribution is unbalanced
        if (maxTasksPerType > avgTasksPerType * 1.5) {
            FTInnerLogger.w(TAG, `Detected unbalanced task distribution: max=${maxTasksPerType}, min=${minTasksPerType}, avg=${avgTasksPerType.toFixed(2)}`);
        }

        this.lastAdjustmentTime = now;
    }

    public getStatus(): LoadBalancerStatus {
        return {
            taskDistribution: this.convertMapToObject(this.taskDistribution),
            threadUtilization: this.threadUtilization,
            lastAdjustmentTime: this.lastAdjustmentTime
        };
    }

    /**
     * Convert Map to plain object
     */
    private convertMapToObject<K, V>(map: Map<K, V>): Record<string, V> {
        const result: Record<string, V> = {};
        map.forEach((value, key) => {
            result[String(key)] = value;
        });
        return result;
    }
}

/**
 * Load balancer status interface
 */
interface LoadBalancerStatus {
    taskDistribution: Record<TaskType, number>;
    threadUtilization: number;
    lastAdjustmentTime: number;
}

/**
 * Unified thread pool status interface
 */
export interface UnifiedThreadPoolStatus {
    smartPoolStatus: object; // SmartThreadPool status
    taskStatistics: Record<TaskType, TaskStatistics>;
    queueMonitor: QueueMonitorStatus;
    loadBalancer: LoadBalancerStatus;
}

/**
 * Runnable interface
 */
interface Runnable {
    run(): void;
}
