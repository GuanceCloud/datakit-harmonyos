/**
 * HarmonyOS SDK thread pool manager class
 * Unified management of all thread pools, providing unified interface and configuration
 */
import { SmartThreadPool, TaskPriority, ThreadPoolStatus } from './SmartThreadPool';
import { UnifiedConsumerThreadPool, TaskType, UnifiedThreadPoolStatus } from './UnifiedConsumerThreadPool';
import { FTInnerLogger } from '../log/FTLogger';

/**
 * Smart thread pool configuration interface
 */
interface SmartPoolConfig {
    corePoolSize: number;
    maxPoolSize: number;
}

/**
 * Common thread pool status type
 */
type ThreadPoolMetricsType = ThreadPoolStatus | UnifiedThreadPoolStatus  ;

/**
 * Unified consumer thread pool configuration interface
 */
interface UnifiedPoolConfig {
    enabled: boolean;
    optimalThreadCount: number;
}


const TAG = "ThreadPoolManager";

/**
 * Thread pool type enumeration
 */
export enum ThreadPoolType {
    FACTORY = 'factory',           // Factory thread pool
    SMART = 'smart',               // Smart thread pool
    UNIFIED = 'unified',           // Unified consumer thread pool
    ADAPTIVE = 'adaptive',         // Adaptive thread pool
    MONITORED = 'monitored'        // Monitor thread pool
}

/**
 * Thread pool configuration
 */
export interface ThreadPoolManagerConfig {
    // Smart thread pool configuration
    smartPool: SmartPoolConfig;

    // Unified consumer thread pool configuration
    unifiedPool: UnifiedPoolConfig;

}

/**
 * Thread pool manager class
 * Unified management of all thread pools, providing unified interface and configuration
 */
export class ThreadPoolManager {
    private static instance: ThreadPoolManager | null = null;

    // Thread pool instances
    private smartThreadPool: SmartThreadPool | null = null;
    private unifiedConsumerThreadPool: UnifiedConsumerThreadPool | null = null;

    // Configuration
    private config: ThreadPoolManagerConfig;

    // Status management
    private isInitialized: boolean = false;
    private isShutdown: boolean = false;

    private constructor(config: Partial<ThreadPoolManagerConfig> = {}) {
        // Set default configuration - optimized to reduce database operation threads
        const defaultConfig: ThreadPoolManagerConfig = {
            smartPool: {
                corePoolSize: 2,  // Reduce core thread count: 4 -> 2
                maxPoolSize: 4    // Reduce max thread count: 8 -> 4
            },
            unifiedPool: {
                enabled: true,
                optimalThreadCount: 2  // Reduce unified consumer threads: 4 -> 2
            },
        };

        // Merge configuration
        this.config = this.mergeConfig(defaultConfig, config);

        FTInnerLogger.i(TAG, "ThreadPoolManager initialization started");
    }

    /**
     * Merge configuration
     */
    private mergeConfig(defaultConfig: ThreadPoolManagerConfig, userConfig: Partial<ThreadPoolManagerConfig>): ThreadPoolManagerConfig {
        const result = this.copyConfig(defaultConfig);

        if (userConfig.smartPool) {
            result.smartPool = this.mergeSmartPoolConfig(defaultConfig.smartPool, userConfig.smartPool);
        }
        if (userConfig.unifiedPool) {
            result.unifiedPool = this.mergeUnifiedPoolConfig(defaultConfig.unifiedPool, userConfig.unifiedPool);
        }

        return result;
    }

    /**
     * Clone configuration
     */
    private copyConfig(config: ThreadPoolManagerConfig): ThreadPoolManagerConfig {
        return {
            smartPool: this.copySmartPoolConfig(config.smartPool),
            unifiedPool: this.copyUnifiedPoolConfig(config.unifiedPool),
        };
    }

    /**
     * Clone smart thread pool configuration
     */
    private copySmartPoolConfig(config: SmartPoolConfig): SmartPoolConfig {
        return {
            corePoolSize: config.corePoolSize,
            maxPoolSize: config.maxPoolSize
        };
    }

    /**
     * Clone unified consumer thread pool configuration
     */
    private copyUnifiedPoolConfig(config: UnifiedPoolConfig): UnifiedPoolConfig {
        return {
            enabled: config.enabled,
            optimalThreadCount: config.optimalThreadCount
        };
    }

    /**
     * Merge smart thread pool configuration
     */
    private mergeSmartPoolConfig(defaultConfig: SmartPoolConfig, userConfig: Partial<SmartPoolConfig>): SmartPoolConfig {
        return {
            corePoolSize: userConfig.corePoolSize ?? defaultConfig.corePoolSize,
            maxPoolSize: userConfig.maxPoolSize ?? defaultConfig.maxPoolSize
        };
    }

    /**
     * Merge unified consumer thread pool configuration
     */
    private mergeUnifiedPoolConfig(defaultConfig: UnifiedPoolConfig, userConfig: Partial<UnifiedPoolConfig>): UnifiedPoolConfig {
        return {
            enabled: userConfig.enabled ?? defaultConfig.enabled,
            optimalThreadCount: userConfig.optimalThreadCount ?? defaultConfig.optimalThreadCount
        };
    }


