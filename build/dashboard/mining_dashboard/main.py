import asyncio
import logging
import time
from aiohttp import web, ClientSession

from config import UPDATE_INTERVAL, HOST_IP, XMRIG_API_PORT, XVB_TIME_ALGO_MS
from storage import StateManager
from algo import XvbAlgorithm
from web.server import create_app
from collectors.miners import get_all_workers_stats
from collectors.pools import get_p2pool_stats, get_network_stats, get_stratum_stats, get_tari_stats
from collectors.system import get_disk_usage, get_hugepages_status, get_memory_usage, get_load_average, get_cpu_usage
from collectors.xvb import fetch_xvb_stats 

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')
logger = logging.getLogger("Main")

state_manager = StateManager()
algorithm = XvbAlgorithm(state_manager)

# Global shared state for the latest aggregated metrics
DEFAULT_DATA = {
    "workers": [],
    "total_live_h15": 0,
    "pool": {"p2p": {}, "pool": {}},
    "network": {},
    "system": {},
    "tari": {},
    "stratum": {},
    "timestamp": 0
}

# Attempt to restore state from DB to prevent empty dashboard on restart
loaded_snapshot = state_manager.load_snapshot()
if loaded_snapshot and isinstance(loaded_snapshot, dict):
    LATEST_DATA = {**DEFAULT_DATA, **loaded_snapshot}
else:
    LATEST_DATA = DEFAULT_DATA.copy()


async def switch_worker(session, worker, p2pool_state, xvb_state):
    """Helper to switch a single worker's configuration."""
    name = worker.get('name', '')
    ip = worker.get('ip', '')
    
    # Connection Strategy: Hostname -> mDNS -> IP
    targets = [
        f"{name}:{XMRIG_API_PORT}",       
        f"{name}.local:{XMRIG_API_PORT}", 
        f"{ip}:{XMRIG_API_PORT}"          
    ]

    # Use the worker's hostname (derived from name) as the access token
    token = name.split('+')[0].strip()
    headers = {"Authorization": f"Bearer {token}"}

    switched = False
    for target in targets:
        if target.startswith(":"): continue 

        url = f"http://{target}/1/config"
        
        try:
            # 1. Fetch current configuration
            async with session.get(url, headers=headers, timeout=2) as get_resp:
                if get_resp.status != 200:
                    continue
                config_data = await get_resp.json()
            
            if not isinstance(config_data, dict):
                continue

            # 2. Modify pool states based on ports
            needs_update = False
            if "pools" in config_data and isinstance(config_data["pools"], list):
                for pool in config_data["pools"]:
                    p_url = pool.get("url", "")
                    target_state = None
                    if ":3333" in p_url: target_state = p2pool_state
                    elif ":3344" in p_url: target_state = xvb_state
                    
                    if target_state is not None and pool.get("enabled") != target_state:
                        pool["enabled"] = target_state
                        needs_update = True

            if not needs_update:
                switched = True
                break

            # 3. Push updated configuration
            async with session.put(url, json=config_data, headers=headers, timeout=2) as resp:
                if resp.status in [200, 202, 204]:
                    switched = True
                    break 
        except Exception:
            continue
    
    if not switched:
        logger.warning(f"Worker Control Error: Failed to switch {name} (Targets attempted: {', '.join(targets)})")

async def switch_miners(mode, workers):
    """
    Configures the upstream pool priority for all active XMRig workers.
    
    Iterates through the provided worker list and updates their configuration
    via the XMRig HTTP API to prioritize either P2Pool or the XvB proxy.
    
    Args:
        mode (str): The target mining mode ("P2POOL" or "XVB").
        workers (list): A list of worker dictionaries containing 'ip' and 'name'.
    """
    if not workers: return
    
    p2pool_state = True if mode == "P2POOL" else False
    xvb_state = True if mode == "XVB" else False

    async with ClientSession() as session:
        tasks = [switch_worker(session, w, p2pool_state, xvb_state) for w in workers]
        await asyncio.gather(*tasks)


