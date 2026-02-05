import requests
import json
import logging

class XMRigProxyClient:
    def __init__(self, host="127.0.0.1", port=8080, access_token=None):
        """
        Initialize the XMRig Proxy Client.
        
        :param host: The hostname or IP address of the xmrig-proxy.
        :param port: The HTTP API port (configured via --http-port).
        :param access_token: The access token (configured via --http-access-token).
        """
        self.logger = logging.getLogger("ProxyClient")
        self.base_url = f"http://{host}:{port}"
        self.headers = {}
        if access_token:
            self.headers["Authorization"] = f"Bearer {access_token}"

    def get_summary(self):
        """
        Get proxy summary information including uptime, version, and resources.
        Endpoint: GET /1/summary

        Response:
        {
            "id": "str",                    // Instance ID
            "worker_id": "str",             // Worker ID (default: hostname)
            "uptime": int,                  // Uptime in seconds
            "restricted": bool,             // If API is running in restricted mode
            "resources": {
                "memory": {
                    "free": int,            // Free memory in bytes
                    "total": int,           // Total memory in bytes
                    "resident_set_memory": int // RSS in bytes
                },
                "load_average": [float, float, float], // [1min, 5min, 15min]
                "hardware_concurrency": int // Number of CPU threads
            },
            "features": ["str"]             // List of enabled features (e.g. "api", "http", "tls")
        }
        """
        url = f"{self.base_url}/1/summary"
        response = requests.get(url, headers=self.headers)
        response.raise_for_status()
        return response.json()

    def get_workers(self):
        """
        Get details about connected workers.
        Endpoint: GET /1/workers

        Response:
        {
            "workers": [
                {
                    "id": "str",            // Worker ID
                    "ip": "str",            // Worker IP address
                    "user_agent": "str",    // Miner user agent
                    "hashrate": [float, float, float], // [10s, 60s, 15m] hashrate
                    "shares": [int, int, int] // [accepted, rejected, invalid] shares
                }
            ],
            "hashrate": {
                "total": [float, float, float],
                "highest": float
            },
            "results": {
                "diff_current": int,
                "shares_good": int,
                "shares_total": int,
                "avg_time": int,
                "hashes_total": int
            },
            "connection": {
                "uptime": int,
                "ping": int,
                "failures": int
            }
        }
        """
        url = f"{self.base_url}/1/workers"
        response = requests.get(url, headers=self.headers)
        response.raise_for_status()
        return response.json()

    def get_config(self):
        """
        Get the current configuration of the proxy.
        Endpoint: GET /1/config

        Response:
        {
            "pools": [
                {
                    "url": "str",
                    "user": "str",
                    "pass": "str",
                    "keepalive": bool,
                    "tls": bool
                }
            ],
            "bind": "str",                  // Bind address (e.g. "0.0.0.0:3333")
            "mode": "str",                  // Proxy mode ("nicehash" or "simple")
            "donate-level": int,            // Donation level percentage
            "custom-diff": int,             // Global custom difficulty
            "api": {
                "port": int,
                "access-token": "str",
                "worker-id": "str",
                "ipv6": bool,
                "restricted": bool
            },
            "log-file": "str"
        }
        """
        url = f"{self.base_url}/1/config"
        response = requests.get(url, headers=self.headers)
        response.raise_for_status()
        return response.json()

    def update_config(self, config_data):
        """
        Update the proxy configuration.
        Endpoint: PUT /1/config

        :param config_data: A dictionary containing the configuration fields to update.

        Body:
        {
            "pools": [
                {
                    "url": "host:port",
                    "user": "wallet_address",
                    "pass": "x"
                }
            ],
            "donate-level": int
            ... (Any other config fields to update)
        }
        """
        url = f"{self.base_url}/1/config"
        response = requests.put(url, headers=self.headers, json=config_data)
        response.raise_for_status()
        return response.json()

if __name__ == "__main__":
    # Configuration
    # Ensure xmrig-proxy is running with API enabled:
    # ./xmrig-proxy --http-port=8080 --http-access-token=SECRET
    
    HOST = "127.0.0.1"
    PORT = 8080 
    TOKEN = "SECRET" 

    client = XMRigProxyClient(HOST, PORT, TOKEN)

    try:
        # 1. Get Summary
        print("--- Summary ---")
        summary = client.get_summary()
        print(json.dumps(summary, indent=4))

        # 2. Get Workers
        print("\n--- Worker Details ---")
        workers = client.get_workers()
        print(json.dumps(workers, indent=4))

        # 3. Get Config
        print("\n--- Current Config ---")
        config = client.get_config()
        print(json.dumps(config, indent=4))

        # 4. Update Config (Example: changing donate level)
        # print("\n--- Updating Config ---")
        # updated_config = client.update_config({"donate-level": 1})
        # print(json.dumps(updated_config, indent=4))

    except requests.exceptions.RequestException as e:
        print(f"HTTP Request failed: {e}")
    except Exception as e:
        print(f"An error occurred: {e}")