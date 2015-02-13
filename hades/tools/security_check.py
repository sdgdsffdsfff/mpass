import os
import sys
import json
import cPickle

STATUS_FILE = "/home/bae/run/baeng/hades/status/instance.status"

import logging
import subprocess

def load_from_disk():
        try:
            with open(STATUS_FILE, "rb") as fd:
                a = cPickle.load(fd)
                return True, a
        except Exception, e:
            return False, None

error = False

ret, status_info = load_from_disk()
if not ret:
    sys.exit(1)

uid_list = [ v['uid'] for k,v in status_info.items()]

print ">>>check zombie and illegal process"
try:
	import psutil
except ImportError:
	print "install psutil first"

proc_white_list = ["supervisord", "lighttpd", "wshd", "baelog", "comlog_apache", "php5-fpm", "ccdbfs"]
### root:0, admin:10000
uids_list = [0, 10000]
cgroup_path = "/sys/fs/cgroup/cpuacct/lxc"    

error = False
for p in psutil.get_process_list():
	try:
		if p.name == "lxc-start":
			for cp in [psutil.Process(int(i)) for i in open(os.path.join(cgroup_path, p.cmdline[2], "tasks"), "r").readlines()]:
				if cp.status == "zombie": 
					error = True
					print "%s: found zombie process: %d %s" % (p.cmdline[2][0:12], cp.pid, cp.name)
				#if cp.uids.real in uids_list  and cp.name not in set(proc_white_list) and cp.parent.uids.real not in set(uids_list): 
				if cp.uids.real in uids_list  and cp.name not in set(proc_white_list): 
					error = True
					print "%s: found illegal process: %d %s" % (p.cmdline[2][0:12], cp.pid, cp.name)
	except psutil.NoSuchProcess, IOError:
    		pass


if error: 
	sys.exit(1)
sys.exit(0)


