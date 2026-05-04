#!/usr/bin/env python3
import sys
sys.path.insert(0, r'C:\Users\thinkpad-mateus\Downloads\Project_O\Marketing\Stream')
from MCP import sideloadly_mcp_server as s

result = s.launch_sideloadly_install()
print(f"Launched Sideloadly: PID {result['pid']}")
