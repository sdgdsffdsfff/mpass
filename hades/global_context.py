import Queue
import os

g_reply_queue     = Queue.Queue(100)
g_heartbeat_queue = Queue.Queue(10)

g_debug_mode = True if 'DEBUG_MODE' in os.environ and os.environ['DEBUG_MODE'] == "1" else False
g_healthy_check = True if 'HEALTHY_CHECK' in os.environ and os.environ['HEALTHY_CHECK'] == "1" else False

