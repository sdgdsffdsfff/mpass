import os
import sys
import json
import cPickle

STATUS_FILE = "/home/bae/run/baeng/hades/status/instance.status"

import logging
import subprocess

def run_cmd(cmd, out=False):
    stdout = ""
    try:
        stdout = subprocess.check_output(cmd, shell=True, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError, e:
        logging.warning("(%s) failed (%d)" % (cmd, e.returncode))
        logging.info(stdout)
        return e.returncode, None
    except Exception, e:
        logging.warning("(%s) failed (%s)" % (cmd, e))
        return -1, None
    else:
        if out: return 0, stdout
        return 0, None


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
    status_info = {}

instance_list = [ k for k,v in status_info.items()]
container_list = [ v['container_id'] for k,v in status_info.items()]
ip_list = [ v['container_ip'] for k,v in status_info.items()]
uid_list = [ v['uid'] for k,v in status_info.items()]

### /home/bae/share/instances
print ">>>check share instance directory"
cmd = """ls /home/bae/share/instances/ -1"""
ret, output = run_cmd(cmd, True)
if ret == 0:
    output = output.strip()
    if len(output) > 3:
        instance_dirs = output.split('\n')
        for instance in instance_dirs:
            path = "/home/bae/share/instances/%s" % instance
            if os.path.isdir(path) and instance not in instance_list:
                os.system("rm -rf %s" % path)
else:
    print "ERROR: missing /home/bae/share/instances/ ?"

### /home/bae/share/logs
print ">>>check share logs directory"
cmd = """ls /home/bae/share/logs/ -1"""
ret, output = run_cmd(cmd, True)
if ret == 0:
    output = output.strip()
    if len(output) > 3:
        instance_dirs = output.strip().split('\n')
        for instance in instance_dirs:
        path = "/home/bae/share/logs/%s" % instance
        if os.path.isdir(path) and instance not in instance_list:
            os.system("rm -rf %s" % path)
else:
    print "ERROR: missing /home/bae/share/logs/"

if error: 
    sys.exit(1)
sys.exit(0)