async def data_collection_loop():
    """
    Periodic task to aggregate statistics from local collectors and external APIs.
    Updates the global LATEST_DATA state and persists historical metrics.
    """
    logger.info("Service Started: Data Collection Loop")
    
    iteration_count = 0 
    
    while True:
        try:
            # 1. Collect Local Statistics (High Frequency)
            stratum_raw, worker_configs = get_stratum_stats()
            
            # Update persistent state with currently visible workers
            await asyncio.to_thread(state_manager.update_known_workers, worker_configs)
            
            # Query ALL known workers (even those temporarily missing from P2Pool stats)
            all_known_workers = state_manager.get_known_workers()
            workers_stats = await get_all_workers_stats(all_known_workers)
            
            # Aggregate 15-minute average hashrate for stable algorithmic input
            total_h15 = sum(w.get('h15', 0) for w in workers_stats if w.get('status') == 'online')
            
            pool_stats = get_p2pool_stats()
            net_stats = get_network_stats()
            sys_stats = {
                "disk": get_disk_usage(),
                "hugepages": get_hugepages_status(),
                "memory": get_memory_usage(),
                "load": get_load_average(),
                "cpu_percent": get_cpu_usage()
            }
            
            LATEST_DATA.update({
                "workers": workers_stats,
                "total_live_h15": total_h15,
                "pool": pool_stats,
                "network": net_stats,
                "tari": get_tari_stats(),
                "system": sys_stats,
                "stratum": stratum_raw,
                "timestamp": time.time()
            })
            
            # 2. Update Historical Data
            # Attribute hashrate to the active mode for visualization
            current_mode = state_manager.get_xvb_stats().get("current_mode", "P2POOL")
            p2pool_hr = 0
            xvb_hr = 0
            if "XVB" in current_mode:
                xvb_hr = total_h15
            else:
                p2pool_hr = total_h15
            
            await asyncio.to_thread(state_manager.update_history, total_h15, p2pool_hr, xvb_hr)

            # Persist the latest snapshot to DB for crash recovery
            await asyncio.to_thread(state_manager.save_snapshot, LATEST_DATA)

            # 3. External API Sync (Throttled: Every 5 minutes / 10 cycles)
            if iteration_count % 10 == 0:
                real_xvb_stats = await fetch_xvb_stats()
                if real_xvb_stats:
                    await asyncio.to_thread(state_manager.update_xvb_stats,
                        donation_avg_24h=real_xvb_stats["24h_avg"],
                        donation_avg_1h=real_xvb_stats["1h_avg"],
                        fail_count=real_xvb_stats.get("fail_count", 0)
                    )
                    logger.info(f"External Sync: XvB Stats Updated (1h={real_xvb_stats['1h_avg']:.0f} H/s | 24h={real_xvb_stats['24h_avg']:.0f} H/s)")
            
            iteration_count += 1
            
        except Exception as e:
            logger.error(f"Data Collection Error: {e}")
            
        await asyncio.sleep(UPDATE_INTERVAL)


async def algo_control_loop():
    """
    Periodic task to execute the mining strategy algorithm.
    Determines the optimal mining mode and manages worker switching cycles.
    """
    logger.info("Service Started: Algorithm Control Loop")
    await asyncio.sleep(5) 
    
    while True:
        try:
            current_hr = LATEST_DATA.get("total_live_h15", 0)
            p2pool_stats = LATEST_DATA.get("pool", {}).get("pool", {}) 
            xvb_stats = state_manager.get_xvb_stats()
            
            # Execute decision logic
            decision, xvb_duration = algorithm.get_decision(current_hr, p2pool_stats, xvb_stats)
            workers = LATEST_DATA.get("workers", [])
            
            if decision == "P2POOL":
                await asyncio.to_thread(state_manager.update_xvb_stats, mode="P2POOL")
                await switch_miners("P2POOL", workers)
                await asyncio.sleep(XVB_TIME_ALGO_MS / 1000)
                
            elif decision == "XVB":
                await asyncio.to_thread(state_manager.update_xvb_stats, mode="XVB")
                await switch_miners("XVB", workers)
                await asyncio.sleep(XVB_TIME_ALGO_MS / 1000)
                
            elif decision == "SPLIT":
                # Split Mode: Allocate time slice to XvB, remainder to P2Pool
                await asyncio.to_thread(state_manager.update_xvb_stats, mode="XVB (Split)")
                await switch_miners("XVB", workers)
                await asyncio.sleep(xvb_duration / 1000)
                
                remainder = (XVB_TIME_ALGO_MS - xvb_duration) / 1000
                if remainder > 0:
                    await asyncio.to_thread(state_manager.update_xvb_stats, mode="P2POOL (Split)")
                    await switch_miners("P2POOL", workers)
                    await asyncio.sleep(remainder)

        except Exception as e:
            logger.error(f"Algorithm Error: {e}")
            await asyncio.sleep(10)

async def start_background_tasks(app):
    """Initializes background services upon web application startup."""
    app['data_task'] = asyncio.create_task(data_collection_loop())
    app['algo_task'] = asyncio.create_task(algo_control_loop())

if __name__ == "__main__":
    app = create_app(state_manager, LATEST_DATA)
    app.on_startup.append(start_background_tasks)
    logger.info("Initializing Dashboard Web Server on Port 8000")
    web.run_app(app, port=8000, print=None)