    /**
     * Get the singleton instance
     */
    public static getInstance(config?: Partial<ThreadPoolManagerConfig>): ThreadPoolManager {
        if (!ThreadPoolManager.instance) {
            ThreadPoolManager.instance = new ThreadPoolManager(config);
        }
        return ThreadPoolManager.instance;
    }

    /**
     * Initialize thread pool manager
     */
    public async initialize(): Promise<void> {
        if (this.isInitialized) {
            FTInnerLogger.w(TAG, "ThreadPoolManager has already been initialized");
            return;
        }

        try {
            // Initialize smart thread pool
            this.initializeSmartThreadPool();

            // Initialize unified consumer thread pool
            if (this.config.unifiedPool.enabled) {
                this.initializeUnifiedConsumerThreadPool();
            }


            this.isInitialized = true;
            FTInnerLogger.i(TAG, "ThreadPoolManager initialization completed");

        } catch (error) {
            FTInnerLogger.e(TAG, `ThreadPoolManager initialization failed: ${error}`);
            throw new Error(`ThreadPoolManager initialization failed: ${error}`);
        }
    }

    /**
     * Initialize smart thread pool
     */
    private initializeSmartThreadPool(): void {
        this.smartThreadPool = new SmartThreadPool(
            this.config.smartPool.corePoolSize,
            this.config.smartPool.maxPoolSize
        );
        FTInnerLogger.i(TAG, "Smart thread pool initialization completed");
    }

    /**
     * Initialize unified consumer thread pool
     */
    private initializeUnifiedConsumerThreadPool(): void {
        this.unifiedConsumerThreadPool = UnifiedConsumerThreadPool.getInstance();
        FTInnerLogger.i(TAG, "Unified consumer thread pool initialization completed");
    }



    /**
     * Execute high priority task
     */
    public executeHighPriority(task: () => void): void {
        this.checkInitialization();

        if (this.unifiedConsumerThreadPool) {
            this.unifiedConsumerThreadPool.executeEventTask(task);
        } else if (this.smartThreadPool) {
            this.smartThreadPool.executeHighPriority(task);
        } else {
            throw new Error('No available thread pool');
        }
    }

    /**
     * Execute normal priority task
     */
    public executeNormalPriority(task: () => void): void {
        this.checkInitialization();

        if (this.unifiedConsumerThreadPool) {
            this.unifiedConsumerThreadPool.executeLogTask(task);
        } else if (this.smartThreadPool) {
            this.smartThreadPool.executeNormalPriority(task);
        } else {
            throw new Error('No available thread pool');
        }
    }

    /**
     * Execute low priority task
     */
    public executeLowPriority(task: () => void): void {
        this.checkInitialization();

        if (this.unifiedConsumerThreadPool) {
            this.unifiedConsumerThreadPool.executeNetworkTask(task);
        } else if (this.smartThreadPool) {
            this.smartThreadPool.executeLowPriority(task);
        } else {
            throw new Error('No available thread pool');
        }
    }


    /**
     * Check initialization status
     */
    private checkInitialization(): void {
        if (!this.isInitialized) {
            throw new Error('ThreadPoolManager has not been initialized, please call initialize() method first');
        }

        if (this.isShutdown) {
            throw new Error('ThreadPoolManager has been shut down');
        }
    }

    /**
     * Get thread pool status
     */
    public getStatus(): ThreadPoolManagerStatus {
        return {
            isInitialized: this.isInitialized,
            isShutdown: this.isShutdown,
            smartThreadPool: this.smartThreadPool?.getStatus() || null,
            unifiedConsumerThreadPool: this.unifiedConsumerThreadPool?.getStatus() || null,
            config: this.config
        };
    }



    /**
     * Shutdown thread pool manager
     */
    public shutdown(): void {
        if (this.isShutdown) {
            return;
        }

        this.isShutdown = true;

        try {
            // Shutdown all thread pools
            if (this.smartThreadPool) {
                this.smartThreadPool.shutdown();
            }

            if (this.unifiedConsumerThreadPool) {
                this.unifiedConsumerThreadPool.shutdown();
            }

            FTInnerLogger.i(TAG, "ThreadPoolManager has been shut down");

        } catch (error) {
            FTInnerLogger.e(TAG, `Error occurred while shutting down ThreadPoolManager: ${error}`);
        }
    }

    /**
     * Force shutdown thread pool manager
     */
    public shutdownNow(): void {
        if (this.isShutdown) {
            return;
        }

        this.isShutdown = true;

        try {
            // Force shutdown all thread pools
            if (this.smartThreadPool) {
                this.smartThreadPool.shutdownNow();
            }

            if (this.unifiedConsumerThreadPool) {
                this.unifiedConsumerThreadPool.shutdownNow();
            }


            FTInnerLogger.i(TAG, "ThreadPoolManager has been force shut down");

        } catch (error) {
            FTInnerLogger.e(TAG, `Error occurred while force shutting down ThreadPoolManager: ${error}`);
        }
    }

    /**
     * Reset thread pool manager
     */
    public reset(): void {
        this.shutdown();
        this.isInitialized = false;
        this.isShutdown = false;

        // Reinitialize
        this.initialize();
    }
}

/**
 * Thread pool manager status interface
 */
export interface ThreadPoolManagerStatus {
    isInitialized: boolean;
    isShutdown: boolean;
    smartThreadPool: object | null;
    unifiedConsumerThreadPool: object | null;
    config: ThreadPoolManagerConfig;
}
